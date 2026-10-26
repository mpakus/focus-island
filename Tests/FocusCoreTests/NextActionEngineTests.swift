import Foundation
import Testing
import OpenIslandCore
@testable import FocusCore

struct NextActionAlternativesTests {
    let t0 = Date(timeIntervalSince1970: 40_000)

    func session(_ id: String, _ phase: SessionPhase, updatedAt offset: TimeInterval = 0) -> AgentSession {
        var session = AgentSession(id: id, title: id, tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: t0.addingTimeInterval(offset))
        session.isHookManaged = true
        return session
    }

    func task(_ id: String, _ position: Double, path: String? = nil, column: BoardColumn = .todo) -> FocusTask {
        FocusTask(id: id, title: id, details: nil, boardColumn: column, position: position, projectPath: path, note: nil, createdAt: t0, updatedAt: t0, doneAt: nil)
    }

    func input(sessions: [AgentSession], tasks: [FocusTask] = [], unseen: Set<String> = [], skipped: Set<String> = []) -> NextActionInput {
        NextActionInput(triggeringSessionID: "me", sessions: sessions, unseenCompletedSessionIDs: unseen, board: BoardSnapshot(tasks: tasks), sessionTaskBindings: [:], skippedTaskIDs: skipped)
    }

    @Test
    func ordersAttendThenReviewThenTasks() {
        let sessions = [session("me", .running), session("c", .completed), session("q", .waitingForAnswer, updatedAt: 5), session("a", .waitingForApproval, updatedAt: 9)]
        let all = NextActionEngine.alternatives(input(sessions: sessions, tasks: [task("t1", 1)], unseen: ["c"]), triggerCWD: nil, parked: [], limit: 10)
        #expect(all == [
            .attend(sessionID: "q", reason: .question, since: t0.addingTimeInterval(5)),
            .attend(sessionID: "a", reason: .approval, since: t0.addingTimeInterval(9)),
            .review(sessionID: "c"),
            .startTask(taskID: "t1", sameProject: false),
        ])
    }

    @Test
    func defaultLimitIsTwo() {
        let sessions = [session("me", .running), session("a", .waitingForApproval), session("q", .waitingForAnswer), session("c", .completed)]
        #expect(NextActionEngine.alternatives(input(sessions: sessions, unseen: ["c"]), triggerCWD: nil, parked: []).count == 2)
    }

    @Test
    func excludesTriggerAndParked() {
        let sessions = [session("me", .waitingForApproval), session("a", .waitingForApproval), session("b", .waitingForApproval, updatedAt: 3)]
        let result = NextActionEngine.alternatives(input(sessions: sessions), triggerCWD: nil, parked: ["a"])
        #expect(result == [.attend(sessionID: "b", reason: .approval, since: t0.addingTimeInterval(3))])
    }

    @Test
    func seenCompletionIsNotAReview() {
        let sessions = [session("me", .running), session("c", .completed)]
        #expect(NextActionEngine.alternatives(input(sessions: sessions), triggerCWD: nil, parked: []).isEmpty)
    }

    @Test
    func sameProjectTasksComeFirstAndSkippedAreDropped() {
        let tasks = [
            task("other", 1, path: "/work/other"),
            task("same", 2, path: "/work/focus"),
            task("parent", 3, path: "/work"),
            task("skipped", 4, path: "/work/focus"),
            task("inprog", 5, path: "/work/focus", column: .inProgress),
        ]
        let result = NextActionEngine.alternatives(input(sessions: [session("me", .running)], tasks: tasks, skipped: ["skipped"]), triggerCWD: "/work/focus/Sources", parked: [], limit: 10)
        #expect(result == [
            .startTask(taskID: "same", sameProject: true),
            .startTask(taskID: "parent", sameProject: true),
            .startTask(taskID: "other", sameProject: false),
        ])
    }

    @Test
    func prefixSiblingIsNotSameProject() {
        let result = NextActionEngine.alternatives(input(sessions: [session("me", .running)], tasks: [task("t", 1, path: "/work/foc")]), triggerCWD: "/work/focus", parked: [])
        #expect(result == [.startTask(taskID: "t", sameProject: false)])
    }

    @Test
    func attendFillsLimitBeforeTasks() {
        let sessions = [session("me", .running), session("a", .waitingForApproval)]
        let result = NextActionEngine.alternatives(input(sessions: sessions, tasks: [task("t1", 1)]), triggerCWD: nil, parked: [], limit: 2)
        #expect(result.count == 2)
        #expect(result.last == .startTask(taskID: "t1", sameProject: false))
    }

    @Test func prefersCurrentTaskUntilAnotherWaitIsOverdue() {
        var input = input(sessions: [session("outside", .waitingForAnswer), session("inside", .waitingForApproval, updatedAt: 100)])
        input.currentTaskID = "focused"
        input.sessionTaskBindings = ["inside": "focused"]
        let fresh = NextActionEngine.alternatives(input, triggerCWD: nil, parked: [], now: t0.addingTimeInterval(120), longWait: 300)
        #expect(fresh.first == .attend(sessionID: "inside", reason: .approval, since: t0.addingTimeInterval(100)))
        let overdue = NextActionEngine.alternatives(input, triggerCWD: nil, parked: [], now: t0.addingTimeInterval(310), longWait: 300)
        #expect(overdue.first == .attend(sessionID: "outside", reason: .question, since: t0))
    }

    @Test func ongoingUpdatesDoNotResetRecordedWaitAndTiesAreStable() {
        var input = input(sessions: [session("z", .waitingForApproval, updatedAt: 400), session("a", .waitingForAnswer, updatedAt: 20)])
        input.waitingSince = ["z": t0]
        let result = NextActionEngine.alternatives(input, triggerCWD: nil, parked: [], now: t0.addingTimeInterval(500))
        #expect(result.first == .attend(sessionID: "z", reason: .approval, since: t0))
        input.waitingSince["a"] = t0
        #expect(NextActionEngine.alternatives(input, triggerCWD: nil, parked: [], now: t0).first == .attend(sessionID: "a", reason: .question, since: t0))
    }
}
