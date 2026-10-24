import AppKit
import FocusCore
import Observation
import OpenIslandCore

@MainActor
@Observable
final class ClickUpCoordinator {
    private(set) var connection: ClickUpConnection?
    private(set) var tasks: [ClickUpTask] = []
    private(set) var isBusy = false
    private(set) var isAuthorizing = false
    private(set) var error: String?
    private(set) var lastRefresh: Date?
    @ObservationIgnored private(set) var operation: Task<Void, Never>?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let client: any ClickUpProviding
    @ObservationIgnored private let service: ClickUpTaskService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let durable: Bool
    @ObservationIgnored private var generation = UUID()
    static let connectionKey = "focus.clickup.connection"

    init(store: FocusStore, defaults: UserDefaults, durable: Bool, client: (any ClickUpProviding)? = nil) {
        self.client = client ?? Self.browserClient()
        service = ClickUpTaskService(store: store)
        self.defaults = defaults; self.durable = durable
        if let data = defaults.data(forKey: Self.connectionKey),
           let saved = try? JSONDecoder().decode(ClickUpConnection.self, from: data), (try? saved.validate()) != nil { connection = saved }
    }

    static func browserClient() -> ClickUpMCPClient {
        ClickUpMCPClient(credentials: IntegrationKeychain(service: "\(Bundle.main.bundleIdentifier ?? "dev.zhanabayev.focusisland").clickup"), browser: { url in
            try await MainActor.run {
                guard NSWorkspace.shared.open(url) else { throw ClickUpError.commandFailed }
            }
        })
    }

    func connect(authorize: Bool = false) {
        perform(authorizing: authorize) {
            let connection = try await (authorize ? self.client.authorize() : self.client.connect())
            try Task.checkCancellation()
            self.defaults.set(try JSONEncoder().encode(connection), forKey: Self.connectionKey)
            self.connection = connection
            if authorize { NSApp?.activate() }
        }
    }

    func reconnect() {
        guard !isBusy else { return }
        disconnect()
        if error == nil { connect(authorize: true) }
    }

    func loadTasks() {
        guard let connection else { return }
        perform {
            let tasks = try await self.client.search(connection: connection)
            try Task.checkCancellation()
            self.tasks = tasks
        }
    }

    func importTasks(ids: Set<String>, column: BoardColumn, projectPath: String?) {
        guard let connection, !ids.isEmpty else { return }
        guard ids.isSubset(of: Set(tasks.map(\.id))) else { error = ClickUpError.invalidResponse.localizedDescription; return }
        perform {
            let results = try await self.client.tasks(ids: ids.sorted(), connection: connection)
            let tasks = try Self.available(results, expected: ids)
            guard tasks.allSatisfy({ $0.unfinished && $0.assigneeIDs.contains(connection.userID) }) else { throw ClickUpError.invalidResponse }
            try Task.checkCancellation()
            try self.service.importTasks(tasks, connection: connection, column: column, projectPath: projectPath)
            self.onChange?()
        }
    }

    func syncAssignedTasks(links: [ClickUpTaskLink]) {
        guard let connection else { return }
        let linked = links.filter { $0.workspaceID == connection.workspaceID }
        let linkedIDs = Set(linked.map(\.remoteTaskID))
        perform {
            let tasks = try await self.client.search(connection: connection)
            guard Set(tasks.map(\.id)).count == tasks.count else { throw ClickUpError.invalidResponse }
            try Task.checkCancellation()
            try self.service.importTasks(tasks.filter { !linkedIDs.contains($0.id) }, connection: connection)
            self.tasks = tasks
            self.onChange?()
            try await self.refreshLinks(linked, connection: connection, fetched: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) }))
        }
    }

    func refresh(links: [ClickUpTaskLink]) {
        guard let connection else { return }
        perform { try await self.refreshLinks(links.filter { $0.workspaceID == connection.workspaceID }, connection: connection) }
    }

    private func refreshLinks(_ links: [ClickUpTaskLink], connection: ClickUpConnection, fetched: [String: ClickUpTask] = [:]) async throws {
        let missing = links.map(\.remoteTaskID).filter { fetched[$0] == nil }
        var results = fetched.map { ClickUpTaskResult.task($0.value) }
        if !missing.isEmpty { results += try await client.tasks(ids: missing, connection: connection) }
        let byID = Dictionary(grouping: results, by: \.id)
        var unavailable = 0
        for link in links {
            try Task.checkCancellation()
            guard let values = byID[link.remoteTaskID], values.count == 1 else { throw ClickUpError.invalidResponse }
            switch values[0] {
            case .task(let task): try service.refresh(task, link: link)
            case .unavailable: try service.markUnavailable(link); unavailable += 1
            }
            onChange?()
        }
        if unavailable == 0 { lastRefresh = .now }
        else { error = L10n.tr("clickup.partial_refresh", "\(unavailable)") }
    }

    private static func available(_ results: [ClickUpTaskResult], expected: Set<String>) throws -> [ClickUpTask] {
        guard results.count == expected.count, Set(results.map(\.id)) == expected else { throw ClickUpError.invalidResponse }
        return try results.map { guard case let .task(task) = $0 else { throw ClickUpError.unavailable }; return task }
    }

    func detach(taskID: String) {
        do { try service.detach(taskID: taskID); onChange?() }
        catch { self.error = ClickUpError.commandFailed.localizedDescription }
    }

    func disconnect() {
        generation = UUID()
        operation?.cancel(); operation = nil
        isBusy = false; isAuthorizing = false
        connection = nil; tasks = []; error = nil; lastRefresh = nil
        defaults.removeObject(forKey: Self.connectionKey)
        do { try client.disconnect() }
        catch { self.error = L10n.tr("clickup.credentials_unavailable") }
    }

    private func perform(authorizing: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        guard durable else { error = ClickUpError.databaseUnavailable.localizedDescription; return }
        isBusy = true; isAuthorizing = authorizing; error = nil
        let generation = generation
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.isBusy = false; self.isAuthorizing = false; self.operation = nil } }
            do { try await action() }
            catch is CancellationError { }
            catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                self.error = error is IntegrationCredentialError ? L10n.tr("clickup.credentials_unavailable")
                    : ((error as? ClickUpError)?.localizedDescription ?? L10n.tr("clickup.error.commandFailed"))
            }
        }
    }
}
