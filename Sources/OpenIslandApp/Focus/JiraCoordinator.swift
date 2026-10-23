import FocusCore
import Foundation
import Observation
import OpenIslandCore

@MainActor
@Observable
final class JiraCoordinator {
    private(set) var connection: JiraConnection?
    private(set) var issues: [JiraIssue] = []
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var lastRefresh: Date?
    @ObservationIgnored private(set) var operation: Task<Void, Never>?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let client: any JiraProviding
    @ObservationIgnored private let service: JiraTaskService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let durable: Bool
    @ObservationIgnored private var generation = UUID()
    static let connectionKey = "focus.jira.connection"

    init(store: FocusStore, defaults: UserDefaults, durable: Bool, client: any JiraProviding = JiraCLIClient()) {
        self.client = client
        service = JiraTaskService(store: store)
        self.defaults = defaults
        self.durable = durable
        if let data = defaults.data(forKey: Self.connectionKey),
           let saved = try? JSONDecoder().decode(JiraConnection.self, from: data),
           (try? JiraConnection.canonicalSite(saved.site)) == saved.site, UUID(uuidString: saved.cloudID) != nil {
            connection = saved
        }
    }

    func connect() {
        perform {
            let connection = try await self.client.connect()
            // A successful search verifies access, not just the presence of a CLI login.
            let issues = try await self.client.search(connection: connection)
            try Task.checkCancellation()
            self.defaults.set(try JSONEncoder().encode(connection), forKey: Self.connectionKey)
            self.connection = connection
            self.issues = issues
        }
    }

    func authorize(executable: URL? = JiraCommand.executable(), launcher: any TerminalLaunching = AppleScriptTerminalLauncher()) {
        guard !isBusy else { return }
        guard let executable else { error = JiraError.cliMissing.localizedDescription; return }
        do {
            try launcher.run(command: "\(ShellQuoting.singleQuoted(executable.path)) jira auth login --web", in: .terminal)
            error = nil
        } catch { self.error = L10n.tr("jira.error.commandFailed") }
    }

    func loadIssues() {
        guard let connection else { return }
        perform {
            let issues = try await self.client.search(connection: connection)
            try Task.checkCancellation()
            self.issues = issues
        }
    }

    func importIssues(ids: Set<String>, column: BoardColumn, projectPath: String?) {
        guard let connection else { return }
        let selected = issues.filter { ids.contains($0.id) }
        guard selected.count == ids.count else { error = JiraError.invalidResponse.localizedDescription; return }
        guard !selected.isEmpty else { return }
        perform {
            var details: [JiraIssue] = []
            for issue in selected {
                details.append(try await self.client.issue(id: issue.id, connection: connection))
                try Task.checkCancellation()
            }
            try self.service.importIssues(details, connection: connection, column: column, projectPath: projectPath)
            self.onChange?()
        }
    }

    func syncAssignedIssues(links: [JiraTaskLink]) {
        guard let connection else { return }
        let linkedIDs = Set(links.filter { $0.cloudID == connection.cloudID }.map(\.issueID))
        perform {
            let issues = try await self.client.search(connection: connection)
            var details: [JiraIssue] = []
            for issue in issues {
                details.append(try await self.client.issue(id: issue.id, connection: connection))
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            try self.service.importIssues(details.filter { !linkedIDs.contains($0.id) }, connection: connection)
            self.issues = issues
            self.onChange?()
            try await self.refreshLinks(links, connection: connection, fetched: Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) }))
        }
    }

    func refresh(links: [JiraTaskLink]) {
        guard let connection else { return }
        perform { try await self.refreshLinks(links, connection: connection) }
    }

    private func refreshLinks(_ links: [JiraTaskLink], connection: JiraConnection, fetched: [String: JiraIssue] = [:]) async throws {
        var failed = 0
        for link in links where link.cloudID == connection.cloudID {
            try Task.checkCancellation()
            do {
                let issue: JiraIssue
                if let cached = fetched[link.issueID] { issue = cached }
                else { issue = try await client.issue(id: link.issueID, connection: connection) }
                try Task.checkCancellation()
                try service.refresh(issue, link: link)
            } catch JiraError.unavailable {
                try Task.checkCancellation()
                try service.markUnavailable(link)
                failed += 1
            }
            onChange?()
        }
        if failed == 0 { lastRefresh = .now }
        else { error = L10n.tr("jira.partial_refresh", "\(failed)") }
    }

    func detach(taskID: String) {
        do { try service.detach(taskID: taskID); onChange?() }
        catch { self.error = L10n.tr("jira.error.commandFailed") }
    }

    func disconnect() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        isBusy = false
        connection = nil
        issues = []
        error = nil
        lastRefresh = nil
        defaults.removeObject(forKey: Self.connectionKey)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        guard durable else { error = JiraError.databaseUnavailable.localizedDescription; return }
        isBusy = true
        error = nil
        let generation = generation
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.isBusy = false; self.operation = nil } }
            do { try await action() }
            catch is CancellationError { }
            catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                self.error = (error as? JiraError)?.localizedDescription ?? L10n.tr("jira.error.commandFailed")
            }
        }
    }
}
