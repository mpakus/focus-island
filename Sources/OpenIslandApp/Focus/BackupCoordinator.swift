import FocusCore
import Foundation
import Observation

@MainActor
@Observable
final class BackupCoordinator {
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var lastBackup: Date?
    private(set) var preview: BackupPreview?
    private(set) var restoreReady = false
    @ObservationIgnored private(set) var operation: Task<Void, Never>?
    @ObservationIgnored private let service: FocusBackups?
    @ObservationIgnored private var lastAutomaticCheck: Date?

    var available: Bool { service != nil }
    var directory: URL? { service?.directory }

    init(store: FocusStore, durable: Bool) {
        service = durable ? try? FocusBackups(store: store) : nil
        error = store.restoreError
        lastBackup = try? service?.latestBackupDate()
    }

    func tick(now: Date, enabled: Bool) {
        guard enabled, available, !isBusy, !restoreReady,
              lastAutomaticCheck.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastAutomaticCheck = now
        perform(clearError: false) { service in try service.daily(now: now); return nil }
    }

    func create() { perform { service in _ = try service.create(); return nil } }
    func export(to url: URL) { perform { service in try service.export(to: url); return nil } }
    func inspect(_ url: URL) {
        guard !isBusy else { return }
        discardPreview()
        perform { try $0.preview(url) }
    }

    func discardPreview() {
        guard !isBusy else { return }
        if let preview { service?.discard(preview) }
        preview = nil
    }

    func stageRestore() {
        guard let preview, let service, !isBusy, !restoreReady else { return }
        isBusy = true; error = nil
        operation = Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) { try service.stage(preview) }.value
                self?.preview = nil
                self?.restoreReady = true
            } catch { self?.error = error.localizedDescription }
            self?.isBusy = false
        }
    }

    private func perform(clearError: Bool = true, _ work: @escaping @Sendable (FocusBackups) throws -> BackupPreview?) {
        guard let service, !isBusy, !restoreReady else { return }
        isBusy = true
        if clearError { error = nil }
        operation = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    let preview = try work(service)
                    return (preview, try service.latestBackupDate())
                }.value
                if let preview = result.0 { self?.preview = preview }
                self?.lastBackup = result.1
            } catch { self?.error = error.localizedDescription }
            self?.isBusy = false
        }
    }
}
