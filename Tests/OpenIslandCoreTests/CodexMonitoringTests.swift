import Foundation
import Testing
@testable import OpenIslandCore

// Synthetic fixtures for the documented Codex command-hook contract. They are
// deliberately not represented as recordings from a trusted, live Codex client.
struct CodexMonitoringTests {
    func payload(_ event: String, at seconds: Double, id: String = "shared", turn: String? = "t1", call: String? = nil, tool: String = "shell", extra: [String: Any] = [:]) throws -> CodexHookPayload {
        var object: [String: Any] = ["session_id": id, "hook_event_name": event, "cwd": "/tmp/project", "tool_name": tool]
        object["turn_id"] = turn
        object["tool_use_id"] = call
        object.merge(extra) { _, new in new }
        var value = try JSONDecoder().decode(CodexHookPayload.self, from: JSONSerialization.data(withJSONObject: object))
        value.observedAt = Date(timeIntervalSince1970: seconds)
        return value
    }

    func apply(_ payload: CodexHookPayload, to state: inout SessionState) {
        for event in CodexHookAdapter.events(for: payload, existing: state.session(id: payload.internalSessionID)) { state.apply(event) }
    }

    @Test func lifecycleAndProviderIsolation() throws {
        var state = SessionState(sessions: [AgentSession(id: "shared", title: "Claude", tool: .claudeCode, phase: .running, summary: "Claude works", updatedAt: .now)])
        try apply(payload("SessionStart", at: 1), to: &state)
        #expect(state.session(id: "codex:shared")?.phase == .idle)
        try apply(payload("UserPromptSubmit", at: 2, extra: ["prompt": "Build feature"]), to: &state)
        #expect(state.runningCount == 2)
        try apply(payload("Stop", at: 3, extra: ["last_assistant_message": "Done"]), to: &state)
        #expect(state.session(id: "codex:shared")?.phase == .completed)
        #expect(state.session(id: "codex:shared")?.lastAssistantMessageText == "Done")
        #expect(state.session(id: "shared")?.summary == "Claude works")
        #expect(CodexHookAdapter.events(for: try payload("Stop", at: 4), existing: state.session(id: "codex:shared")).isEmpty)
        try apply(payload("PostToolUse", at: 5, call: "late"), to: &state)
        #expect(state.session(id: "codex:shared")?.phase == .completed)
        try apply(payload("PreToolUse", at: 5.5, call: "continuation"), to: &state)
        #expect(state.session(id: "codex:shared")?.phase == .running)
        try apply(payload("SessionEnd", at: 6), to: &state)
        #expect(state.session(id: "codex:shared")?.isSessionEnded == true)
        #expect(state.session(id: "codex:shared")?.phase == .idle)
    }

    @Test func permissionCorrelationAndNoInlineDecisions() throws {
        var state = SessionState()
        try apply(payload("UserPromptSubmit", at: 1), to: &state)
        try apply(payload("PreToolUse", at: 2, call: "a"), to: &state)
        try apply(payload("PermissionRequest", at: 3), to: &state)
        #expect(state.session(id: "codex:shared")?.permissionRequest?.toolUseID == "a")
        state.resolvePermission(sessionID: "codex:shared", resolution: .allowOnce())
        #expect(state.session(id: "codex:shared")?.phase == .waitingForApproval)
        try apply(payload("PreToolUse", at: 4, call: "b", tool: "read"), to: &state)
        try apply(payload("PostToolUse", at: 5, call: "b"), to: &state)
        #expect(state.session(id: "codex:shared")?.phase == .waitingForApproval)
        try apply(payload("PostToolUse", at: 6, call: "a"), to: &state)
        #expect(state.session(id: "codex:shared")?.phase == .running)
        #expect(state.session(id: "codex:shared")?.permissionRequest == nil)
    }

    @Test func ambiguousApprovalStaysPendingUntilLifecycleSignal() throws {
        var state = SessionState()
        try apply(payload("PreToolUse", at: 1, call: "a"), to: &state)
        try apply(payload("PreToolUse", at: 2, call: "b"), to: &state)
        try apply(payload("PermissionRequest", at: 3), to: &state)
        try apply(payload("PostToolUse", at: 4, call: "a"), to: &state)
        try apply(payload("PostToolUse", at: 5, call: "b"), to: &state)
        #expect(state.session(id: "codex:shared")?.phase == .waitingForApproval)
        try apply(payload("Interrupt", at: 6), to: &state)
        #expect(state.completedCount == 0)
        #expect(state.session(id: "codex:shared")?.phase == .idle)
        #expect(state.session(id: "codex:shared")?.codexMetadata?.interrupted == true)
    }

    @Test func compactResumeOrderingAndStaleness() throws {
        var state = SessionState()
        try apply(payload("UserPromptSubmit", at: 1, extra: ["prompt": "first"]), to: &state)
        try apply(payload("SessionStart", at: 2, extra: ["source": "compact"]), to: &state)
        #expect(state.session(id: "codex:shared")?.phase == .running)
        try apply(payload("UserPromptSubmit", at: 3, turn: "t2", extra: ["prompt": "second"]), to: &state)
        try apply(payload("Stop", at: 4, turn: "t1"), to: &state)
        try apply(payload("Stop", at: 2, turn: "t2"), to: &state)
        #expect(state.session(id: "codex:shared")?.phase == .running)
        let session = try #require(state.session(id: "codex:shared"))
        for event in CodexHookAdapter.staleEvents(for: session, now: Date(timeIntervalSince1970: 1_000)) { state.apply(event) }
        #expect(state.session(id: session.id)?.phase == .idle)
        #expect(state.completedCount == 0)
        try apply(payload("PreToolUse", at: 1_001, turn: "t2", call: "new"), to: &state)
        #expect(state.session(id: session.id)?.phase == .running)
        #expect(state.session(id: session.id)?.codexMetadata?.isStale == false)
        _ = state.markProcessLiveness(aliveSessionIDs: [])
        _ = state.markProcessLiveness(aliveSessionIDs: [])
        #expect(state.session(id: session.id)?.isSessionEnded == false)
    }

    @Test func ignoresUnknownSubagentAndInvalidIdentityAndDropsToolResults() throws {
        #expect(CodexHookAdapter.events(for: try payload("Unknown", at: 1), existing: nil).isEmpty)
        #expect(CodexHookAdapter.events(for: try payload("Stop", at: 1, extra: ["agent_id": "child"]), existing: nil).isEmpty)
        #expect(CodexHookAdapter.events(for: try payload("Stop", at: 1, id: ""), existing: nil).isEmpty)
        let p = try payload("PreToolUse", at: 1, extra: ["tool_response": "secret-response", "tool_input": ["command": String(repeating: "a", count: 1_000), "secret": "secret-input"]])
        let wire = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(!wire.contains("secret"))
        #expect(p.toolInput?.command?.count == 500)
    }

    @Test func registryRestoresUnconfirmedAndDoesNotResurrectDismissed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = CodexSessionRegistry(fileURL: folder.appendingPathComponent("registry.json"))
        var state = SessionState()
        try apply(payload("UserPromptSubmit", at: 1), to: &state)
        try registry.save(state.sessions)
        let restored = try #require(try registry.load().first)
        #expect(restored.phase == .idle && restored.codexMetadata?.isStale == true)
        #expect(restored.nativeSessionID == "shared")
        state.dismissSession(id: restored.id)
        #expect(state.completedCount == 0)
        try registry.save(state.sessions)
        #expect(try registry.load().isEmpty)
    }

    @Test func bridgeAcknowledgesApprovalWithoutWaitingForUser() throws {
        let socket = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socket)
        try server.start()
        defer { server.stop() }
        let client = BridgeCommandClient(socketURL: socket)
        let start = Date()
        _ = try client.send(.processCodexHook(payload("PermissionRequest", at: 1, call: "a")), timeout: 0.5)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(server.sessionStateSnapshotForTests().session(id: "codex:shared")?.phase == .waitingForApproval)
    }
}
