import Foundation

public struct CodexSessionMetadata: Equatable, Codable, Sendable {
    public var sessionID: String
    public var source: String?
    public var transcriptPath: String?
    public var initialUserPrompt: String?
    public var lastUserPrompt: String?
    public var lastAssistantMessage: String?
    public var currentTool: String?
    public var currentToolInputPreview: String?
    public var turnID: String?
    public var retiredTurnIDs: [String] = []
    public var activeTools: [String: String] = [:]
    public var seenToolIDs: Set<String> = []
    public var pendingApprovalIDs: Set<String> = []
    public var uncorrelatedApproval = false
    public var lastEventAt: Date
    public var ended = false
    public var isStale = false
    public var interrupted = false
    public var turnFinished = false

    public init(sessionID: String, lastEventAt: Date = .now) {
        self.sessionID = sessionID
        self.lastEventAt = lastEventAt
    }
}

/// Only display fields are decoded; tool results and arbitrary tool arguments never enter the bridge.
public struct CodexToolInput: Equatable, Codable, Sendable {
    public var command: String?
    public var description: String?
}

public struct CodexHookPayload: Equatable, Codable, Sendable {
    public var sessionID: String
    public var hookEventName: String
    public var cwd: String?
    public var transcriptPath: String?
    public var source: String?
    public var turnID: String?
    public var toolName: String?
    public var toolUseID: String?
    public var toolInput: CodexToolInput?
    public var prompt: String?
    public var lastAssistantMessage: String?
    public var agentID: String?
    public var observedAt: Date
    public var terminalApp: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case hookEventName = "hook_event_name"
        case transcriptPath = "transcript_path"
        case turnID = "turn_id"
        case toolName = "tool_name"
        case toolUseID = "tool_use_id"
        case toolInput = "tool_input"
        case lastAssistantMessage = "last_assistant_message"
        case agentID = "agent_id"
        case cwd, source, prompt, observedAt, terminalApp
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        hookEventName = try c.decode(String.self, forKey: .hookEventName)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        turnID = try c.decodeIfPresent(String.self, forKey: .turnID)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID)
        toolInput = try? c.decodeIfPresent(CodexToolInput.self, forKey: .toolInput)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt).map { String($0.prefix(4_000)) }
        lastAssistantMessage = try c.decodeIfPresent(String.self, forKey: .lastAssistantMessage).map { String($0.prefix(16_000)) }
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
        observedAt = try c.decodeIfPresent(Date.self, forKey: .observedAt) ?? .now
        terminalApp = try c.decodeIfPresent(String.self, forKey: .terminalApp)
        if var input = toolInput {
            input.command = input.command.map { String($0.prefix(500)) }
            input.description = input.description.map { String($0.prefix(500)) }
            toolInput = input
        }
    }

    public var internalSessionID: String { "codex:\(sessionID)" }

    public var isValid: Bool {
        !sessionID.isEmpty && sessionID.utf8.count <= 256
            && !sessionID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && (turnID?.utf8.count ?? 0) <= 256
            && (toolUseID?.utf8.count ?? 0) <= 256
    }
}

public enum CodexHookAdapter {
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "Stop", "Interrupt", "SessionEnd",
    ]
    // shortcut: hooks have no heartbeat; after 15 minutes show unconfirmed status until the next event.
    public static let staleInterval: TimeInterval = 15 * 60

    public static func events(for payload: CodexHookPayload, existing: AgentSession?) -> [AgentEvent] {
        guard payload.isValid, payload.agentID == nil, events.contains(payload.hookEventName),
              existing.map({ $0.tool == .codex }) ?? true else { return [] }
        let id = payload.internalSessionID
        let at = payload.observedAt
        var metadata = existing?.codexMetadata ?? CodexSessionMetadata(sessionID: payload.sessionID, lastEventAt: .distantPast)
        guard at > metadata.lastEventAt else { return [] }
        let name = payload.hookEventName
        if metadata.turnFinished {
            if name == "PreToolUse" {
                // A new call proves continuation after a Stop hook; a delayed result does not.
                guard let call = payload.toolUseID, !metadata.seenToolIDs.contains(call) else { return [] }
            } else if ["PermissionRequest", "PostToolUse", "Stop", "Interrupt"].contains(name) { return [] }
        }
        if let turn = payload.turnID {
            guard !metadata.retiredTurnIDs.contains(turn) else { return [] }
            if let current = metadata.turnID, current != turn {
                guard name == "UserPromptSubmit" || name == "SessionStart" else { return [] }
                metadata.retiredTurnIDs = Array((metadata.retiredTurnIDs + [current]).suffix(32))
                metadata.activeTools = [:]
                metadata.pendingApprovalIDs = []
                metadata.uncorrelatedApproval = false
            }
            metadata.turnID = turn
        }
        if metadata.ended && name != "SessionStart" && name != "UserPromptSubmit" { return [] }
        metadata.lastEventAt = at
        metadata.isStale = false
        metadata.transcriptPath = payload.transcriptPath ?? metadata.transcriptPath
        if let source = payload.source { metadata.source = source }
        var result: [AgentEvent] = []
        if existing == nil || metadata.ended {
            metadata.ended = false
            result.append(.sessionStarted(SessionStarted(
                sessionID: id,
                title: payload.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
                tool: .codex, origin: .live, initialPhase: .idle, summary: "Codex is ready.",
                timestamp: at, codexMetadata: metadata
            )))
        }
        // Environment app hints are only used for app activation, never for sending or selecting a pane.
        if let cwd = payload.cwd {
            result.append(.jumpTargetUpdated(JumpTargetUpdated(
                sessionID: id,
                jumpTarget: JumpTarget(
                    terminalApp: payload.terminalApp ?? existing?.jumpTarget?.terminalApp ?? "",
                    workspaceName: URL(fileURLWithPath: cwd).lastPathComponent,
                    paneTitle: "Codex", workingDirectory: cwd
                ), timestamp: at
            )))
        }
        var phase = existing?.phase ?? .idle
        var summary = existing?.summary ?? "Codex is ready."
        var attention: AgentEvent?
        var completion = false
        var resolved = false
        switch name {
        case "SessionStart":
            if payload.source != "compact" && !(payload.source == "resume" && existing != nil && !metadata.ended) {
                phase = .idle
                summary = "Codex is ready."
                metadata.interrupted = false
                metadata.turnFinished = false
                resolved = true
            }
        case "UserPromptSubmit":
            metadata.initialUserPrompt = metadata.initialUserPrompt ?? payload.prompt
            metadata.lastUserPrompt = payload.prompt
            metadata.lastAssistantMessage = nil
            metadata.interrupted = false
            metadata.turnFinished = false
            metadata.activeTools = [:]
            metadata.seenToolIDs = []
            metadata.pendingApprovalIDs = []
            metadata.uncorrelatedApproval = false
            phase = .running
            summary = "Codex is working."
            resolved = true
        case "PreToolUse":
            metadata.turnFinished = false
            if let call = payload.toolUseID, metadata.seenToolIDs.count < 256 { metadata.seenToolIDs.insert(call) }
            if let call = payload.toolUseID, let tool = payload.toolName, metadata.activeTools.count < 128 {
                metadata.activeTools[call] = tool
            }
            metadata.currentTool = payload.toolName
            metadata.currentToolInputPreview = payload.toolInput?.command
            phase = .running
            summary = payload.toolName.map { "Codex is running \($0)." } ?? "Codex is working."
        case "PermissionRequest":
            metadata.currentTool = payload.toolName ?? metadata.currentTool
            metadata.currentToolInputPreview = payload.toolInput?.command ?? metadata.currentToolInputPreview
            let candidates = metadata.activeTools.filter { $0.value == payload.toolName }.map(\.key)
            let correlation = payload.toolUseID ?? (candidates.count == 1 ? candidates.first : nil)
            if let correlation { metadata.pendingApprovalIDs.insert(correlation) }
            else { metadata.uncorrelatedApproval = true }
            phase = .waitingForApproval
            summary = payload.toolInput?.description ?? "Review the request in Codex."
            attention = .permissionRequested(PermissionRequested(
                sessionID: id,
                request: PermissionRequest(title: "Codex needs approval", summary: summary,
                    affectedPath: payload.cwd ?? "", primaryActionTitle: "Open Codex",
                    toolName: payload.toolName, toolUseID: correlation, requiresTerminalApproval: true),
                timestamp: at
            ))
        case "PostToolUse":
            if let call = payload.toolUseID {
                metadata.activeTools.removeValue(forKey: call)
                let removed = metadata.pendingApprovalIDs.remove(call) != nil
                resolved = removed && metadata.pendingApprovalIDs.isEmpty && !metadata.uncorrelatedApproval
            }
            metadata.currentTool = nil
            metadata.currentToolInputPreview = nil
            phase = .running
            summary = "Codex is working."
        case "Stop":
            guard existing?.phase != .completed || existing?.codexMetadata?.isStale == true else { return result }
            metadata.lastAssistantMessage = payload.lastAssistantMessage ?? metadata.lastAssistantMessage
            summary = payload.lastAssistantMessage.map { String($0.prefix(500)) } ?? "Codex finished the turn."
            phase = .completed
            completion = true
            metadata.turnFinished = true
            resolved = true
        case "Interrupt":
            metadata.interrupted = true
            metadata.turnFinished = true
            phase = .idle
            summary = "Codex was interrupted."
            resolved = true
        case "SessionEnd":
            metadata.ended = true
            phase = .idle
            summary = "Codex session ended."
            resolved = true
        default: break
        }
        if resolved {
            metadata.pendingApprovalIDs = []
            metadata.uncorrelatedApproval = false
            if name != "PostToolUse" { metadata.activeTools = [:] }
            metadata.currentTool = nil
            metadata.currentToolInputPreview = nil
        }
        result.append(.codexSessionMetadataUpdated(.init(sessionID: id, metadata: metadata, timestamp: at)))
        if resolved {
            result.append(.actionableStateResolved(.init(sessionID: id, summary: summary, timestamp: at)))
        }
        if attention == nil && phase == .running && (!metadata.pendingApprovalIDs.isEmpty || metadata.uncorrelatedApproval) {
            attention = .permissionRequested(PermissionRequested(sessionID: id,
                request: existing?.permissionRequest ?? PermissionRequest(title: "Codex approval status unconfirmed", summary: "Review the request in Codex.", affectedPath: payload.cwd ?? "", primaryActionTitle: "Open Codex", requiresTerminalApproval: true), timestamp: at))
        }
        if let attention { result.append(attention) }
        else if completion {
            result.append(.sessionCompleted(.init(sessionID: id, summary: summary, timestamp: at)))
        } else {
            result.append(.activityUpdated(.init(sessionID: id, summary: summary, phase: phase, timestamp: at)))
        }
        return result
    }

    public static func staleEvents(for session: AgentSession, now: Date) -> [AgentEvent] {
        guard session.tool == .codex, var metadata = session.codexMetadata,
              !metadata.ended, !metadata.isStale,
              now.timeIntervalSince(metadata.lastEventAt) >= staleInterval else { return [] }
        metadata.isStale = true
        return [
            .codexSessionMetadataUpdated(.init(sessionID: session.id, metadata: metadata, timestamp: session.updatedAt)),
            .activityUpdated(.init(sessionID: session.id, summary: "Codex status unconfirmed — waiting for a new event.", phase: .idle, timestamp: session.updatedAt)),
        ]
    }
}
