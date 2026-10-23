import AppKit
import FocusCore
import Foundation
import Observation
import OpenIslandCore

@MainActor
@Observable
final class JiraCoordinator {
    private(set) var connection: JiraConnection?
    private(set) var usesCLI: Bool
    private(set) var issues: [JiraIssue] = []
    private(set) var isBusy = false
    private(set) var isAuthorizing = false
    private(set) var error: String?
    private(set) var lastRefresh: Date?
    @ObservationIgnored private(set) var operation: Task<Void, Never>?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let browserClient: any JiraProviding
    @ObservationIgnored private let cliClient: any JiraProviding
    private var client: any JiraProviding { usesCLI ? cliClient : browserClient }
    @ObservationIgnored private let service: JiraTaskService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let durable: Bool
    @ObservationIgnored private var generation = UUID()
    static let connectionKey = "focus.jira.browserConnection"
    private static let cliKey = "focus.jira.useCLI"

    init(store: FocusStore, defaults: UserDefaults, durable: Bool, client: (any JiraProviding)? = nil, cliClient: any JiraProviding = JiraCLIClient()) {
        browserClient = client ?? JiraBrowserAuthorization.client()
        self.cliClient = cliClient
        usesCLI = defaults.bool(forKey: Self.cliKey)
        service = JiraTaskService(store: store)
        self.defaults = defaults
        self.durable = durable
        if let data = defaults.data(forKey: Self.connectionKey),
           let saved = try? JSONDecoder().decode(JiraConnection.self, from: data),
           (try? JiraConnection.canonicalSite(saved.site)) == saved.site, UUID(uuidString: saved.cloudID) != nil {
            connection = saved
        }
    }

    func connect(authorize: Bool = false) {
        perform(authorizing: authorize) {
            let connection = try await (authorize ? self.client.authorize() : self.client.connect())
            // Verify issue access before publishing the connection.
            let issues = try await self.client.search(connection: connection)
            try Task.checkCancellation()
            self.defaults.set(try JSONEncoder().encode(connection), forKey: Self.connectionKey)
            self.defaults.set(self.usesCLI, forKey: Self.cliKey)
            self.connection = connection
            self.issues = issues
            if authorize { NSApp?.activate() }
        }
    }

    func authorize() {
        guard !isBusy else { return }
        disconnect()
        guard error == nil else { return }
        connect(authorize: true)
    }

    func connectUsingCLI() {
        guard !isBusy else { return }
        disconnect()
        guard error == nil else { return }
        usesCLI = true
        connect()
    }

    func reconnect() {
        if usesCLI { connectUsingCLI() }
        else { authorize() }
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
        isAuthorizing = false
        connection = nil
        usesCLI = false
        issues = []
        error = nil
        lastRefresh = nil
        defaults.removeObject(forKey: Self.connectionKey)
        defaults.removeObject(forKey: Self.cliKey)
        defaults.removeObject(forKey: "focus.jira.connection")
        for client in [browserClient, cliClient] {
            do { try client.disconnect() }
            catch { self.error = JiraError.credentialsUnavailable.localizedDescription }
        }
    }

    private func perform(authorizing: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        guard durable else { error = JiraError.databaseUnavailable.localizedDescription; return }
        isBusy = true
        isAuthorizing = authorizing
        error = nil
        let generation = generation
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.isBusy = false; self.isAuthorizing = false; self.operation = nil } }
            do { try await action() }
            catch is CancellationError { }
            catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                self.error = (error as? JiraError)?.localizedDescription ?? L10n.tr("jira.error.commandFailed")
            }
        }
    }
}
