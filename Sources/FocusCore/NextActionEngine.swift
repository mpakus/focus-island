import Foundation
import OpenIslandCore

public enum AttentionReason: String, Equatable, Sendable {
    case approval
    case question
    case unseenCompletion
}

public enum NextAlternative: Equatable, Sendable {
    case attend(sessionID: String, reason: AttentionReason, since: Date)
    case review(sessionID: String)
    case startTask(taskID: String, sameProject: Bool)
}

public struct NextActionInput: Sendable {
    public var triggeringSessionID: String
    public var sessions: [AgentSession]
    public var unseenCompletedSessionIDs: Set<String>
    public var board: BoardSnapshot
    public var sessionTaskBindings: [String: String]
    public var skippedTaskIDs: Set<String>
    public var currentTaskID: String?
    public var waitingSince: [String: Date]

    public init(triggeringSessionID: String, sessions: [AgentSession], unseenCompletedSessionIDs: Set<String>, board: BoardSnapshot, sessionTaskBindings: [String: String], skippedTaskIDs: Set<String>, currentTaskID: String? = nil, waitingSince: [String: Date] = [:]) {
        self.triggeringSessionID = triggeringSessionID
        self.sessions = sessions
        self.unseenCompletedSessionIDs = unseenCompletedSessionIDs
        self.board = board
        self.sessionTaskBindings = sessionTaskBindings
        self.skippedTaskIDs = skippedTaskIDs
        self.currentTaskID = currentTaskID
        self.waitingSince = waitingSince
    }
}

public enum NextActionEngine {
    public static func alternatives(_ input: NextActionInput, triggerCWD: String?, parked: Set<String>, limit: Int = 2, now: Date = .now, longWait: TimeInterval = 900) -> [NextAlternative] {
        guard limit > 0 else { return [] }
        func since(_ session: AgentSession) -> Date { input.waitingSince[session.id] ?? session.updatedAt }
        func focused(_ session: AgentSession) -> Bool {
            input.currentTaskID != nil && input.sessionTaskBindings[session.id] == input.currentTaskID
        }
        let others = input.sessions
            .filter { $0.id != input.triggeringSessionID && !parked.contains($0.id) && $0.isVisibleInIsland && !$0.isSessionEnded && !$0.isDemoSession && !$0.isSyntheticProcessSession }
            .sorted {
                let leftOverdue = now.timeIntervalSince(since($0)) >= longWait
                let rightOverdue = now.timeIntervalSince(since($1)) >= longWait
                if leftOverdue != rightOverdue { return leftOverdue }
                if !leftOverdue, focused($0) != focused($1) { return focused($0) }
                if since($0) != since($1) { return since($0) < since($1) }
                return $0.id < $1.id
            }

        var result: [NextAlternative] = []
        for session in others where session.phase == .waitingForApproval || session.phase == .waitingForAnswer {
            result.append(.attend(sessionID: session.id, reason: session.phase == .waitingForApproval ? .approval : .question, since: since(session)))
        }
        for session in others where session.phase == .completed && input.unseenCompletedSessionIDs.contains(session.id) {
            result.append(.review(sessionID: session.id))
        }

        if result.count < limit {
            let todos = input.board.tasks(in: .todo).filter { !input.skippedTaskIDs.contains($0.id) }
            let tagged = todos.map { ($0, isSameProject($0.projectPath, triggerCWD)) }
            for (task, same) in tagged where same {
                result.append(.startTask(taskID: task.id, sameProject: true))
            }
            for (task, same) in tagged where !same {
                result.append(.startTask(taskID: task.id, sameProject: false))
            }
        }
        return Array(result.prefix(limit))
    }

    private static func isSameProject(_ projectPath: String?, _ cwd: String?) -> Bool {
        guard let projectPath, !projectPath.isEmpty, let cwd, !cwd.isEmpty else { return false }
        let project = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        return cwd == project || cwd.hasPrefix(project + "/")
    }
}
