import Foundation
import Observation
import OpenIslandCore

@MainActor
@Observable
final class CodexUsageCoordinator {
    private(set) var snapshot: CodexUsageSnapshot?
    private(set) var error: String?
    private(set) var isRefreshing = false
    @ObservationIgnored private(set) var operation: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private let read: @Sendable () async throws -> CodexUsageSnapshot

    init(read: @escaping @Sendable () async throws -> CodexUsageSnapshot = { try await CodexUsageClient.read() }) { self.read = read }
    deinit { monitor?.cancel(); operation?.cancel() }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        operation = Task { [weak self, read] in
            do {
                let snapshot = try await read()
                try Task.checkCancellation()
                self?.snapshot = snapshot; self?.error = nil
            } catch is CancellationError { }
            catch {
                self?.snapshot = nil
                self?.error = (error as? CodexUsageError ?? .unavailable).localizedDescription
            }
            self?.isRefreshing = false; self?.operation = nil
        }
    }

    func start() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: .seconds(120)) } catch { break }
            }
        }
    }
}
