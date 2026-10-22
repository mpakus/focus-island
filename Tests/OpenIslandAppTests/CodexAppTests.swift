import FocusCore
import Foundation
@testable import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct CodexAppTests {
    @Test func codexOnlySetupCountsAsInstalledButWaitsForLiveVerification() throws {
        let model = AppModel(focusStore: try FocusStore.inMemory(), claudeRegistry: .temporaryForTesting(), runBackfill: false)
        #expect(!model.hasAnyInstalledAgent)
        #expect(model.onboardingAgent == .claudeCode)
        model.hooks.codexHookStatus = CodexHookInstallationStatus(
            configURL: URL(fileURLWithPath: "/tmp/codex-fixture/hooks.json"),
            configured: true, binaryAvailable: true, inlineConflict: false
        )
        #expect(!model.claudeHooksInstalled)
        #expect(model.hasAnyInstalledAgent)
        #expect(model.codexHooksInstalled && model.codexHooksConfigured)
        #expect(model.onboardingAgent == .codex)
        #expect(model.codexHookStatusText == model.lang.t("setup.codex.awaitingEvents"))
        model.state = SessionState(sessions: [session("live")])
        #expect(model.codexHookStatusText == model.lang.t("setup.codex.receiving"))
    }

    @Test func codexSetupKeepsRemovalAvailableWhenHelperNeedsRepair() throws {
        let model = AppModel(focusStore: try FocusStore.inMemory(), claudeRegistry: .temporaryForTesting(), runBackfill: false)
        model.hooks.codexHookStatus = CodexHookInstallationStatus(
            configURL: URL(fileURLWithPath: "/tmp/codex-fixture/hooks.json"),
            configured: true, binaryAvailable: false, inlineConflict: false
        )
        #expect(model.hasAnyInstalledAgent && model.codexHooksInstalled)
        #expect(!model.codexHooksConfigured)
        #expect(model.codexHookStatusText == model.lang.t("setup.codex.helperUnavailable"))
        model.hooks.codexHookStatus?.inlineConflict = true
        #expect(model.codexHookStatusText == model.lang.t("setup.codex.conflict"))
    }

    func session(_ id: String, phase: SessionPhase = .running, at date: Date = .now) -> AgentSession {
        var session = AgentSession(id: "codex:\(id)", title: "Codex", tool: .codex, origin: .live, attachmentState: .attached, phase: phase, summary: "Codex work", updatedAt: date,
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "Codex", workingDirectory: "/tmp"), codexMetadata: CodexSessionMetadata(sessionID: id, lastEventAt: date))
        session.isHookManaged = true
        return session
    }

    @Test func sameDirectorySessionsStayDistinctAndProcessPollingCannotEndThem() throws {
        let model = AppModel(focusStore: try FocusStore.inMemory(), claudeRegistry: .temporaryForTesting())
        model.state = SessionState(sessions: [session("a"), session("b")])
        #expect(model.islandListSessions.count == 2)
        model.monitoring.reconcileSessionAttachments(activeProcesses: [], ghosttyAvailability: .available([], appIsRunning: false), terminalAvailability: .available([], appIsRunning: false), preResolvedJumpTargets: [:])
        #expect(model.state.sessions.count == 2)
        #expect(model.state.sessions.allSatisfy { !$0.isSessionEnded && $0.phase == .running })
    }

    @Test func staleCodexOnlyReconcileNotifiesFocusAndPersistence() {
        let monitor = ProcessMonitoringCoordinator()
        var state = SessionState(sessions: [session("a", at: .now.addingTimeInterval(-1_000))])
        var reconciled = 0
        var persisted = 0
        monitor.stateAccessor = { state }
        monitor.stateUpdater = { state = $0 }
        monitor.onSessionsReconciled = { reconciled += 1 }
        monitor.onPersistenceNeeded = { persisted += 1 }
        monitor.reconcileSessionAttachments(activeProcesses: [], preResolvedJumpTargets: [:])
        #expect(state.session(id: "codex:a")?.codexMetadata?.isStale == true)
        #expect(state.session(id: "codex:a")?.phase == .idle)
        #expect(reconciled == 1 && persisted == 1)
    }

    @Test func codexQueuedPromptCopiesAndDoesNotReachInjectedSender() async throws {
        let h = try FocusCoordinatorCardTests().make(sendResult: .sent)
        let c = h.coordinator
        let now = Date(timeIntervalSince1970: 80_000)
        c.sessionsDidChange([session("a", at: now)], now: now)
        c.perform(.queuePrompt(sessionID: "codex:a", text: "Continue"), now: now.addingTimeInterval(1))
        c.sessionsDidChange([session("a", phase: .completed, at: now.addingTimeInterval(30))], now: now.addingTimeInterval(30))
        await c.performAsync(.sendQueuedPrompt(sessionID: "codex:a"), now: now.addingTimeInterval(40))
        #expect(h.sender.sent.isEmpty)
        #expect(h.clipboard.items == ["Continue"])
        #expect(c.queuedPrompt(sessionID: "codex:a")?.text == "Continue")
        #expect(h.jumps.ids == ["codex:a"])
    }

    @Test func focusCountsCodexWorkAndLeavesIdleUncounted() throws {
        let helper = FocusCoordinatorSpanTests()
        let (c, store) = try helper.make()
        let now = helper.t0
        c.sessionsDidChange([session("a", at: now)], now: now)
        c.sessionsDidChange([session("a", phase: .idle, at: now.addingTimeInterval(30))], now: now.addingTimeInterval(30))
        let spans = try helper.spans(store)
        #expect(spans.count == 1 && spans.first?.kind == .codex)
        #expect(spans.first?.endedAt == now.addingTimeInterval(30))
        let report = try #require(c.dayReport(day: now, now: now.addingTimeInterval(60)))
        #expect(report.codexSeconds == 30 && report.agentSeconds == 30 && report.claudeSeconds == 0)
    }

    @Test func handlersAndTerminalRepliesRejectCodex() throws {
        let model = AppModel(focusStore: try FocusStore.inMemory(), claudeRegistry: .temporaryForTesting())
        var codex = session("a", phase: .waitingForApproval)
        codex.permissionRequest = PermissionRequest(title: "Approve", summary: "Review in Codex", affectedPath: "", primaryActionTitle: "Open", requiresTerminalApproval: true)
        model.state = SessionState(sessions: [codex])
        model.approvePermission(for: codex.id, approved: true)
        model.approvePermission(for: codex.id, approved: false)
        #expect(model.state.session(id: codex.id)?.phase == .waitingForApproval)
        codex.phase = .completed
        codex.jumpTarget?.terminalApp = "Ghostty"
        #expect(!TerminalTextSender.canReply(to: codex, enabled: true))
        #expect(!TerminalTextSender.send("never send", to: codex))
    }

    @Test func identicalPromptsInDistinctTurnsRestartDuration() throws {
        let helper = FocusCoordinatorSpanTests()
        let (c, _) = try helper.make()
        let now = helper.t0
        var codex = session("a", at: now)
        codex.codexMetadata?.lastUserPrompt = "Continue"
        codex.codexMetadata?.turnID = "first"
        c.sessionsDidChange([codex], now: now)
        codex.codexMetadata?.turnID = "second"
        codex.updatedAt = now.addingTimeInterval(60)
        c.sessionsDidChange([codex], now: codex.updatedAt)
        codex.phase = .completed
        c.sessionsDidChange([codex], now: now.addingTimeInterval(75))
        #expect(c.lastTurnDuration(sessionID: codex.id) == 15)
    }
}
