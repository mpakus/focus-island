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

    func refresh(links: [JiraTaskLink]) {
        guard let connection else { return }
        let links = links.filter { $0.cloudID == connection.cloudID }
        perform {
            var failed = 0
            for link in links {
                try Task.checkCancellation()
                do {
                    let issue = try await self.client.issue(id: link.issueID, connection: connection)
                    try Task.checkCancellation()
                    try self.service.refresh(issue, link: link)
                } catch JiraError.unavailable {
                    try Task.checkCancellation()
                    try self.service.markUnavailable(link)
                    failed += 1
                }
                self.onChange?()
            }
            if failed == 0 { self.lastRefresh = .now }
            else { self.error = L10n.tr("jira.partial_refresh", "\(failed)") }
        }
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
