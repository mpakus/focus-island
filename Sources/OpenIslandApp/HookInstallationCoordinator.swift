import Foundation
import Observation
import OpenIslandCore

@MainActor
@Observable
final class HookInstallationCoordinator {
    @ObservationIgnored
    let intentStore: AgentIntentStore

    init(
        intentStore: AgentIntentStore = AgentIntentStore()
    ) {
        self.intentStore = intentStore
    }

    var claudeHookStatus: ClaudeHookInstallationStatus? {
        didSet { onClaudeHookStatusChanged?() }
    }
    var codexHookStatus: CodexHookInstallationStatus? {
        didSet { onClaudeHookStatusChanged?() }
    }
    var codexHookError: String?
    var isCodexHookSetupBusy = false
    var codexHooksConfigured: Bool { codexHookStatus?.readyForVerification == true }
    var claudeStatusLineStatus: ClaudeStatusLineInstallationStatus?
    var claudeUsageSnapshot: ClaudeUsageSnapshot?
    var hooksBinaryURL: URL?
    var isClaudeHookSetupBusy = false
    var isClaudeUsageSetupBusy = false

    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    @ObservationIgnored
    var onClaudeHookStatusChanged: (() -> Void)?

    /// Computed so it always reflects the latest `ClaudeConfigDirectory` setting.
    private var claudeHookInstallationManager: ClaudeHookInstallationManager {
        ClaudeHookInstallationManager()
    }

    /// Computed so it always reflects the latest `ClaudeConfigDirectory` setting.
    private var claudeStatusLineInstallationManager: ClaudeStatusLineInstallationManager {
        ClaudeStatusLineInstallationManager()
    }

    @ObservationIgnored
    private var claudeUsageMonitorTask: Task<Void, Never>?

    @ObservationIgnored
    private var relativeTimestampFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LanguageManager.shared.locale
        formatter.unitsStyle = .short
        return formatter
    }

    // MARK: - Computed display properties

    var claudeHooksInstalled: Bool {
        claudeHookStatus?.managedHooksPresent == true
    }

    var claudeUsageInstalled: Bool {
        claudeStatusLineStatus?.managedStatusLineInstalled == true
    }

    var claudeStatusLineProvidedByOtherIsland: Bool {
        claudeStatusLineStatus?.providedByOtherIsland == true
    }

    static var statusLineProvidedByOtherIslandText: String { L10n.tr("focus.open_island_already_uses_the_status_line_focus_leaves_it_unchanged") }

    var claudeHookStatusTitle: String {
        if claudeHooksInstalled {
            return L10n.tr("ui.claude_hooks_installed")
        }

        if hooksBinaryURL == nil {
            return L10n.tr("ui.hook_binary_not_found")
        }

        return L10n.tr("ui.claude_hooks_not_installed")
    }

    var claudeHookStatusSummary: String {
        guard let status = claudeHookStatus else {
            return L10n.tr("ui.reading", "\(ClaudeConfigDirectory.resolved().appendingPathComponent("settings.json").path)")
        }

        if claudeHooksInstalled {
            if status.hasClaudeIslandHooks {
                return L10n.tr("ui.managed_hooks_present_claude_island_hooks_also_detected")
            }
            return L10n.tr("ui.managed_hooks_present")
        }

        if hooksBinaryURL == nil {
            return L10n.tr("ui.build_openislandhooks_before_installing")
        }

        if status.hasClaudeIslandHooks {
            return L10n.tr("ui.claude_island_hooks_detected_managed_hooks_absent")
        }

        return L10n.tr("ui.no_managed_claude_hooks")
    }

    var claudeUsageStatusTitle: String {
        guard let status = claudeStatusLineStatus else {
            return L10n.tr("ui.claude_usage_status_unavailable")
        }

        if status.providedByOtherIsland && !status.managedStatusLineInstalled {
            return Self.statusLineProvidedByOtherIslandText
        }

        if status.managedStatusLineInstalled {
            return L10n.tr("ui.claude_usage_bridge_installed")
        }

        if status.managedStatusLineNeedsRepair {
            return L10n.tr("ui.claude_usage_bridge_needs_repair")
        }

        if status.hasConflictingStatusLine {
            return L10n.tr("ui.custom_claude_status_line_detected")
        }

        return L10n.tr("ui.claude_usage_bridge_not_installed")
    }

    var claudeUsageStatusSummary: String {
        guard let status = claudeStatusLineStatus else {
            return L10n.tr("ui.reading", "\(ClaudeConfigDirectory.resolved().appendingPathComponent("settings.json").path)")
        }

        if status.managedStatusLineInstalled {
            if let summary = claudeUsageSummaryText {
                return L10n.tr("ui.caching_rate_limits_from_claude_code", "\(summary)")
            }
            return L10n.tr("ui.caching_rate_limits_from_claude_code_into", "\(status.cacheURL.path)")
        }

        if status.providedByOtherIsland {
            return Self.statusLineProvidedByOtherIslandText
        }

        if status.managedStatusLineNeedsRepair {
            return L10n.tr("ui.open_island_detected_a_missing_managed_claude_status_line_script_and_will_r")
        }

        if status.hasConflictingStatusLine {
            return L10n.tr("ui.open_island_will_not_overwrite_an_existing_claude_status_line_automatically")
        }

        return L10n.tr("ui.install_a_managed_claude_status_line_to_cache_5h_and_7d_usage_locally")
    }

    var claudeUsageSummaryText: String? {
        guard let snapshot = claudeUsageSnapshot else {
            return nil
        }

        var components: [String] = []
        if let fiveHour = snapshot.fiveHour {
            components.append(L10n.tr("usage.fiveHours", "\(fiveHour.roundedUsedPercentage)"))
        }
        if let sevenDay = snapshot.sevenDay {
            components.append(L10n.tr("usage.sevenDays", "\(sevenDay.roundedUsedPercentage)"))
        }
        if let cachedAt = snapshot.cachedAt {
            components.append(L10n.tr("ui.updated", "\(relativeTimestampFormatter.localizedString(for: cachedAt, relativeTo: .now))"))
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    // MARK: - Claude config directory

    /// Updates the custom Claude config directory, cleans up old hooks if present, and refreshes status.
    func updateClaudeConfigDirectory(to newDirectory: URL?) {
        let oldDirectory = ClaudeConfigDirectory.resolved()
        let oldHadHooks = claudeHookStatus?.managedHooksPresent == true

        ClaudeConfigDirectory.customDirectory = newDirectory

        // Refresh status from the new directory
        refreshClaudeHookStatus()
        refreshClaudeUsageState()

        let newPath = ClaudeConfigDirectory.resolved().path
        if oldHadHooks {
            let oldPath = oldDirectory.path
            if oldPath != newPath {
                onStatusMessage?(L10n.tr("ui.claude_config_directory_changed_to_hooks_in_were_not_removed_uninstall_them", "\(newPath)", "\(oldPath)"))
            }
        } else {
            onStatusMessage?(L10n.tr("ui.claude_config_directory_set_to", "\(newPath)"))
        }
    }

    // MARK: - Auto-update hooks binary

    /// Overwrites the installed hooks binary if the app bundle ships a newer version.
    /// Call once at startup after hooksBinaryURL is set.
    func updateHooksBinaryIfNeeded() {
        guard let sourceURL = hooksBinaryURL else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let source = sourceURL
                let updated = try await Task.detached(priority: .utility) {
                    try ManagedHooksBinary.updateIfNeeded(from: source)
                }.value
                if updated {
                    self.onStatusMessage?(L10n.tr("ui.hooks_binary_updated_to_match_the_current_app_version"))
                    self.refreshClaudeHookStatus()
                }
            } catch {
                self.onStatusMessage?(L10n.tr("ui.failed_to_update_hooks_binary", "\(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Health check & auto-repair

    var claudeHealthReport: HookHealthReport?

    /// Every report produced by the last check, in display order.
    var healthReports: [HookHealthReport] {
        [claudeHealthReport].compactMap(\.self)
    }

    /// Refreshes both agents; Codex trust and live delivery still require verification in Codex.
    func runHealthChecks() {
        refreshCodexHookStatus()
        Task { @MainActor [weak self] in
            guard let self else { return }

            let binaryURL = self.hooksBinaryURL
            let claudeReport = await Task.detached(priority: .utility) {
                HookHealthCheck.checkClaude(hooksBinaryURL: binaryURL)
            }.value

            self.claudeHealthReport = claudeReport

            if !claudeReport.isHealthy {
                self.onStatusMessage?(L10n.tr("ui.hook_health_check_claude_issue_s", "\(claudeReport.errors.count)"))
            }
        }
    }

    /// Attempts to auto-repair repairable issues by re-installing hooks.
    /// Returns true if any repairs were attempted.
    @discardableResult
    func repairHooksIfNeeded() async -> Bool {
        var repaired = false

        // Re-run health checks first
        let binaryURL = hooksBinaryURL
        let claudeReport = await Task.detached(priority: .utility) {
            HookHealthCheck.checkClaude(hooksBinaryURL: binaryURL)
        }.value

        claudeHealthReport = claudeReport

        // Repair Claude hooks if there are repairable issues
        if !claudeReport.repairableIssues.isEmpty, hooksBinaryURL != nil {
            onStatusMessage?(L10n.tr("ui.repairing_claude_hooks", "\(claudeReport.repairableIssues.map(\.description).joined(separator: "; "))"))
            installClaudeHooks()
            repaired = true
        }

        // Refresh health reports after repair
        if repaired {
            try? await Task.sleep(for: .milliseconds(500))
            let updatedClaude = await Task.detached(priority: .utility) {
                HookHealthCheck.checkClaude(hooksBinaryURL: binaryURL)
            }.value
            claudeHealthReport = updatedClaude

            if updatedClaude.isHealthy {
                onStatusMessage?(L10n.tr("ui.hook_repair_completed_successfully"))
            } else {
                onStatusMessage?(L10n.tr("ui.hook_repair_finished_with_remaining_issue_s", "\(updatedClaude.errors.count)"))
            }
        }

        return repaired
    }

    // MARK: - Refresh

    func refreshClaudeHookStatus() {
        Task { [weak self] in
            guard let self else { return }

            do {
                let status = try self.claudeHookInstallationManager.status(hooksBinaryURL: self.hooksBinaryURL)
                self.claudeHookStatus = status
            } catch {
                self.onStatusMessage?(L10n.tr("ui.failed_to_read_claude_hook_status", "\(error.localizedDescription)"))
            }
        }
    }

    /// Awaitable versions of refresh for use in startup flow to avoid race conditions.
    func refreshAllHookStatusAndWait() async {
        refreshCodexHookStatus()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let status = try self.claudeHookInstallationManager.status(hooksBinaryURL: self.hooksBinaryURL)
                    self.claudeHookStatus = status
                } catch {
                    self.onStatusMessage?(L10n.tr("ui.failed_to_read_claude_hook_status", "\(error.localizedDescription)"))
                }
            }

            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let usageState = try self.readClaudeUsageState(repairManagedBridgeIfNeeded: true)
                    self.claudeStatusLineStatus = usageState.status
                    self.claudeUsageSnapshot = usageState.snapshot
                } catch {
                    self.onStatusMessage?(L10n.tr("ui.failed_to_read_claude_usage_state", "\(error.localizedDescription)"))
                }
            }
        }
    }

    func refreshClaudeUsageState() {
        let manager = claudeStatusLineInstallationManager
        Task { [weak self] in
            guard let self else { return }

            do {
                let usageState = try await Task.detached(priority: .utility) {
                    var status = try manager.status()
                    var repairedManagedBridge = false
                    if status.shouldAutoRepair {
                        status = try manager.install()
                        repairedManagedBridge = true
                    }
                    let snapshot = try ClaudeUsageLoader.load()
                    return (status: status, snapshot: snapshot, repairedManagedBridge: repairedManagedBridge)
                }.value
                self.claudeStatusLineStatus = usageState.status
                self.claudeUsageSnapshot = usageState.snapshot
                if usageState.repairedManagedBridge {
                    self.onStatusMessage?(L10n.tr("ui.recovered_the_claude_usage_bridge_after_repairing_a_missing_managed_script"))
                }
            } catch {
                self.onStatusMessage?(L10n.tr("ui.failed_to_read_claude_usage_state", "\(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Intent-aware helpers

    /// Reports whether the startup flow should auto-install hooks for the
    /// given agent.
    ///
    /// Post-onboarding, the only case that triggers auto-install is
    /// `.installed && !present` — i.e. the user asked for this hook in the
    /// past but it is currently missing (fresh machine, config wiped,
    /// upgraded binary path, etc). This is a repair, not a surprise
    /// install. `.untouched` and `.uninstalled` both return false;
    /// untouched agents are surfaced to the user via the first-run
    /// onboarding window and the empty-state banner instead.
    func shouldAutoInstall(_ agent: AgentIdentifier) -> Bool {
        guard intentStore.intent(for: agent) == .installed else {
            return false
        }

        switch agent {
        case .codex: return false // Codex connection and repair stay explicit because changed hooks need trust review.
        case .claudeCode: return !claudeHooksInstalled
        case .claudeUsageBridge: return !claudeUsageInstalled && !claudeStatusLineProvidedByOtherIsland
        }
    }

    // MARK: - Intent store migration

    /// Reconciles the persisted intent store with the hook status currently
    /// observed on disk. Must be called only after
    /// `refreshAllHookStatusAndWait()` has returned, otherwise every agent
    /// will be recorded as `.untouched` and legacy users will have their
    /// installed hooks silently forgotten.
    func migrateIntentStoreIfNeeded() {
        intentStore.migrateFromLegacyStateIfNeeded { [self] agent in
            switch agent {
            case .codex: return codexHooksConfigured
            case .claudeCode: return claudeHooksInstalled
            case .claudeUsageBridge: return claudeUsageInstalled
            }
        }
    }

    // MARK: - Install / uninstall

    func refreshCodexHookStatus() {
        do {
            codexHookStatus = try CodexHookInstallationManager().status()
            codexHookError = nil
        } catch {
            codexHookError = error.localizedDescription
            codexHookStatus = nil
        }
    }

    func updateCodexHooks(install: Bool) {
        guard !isCodexHookSetupBusy else { return }
        if install && hooksBinaryURL == nil {
            codexHookError = L10n.tr("ui.build_openislandhooks_before_connecting_codex")
            return
        }
        isCodexHookSetupBusy = true
        defer { isCodexHookSetupBusy = false }
        do {
            let manager = CodexHookInstallationManager()
            if install, let binary = hooksBinaryURL {
                codexHookStatus = try manager.install(hooksBinaryURL: binary)
            } else {
                codexHookStatus = try manager.uninstall()
            }
            intentStore.setIntent(install ? .installed : .uninstalled, for: .codex)
            codexHookError = nil
            onStatusMessage?(install
                ? L10n.tr("ui.codex_configured_review_hooks_in_codex_then_send_a_prompt_to_verify_monitor")
                : L10n.tr("ui.codex_monitoring_hooks_removed"))
        } catch {
            codexHookError = error.localizedDescription
            onStatusMessage?(error.localizedDescription)
        }
    }

    func installClaudeHooks() {
        guard let hooksBinaryURL else {
            onStatusMessage?(L10n.tr("ui.could_not_find_a_local_openislandhooks_binary_build_the_package_first"))
            return
        }

        updateClaudeHooks(userMessage: L10n.tr("ui.installing_claude_hooks"), intent: .installed) { manager in
            try manager.install(hooksBinaryURL: hooksBinaryURL)
        }
    }

    func uninstallClaudeHooks() {
        updateClaudeHooks(userMessage: L10n.tr("ui.removing_claude_hooks"), intent: .uninstalled) { manager in
            try manager.uninstall()
        }
    }

    func installClaudeUsageBridge() {
        if claudeStatusLineProvidedByOtherIsland {
            onStatusMessage?(Self.statusLineProvidedByOtherIslandText)
            return
        }
        updateClaudeUsageBridge(userMessage: L10n.tr("ui.installing_claude_usage_bridge"), intent: .installed) { manager in
            do {
                return try manager.install()
            } catch ClaudeStatusLineInstallationError.existingStatusLineConflict {
                // User already has a custom statusLine (e.g. claude-hud). Install as a
                // wrapper so their script keeps running and we still get rate_limits.
                return try manager.installAsWrapper()
            }
        }
    }

    func uninstallClaudeUsageBridge() {
        updateClaudeUsageBridge(userMessage: L10n.tr("ui.removing_claude_usage_bridge"), intent: .uninstalled) { manager in
            try manager.uninstall()
        }
    }

    // MARK: - Monitoring

    func startClaudeUsageMonitoringIfNeeded() {
        guard claudeUsageMonitorTask == nil else { return }

        claudeUsageMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                self.refreshClaudeUsageState()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Internal: readClaudeUsageState

    nonisolated func readClaudeUsageState(
        repairManagedBridgeIfNeeded: Bool
    ) throws -> (
        status: ClaudeStatusLineInstallationStatus,
        snapshot: ClaudeUsageSnapshot?,
        repairedManagedBridge: Bool
    ) {
        let manager = ClaudeStatusLineInstallationManager()
        var status = try manager.status()
        var repairedManagedBridge = false

        if repairManagedBridgeIfNeeded && status.shouldAutoRepair {
            status = try manager.install()
            repairedManagedBridge = true
        }

        let snapshot = try ClaudeUsageLoader.load()
        return (status, snapshot, repairedManagedBridge)
    }

    // MARK: - Private helpers

    private func updateClaudeHooks(
        userMessage: String,
        intent: AgentHookIntent,
        operation: @escaping (ClaudeHookInstallationManager) throws -> ClaudeHookInstallationStatus
    ) {
        isClaudeHookSetupBusy = true
        onStatusMessage?(userMessage)

        Task { [weak self] in
            guard let self else { return }

            defer { self.isClaudeHookSetupBusy = false }

            do {
                let status = try operation(self.claudeHookInstallationManager)
                self.claudeHookStatus = status
                self.intentStore.setIntent(intent, for: .claudeCode)
                if status.managedHooksPresent {
                    self.onStatusMessage?(status.hasClaudeIslandHooks
                        ? L10n.tr("ui.claude_hooks_are_installed_claude_island_hooks_are_also_still_present")
                        : L10n.tr("ui.claude_hooks_are_installed_and_ready"))
                } else {
                    self.onStatusMessage?(L10n.tr("ui.claude_hooks_are_not_installed"))
                }
            } catch {
                self.onStatusMessage?(L10n.tr("ui.claude_hook_update_failed", "\(error.localizedDescription)"))
            }
        }
    }

    private func updateClaudeUsageBridge(
        userMessage: String,
        intent: AgentHookIntent,
        operation: @escaping (ClaudeStatusLineInstallationManager) throws -> ClaudeStatusLineInstallationStatus
    ) {
        isClaudeUsageSetupBusy = true
        onStatusMessage?(userMessage)

        Task { [weak self] in
            guard let self else { return }

            defer { self.isClaudeUsageSetupBusy = false }

            do {
                let status = try operation(self.claudeStatusLineInstallationManager)
                self.claudeStatusLineStatus = status
                self.claudeUsageSnapshot = try ClaudeUsageLoader.load()
                self.intentStore.setIntent(intent, for: .claudeUsageBridge)
                if status.managedStatusLineInstalled {
                    if status.managedStatusLineIsWrapper {
                        self.onStatusMessage?(L10n.tr("ui.claude_usage_bridge_installed_in_wrapper_mode_your_existing_statusline_is_p"))
                    } else {
                        self.onStatusMessage?(L10n.tr("ui.claude_usage_bridge_is_installed_start_a_claude_code_turn_to_refresh_cached"))
                    }
                } else {
                    self.onStatusMessage?(L10n.tr("ui.claude_usage_bridge_is_not_installed"))
                }
            } catch {
                self.onStatusMessage?(L10n.tr("ui.claude_usage_bridge_update_failed", "\(error.localizedDescription)"))
            }
        }
    }
}
