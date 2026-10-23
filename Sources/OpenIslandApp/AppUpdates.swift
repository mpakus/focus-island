import Combine
import Foundation
import Observation
import OpenIslandCore
import Sparkle

@MainActor
@Observable
final class AppUpdates: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdates()
    private(set) var canCheck = false
    private(set) var status = L10n.tr("updates.installed_only")
    private(set) var availableVersion: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: AnyCancellable?

    func start() {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              ProcessInfo.processInfo.environment["OPEN_ISLAND_HARNESS_SCENARIO"] == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            MainActor.assumeIsolated { self?.canCheck = value }
        }
        controller.startUpdater()
        status = L10n.tr("updates.ready")
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func check(showInstaller: Bool = false) {
        start()
        guard canCheck, let updater = controller?.updater else { return }
        status = L10n.tr("updates.checking")
        if showInstaller { updater.checkForUpdates() }
        else { updater.checkForUpdateInformation() }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        status = L10n.tr("updates.available", item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
        status = L10n.tr("updates.current")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error, (error as NSError).code != SUError.noUpdateError.rawValue { status = L10n.tr("updates.failed") }
    }
}
