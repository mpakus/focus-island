import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

struct FocusViewLogicTests {
    @Test
    func stayInTaskHeaderWithPlanAndEstimate() {
        let progress = PlanProgress(completed: 2, total: 7, currentTitle: "обновляет хендлеры")
        #expect(StayInTaskCard.header(progress: progress, remaining: 240, elapsed: 100) == "Step 3 of 7: обновляет хендлеры · about 4 min left in the plan")
    }

    @Test
    func stayInTaskHeaderWithoutEstimateOrTitle() {
        let progress = PlanProgress(completed: 0, total: 3, currentTitle: nil)
        #expect(StayInTaskCard.header(progress: progress, remaining: nil, elapsed: 30) == "Step 1 of 3")
    }

    @Test
    func stayInTaskHeaderClampsStepAndRoundsEstimateUp() {
        let progress = PlanProgress(completed: 3, total: 3, currentTitle: "финал")
        #expect(StayInTaskCard.header(progress: progress, remaining: 20, elapsed: nil) == "Step 3 of 3: финал · about 1 min left in the plan")
    }

    @Test
    func stayInTaskHeaderWithoutPlan() {
        #expect(StayInTaskCard.header(progress: nil, remaining: nil, elapsed: 400) == "Working · 6 min")
        #expect(StayInTaskCard.header(progress: nil, remaining: nil, elapsed: 10) == "Working · less than a minute")
        #expect(StayInTaskCard.header(progress: nil, remaining: nil, elapsed: nil) == "Working")
    }

    @Test
    func clockFormatsMinutesAndSeconds() {
        #expect(StayInTaskCard.clock(100) == "1:40")
        #expect(StayInTaskCard.clock(5) == "0:05")
        #expect(StayInTaskCard.clock(3725) == "62:05")
    }

    @Test
    func switchTitleUsesEstimate() {
        #expect(StayInTaskCard.switchTitle(remaining: 240) == "Or switch — 4 min is enough")
        #expect(StayInTaskCard.switchTitle(remaining: 10) == "Or switch — 1 min is enough")
        #expect(StayInTaskCard.switchTitle(remaining: nil) == "Or switch tasks")
    }

    @Test
    func changedFileURLJoinsPaths() {
        #expect(StayInTaskCard.fileURL(cwd: "/tmp/proj", path: "Sources/A.swift").path == "/tmp/proj/Sources/A.swift")
        #expect(StayInTaskCard.fileURL(cwd: "/tmp/proj/", path: "A.swift").path == "/tmp/proj/A.swift")
        #expect(StayInTaskCard.fileURL(cwd: "/tmp/proj", path: "/abs/B.swift").path == "/abs/B.swift")
    }

    @Test
    func nudgeTitleFormatsSeconds() {
        #expect(NudgeCard.title(target: "youtube.com", seconds: 25) == "The agent is working — you've been on youtube.com for 25 s")
        #expect(NudgeCard.title(target: "Telegram", seconds: 0) == "The agent is working — you've been in Telegram for 0 s")
        #expect(NudgeCard.title(target: "youtube.com", seconds: 125) == "The agent is working — you've been on youtube.com for 2 min 5 s")
        #expect(NudgeCard.title(target: "youtube.com", seconds: 120) == "The agent is working — you've been on youtube.com for 2 min")
        #expect(NudgeCard.title(target: nil, seconds: 30) == "The agent is working — you got distracted")
    }

    @Test
    func nudgeSubtitleJoinsAvailableParts() {
        #expect(NudgeCard.subtitle(project: "focus", task: "Рефакторинг auth", elapsed: 70) == "Session focus · «Рефакторинг auth» · 1:10")
        #expect(NudgeCard.subtitle(project: "focus", task: nil, elapsed: nil) == "Session focus")
        #expect(NudgeCard.subtitle(project: nil, task: nil, elapsed: nil) == "Session")
    }

    @Test
    func returnSubtitleCombinesStepsMinutesAndAwayProject() {
        let progress = PlanProgress(completed: 7, total: 7, currentTitle: nil)
        #expect(ReturnCard.subtitle(progress: progress, minutes: 6, awayProject: "billing") == "7 of 7 steps · 6 min · while you were in billing")
        #expect(ReturnCard.subtitle(progress: nil, minutes: 6, awayProject: nil) == "6 min")
        #expect(ReturnCard.subtitle(progress: progress, minutes: nil, awayProject: nil) == "7 of 7 steps")
        #expect(ReturnCard.subtitle(progress: nil, minutes: nil, awayProject: "billing") == "while you were in billing")
    }

    @Test
    func returnDoneStepsFallBackToTruncatedMessage() {
        let long = String(repeating: "я", count: 300)
        let message = ReturnCard.doneItems(completedTitles: [], lastMessage: long)
        #expect(message.count == 1)
        #expect(message[0].count == 240)
        #expect(ReturnCard.doneItems(completedTitles: ["a", "b", "c", "d", "e"], lastMessage: "x") == ["a", "b", "c", "d"])
        #expect(ReturnCard.doneItems(completedTitles: [], lastMessage: nil).isEmpty)
        #expect(ReturnCard.doneItems(completedTitles: [], lastMessage: "  \n ").isEmpty)
    }

    @Test
    func reEntryBreadcrumbDescribesFocusTask() {
        let progress = PlanProgress(completed: 3, total: 7, currentTitle: nil)
        #expect(ReEntryCard.breadcrumb(taskTitle: "Рефакторинг auth", progress: progress, hasQueuedPrompt: true, isRunning: true) == "Рефакторинг auth continues · step 4 of 7 · prompt queued · I'll notify you when it's done")
        #expect(ReEntryCard.breadcrumb(taskTitle: "Рефакторинг auth", progress: nil, hasQueuedPrompt: false, isRunning: true) == "Рефакторинг auth continues · I'll notify you when it's done")
        #expect(ReEntryCard.breadcrumb(taskTitle: "Рефакторинг auth", progress: progress, hasQueuedPrompt: true, isRunning: false) == nil)
        #expect(ReEntryCard.breadcrumb(taskTitle: nil, progress: progress, hasQueuedPrompt: true, isRunning: true) == nil)
    }

    @Test
    func reEntryAgoText() {
        #expect(ReEntryCard.agoText(minutes: 40) == "40 min ago")
        #expect(ReEntryCard.agoText(minutes: 60) == "1 h ago")
        #expect(ReEntryCard.agoText(minutes: 135) == "2 h 15 min ago")
        #expect(ReEntryCard.agoText(minutes: 0) == "just now")
    }

    @Test
    func truncationLimits() {
        #expect(FocusText.truncated("abc", limit: 5) == "abc")
        #expect(FocusText.truncated("abcdef", limit: 5) == "abcde")
        #expect(FocusText.truncated("  abc \n", limit: 5) == "abc")
        #expect(FocusText.cardMessageLimit == 240)
    }

    @Test
    func planBarFractionClamps() {
        #expect(PlanProgressBar.fraction(PlanProgress(completed: 3, total: 7, currentTitle: nil)) > 0.42)
        #expect(PlanProgressBar.fraction(PlanProgress(completed: 9, total: 7, currentTitle: nil)) == 1)
        #expect(PlanProgressBar.fraction(PlanProgress(completed: 0, total: 0, currentTitle: nil)) == 0)
    }

    @Test
    func alternativeCopy() {
        let since = Date(timeIntervalSince1970: 0)
        #expect(StayInTaskCard.reason(.attend(sessionID: "a", reason: .approval, since: since)) == "Permission · takes a minute")
        #expect(StayInTaskCard.reason(.attend(sessionID: "a", reason: .question, since: since)) == "Question · takes a minute")
        #expect(StayInTaskCard.reason(.startTask(taskID: "t", sameProject: true)) == "same project — easier to switch")
        #expect(StayInTaskCard.attendTitle(name: "billing", reason: .question) == "billing is waiting for an answer")
        #expect(StayInTaskCard.attendTitle(name: "billing", reason: .approval) == "billing is waiting for permission")
        #expect(StayInTaskCard.actionTitle(.startTask(taskID: "t", sameProject: false)) == "Start")
        #expect(StayInTaskCard.actionTitle(.review(sessionID: "a")) == "Open session")
    }

    @Test
    func reEntryOriginLine() {
        #expect(ReEntryCard.originLine(project: "billing", minutes: 40) == "billing · last seen 40 min ago")
        #expect(ReEntryCard.originLine(project: nil, minutes: 40) == "last seen 40 min ago")
        #expect(ReEntryCard.originLine(project: "billing", minutes: nil) == "billing")
    }

    @Test
    func syncedDraftFollowsQueueUnlessUserIsEditing() {
        let initial = StayInTaskCard.syncedDraft(current: "", lastSynced: nil, queued: "old")
        #expect(initial.draft == "old" && initial.lastSynced == "old")
        let unchanged = StayInTaskCard.syncedDraft(current: "typing", lastSynced: "old", queued: "old")
        #expect(unchanged.draft == "typing" && unchanged.lastSynced == "old")
        let followed = StayInTaskCard.syncedDraft(current: "old", lastSynced: "old", queued: "new")
        #expect(followed.draft == "new" && followed.lastSynced == "new")
        let midEdit = StayInTaskCard.syncedDraft(current: "mine", lastSynced: "old", queued: "new")
        #expect(midEdit.draft == "mine" && midEdit.lastSynced == "new")
        let cleared = StayInTaskCard.syncedDraft(current: "old", lastSynced: "old", queued: nil)
        #expect(cleared.draft == "" && cleared.lastSynced == nil)
        let emptyStaysEmpty = StayInTaskCard.syncedDraft(current: "", lastSynced: nil, queued: nil)
        #expect(emptyStaysEmpty.draft == "" && emptyStaysEmpty.lastSynced == nil)
    }

    @Test
    func stalledAgeLabelUsesMinutesThenHours() {
        #expect(WaitingOutsideSection.ageLabel(seconds: 25 * 60) == "25 min")
        #expect(WaitingOutsideSection.ageLabel(seconds: 59 * 60 + 59) == "59 min")
        #expect(WaitingOutsideSection.ageLabel(seconds: 3600) == "1 h")
        #expect(WaitingOutsideSection.ageLabel(seconds: 2 * 3600 + 1800) == "2 h")
        #expect(WaitingOutsideSection.ageLabel(seconds: -5) == "0 min")
    }

    @Test
    func dayStartPrimaryTitleUsesFirstSelected() {
        #expect(DayStartCard.primaryTitle(selectedTitles: ["Рефакторинг auth", "Webhook"]) == "Start with “Рефакторинг auth”")
        #expect(DayStartCard.primaryTitle(selectedTitles: []) == "Start the day")
    }

    @Test
    func dayStartSelectionCapsAtThree() {
        #expect(DayStartCard.toggled(["a", "b"], id: "c") == ["a", "b", "c"])
        #expect(DayStartCard.toggled(["a", "b", "c"], id: "d") == ["a", "b", "c"])
        #expect(DayStartCard.toggled(["a", "b", "c"], id: "b") == ["a", "c"])
    }

    @Test
    func dayStartDefaultSelectionTakesInProgressFirstThree() {
        func task(_ id: String, _ column: BoardColumn) -> FocusTask {
            FocusTask(id: id, title: id, details: nil, boardColumn: column, position: 0, projectPath: nil, note: nil, createdAt: .distantPast, updatedAt: .distantPast, doneAt: nil)
        }
        let tasks = [task("a", .inProgress), task("b", .inProgress), task("c", .inProgress), task("d", .inProgress), task("e", .todo)]
        #expect(DayStartCard.defaultSelection(tasks: tasks) == ["a", "b", "c"])
        #expect(DayStartCard.defaultSelection(tasks: [task("e", .todo)]) == [])
    }

    @Test
    func dayStartYesterdayRowsKeepOpenGroupsBeforeToday() {
        let startOfToday = Date(timeIntervalSince1970: 100_000)
        func row(_ id: String, _ group: HubGroup) -> HubRow {
            HubRow(id: id, group: group, taskID: nil, title: id, projectName: nil, detail: "", since: .distantPast, progress: nil)
        }
        let rows = [row("w", .waiting), row("r", .review), row("run", .running), row("p", .parked), row("fresh", .idle), row("u", .unbound)]
        let activity: [String: Date] = [
            "w": startOfToday.addingTimeInterval(-3600),
            "r": startOfToday.addingTimeInterval(-7200),
            "run": startOfToday.addingTimeInterval(-3600),
            "p": startOfToday.addingTimeInterval(-86_400),
            "fresh": startOfToday.addingTimeInterval(60),
            "u": startOfToday.addingTimeInterval(-3600)
        ]
        let result = DayStartCard.yesterdayRows(rows: rows, startOfToday: startOfToday) { activity[$0] }
        #expect(result.map(\.id) == ["w", "r", "p"])
    }

    @Test
    func dayStartYesterdayDetail() {
        #expect(DayStartCard.yesterdayButtonTitle(group: .waiting) == "Resume")
        #expect(DayStartCard.yesterdayButtonTitle(group: .review) == "Review")
        #expect(DayStartCard.yesterdayButtonTitle(group: .parked) == "Restore")
        #expect(DayStartCard.yesterdayButtonTitle(group: .idle) == "Resume")
    }

    @Test
    func bindingGroupsPutProjectTasksFirst() {
        func task(_ id: String, _ path: String?) -> FocusTask {
            FocusTask(id: id, title: id, details: nil, boardColumn: .todo, position: 0, projectPath: path, note: nil, createdAt: .distantPast, updatedAt: .distantPast, doneAt: nil)
        }
        let tasks = [task("a", "/p/focus"), task("b", "/p/other"), task("c", nil), task("d", "/p/focus/")]
        let groups = BindingCard.groups(tasks: tasks, cwd: "/p/focus/Sources")
        #expect(groups.thisProject.map(\.id) == ["a", "d"])
        #expect(groups.others.map(\.id) == ["b", "c"])
        let none = BindingCard.groups(tasks: tasks, cwd: nil)
        #expect(none.thisProject.isEmpty && none.others.count == 4)
    }

    @Test
    func overloadTitleAndChipText() {
        #expect(OverloadCard.title(liveCount: 4) == "Session 4 in this task")
        #expect(OverloadCard.subtitle(limit: 3) == "You usually manage 3 comfortably. More sessions can be hard to track — clear a slot first.")
        #expect(OverloadCard.stateText(.waiting) == "waiting")
        #expect(OverloadCard.stateText(.running) == "working")
        #expect(OverloadCard.stateText(.review) == "done")
        #expect(OverloadCard.stateText(.idle) == "your turn")
        #expect(OverloadCard.stateText(.unbound) == "no task")
    }

    @Test
    func onboardingCompletionAndInput() {
        #expect(OnboardingCard.canAddTask(text: "  ") == false)
        #expect(OnboardingCard.canAddTask(text: " Задача ") == true)
        #expect(OnboardingCard.stage(hooksInstalled: nil, taskAdded: false) == .connect)
        #expect(OnboardingCard.stage(hooksInstalled: false, taskAdded: false) == .connect)
        #expect(OnboardingCard.stage(hooksInstalled: true, taskAdded: false) == .firstTask)
        #expect(OnboardingCard.stage(hooksInstalled: true, taskAdded: true) == .started)
        #expect(OnboardingCard.startedToast(sessionCount: 2) == "Task in progress · 2 sessions included")
        #expect(OnboardingCard.candidateDetail(cwd: nil, appName: nil) == "agent session")
        #expect(OnboardingCard.candidateDetail(cwd: "/tmp/api", appName: "Ghostty") == "/tmp/api · Ghostty")
        #expect(OnboardingCard.shortPath(NSHomeDirectory() + "/work/api") == "~/work/api")
        #expect(OnboardingCard.launchCommand(projectPath: nil) == "claude")
        #expect(OnboardingCard.launchCommand(projectPath: NSHomeDirectory() + "/work/api") == "cd ~/work/api && claude")
        #expect(OnboardingCard.launchCommand(projectPath: "/tmp/my api") == "cd \"/tmp/my api\" && claude")
        #expect(OnboardingCard.launchCommand(projectPath: nil, agent: .codex) == "codex")
        #expect(OnboardingCard.launchCommand(projectPath: "/tmp/my api", agent: .codex) == "cd \"/tmp/my api\" && codex")
    }

    @Test
    func bindingShortPathReplacesHome() {
        let home = NSHomeDirectory()
        #expect(BindingCard.shortPath(home) == "~")
        #expect(BindingCard.shortPath(home + "/Projects/focus") == "~/Projects/focus")
        #expect(BindingCard.shortPath("/tmp/x") == "/tmp/x")
    }

    @Test
    func overloadWaitingDetailUsesNow() {
        let since = Date(timeIntervalSince1970: 1000)
        let row = HubRow(id: "a", group: .waiting, taskID: nil, title: "a", projectName: nil, detail: "", since: since, progress: nil)
        #expect(OverloadCard.waitingDetail(row: row, now: since.addingTimeInterval(190)) == "waiting 3 min")
    }

    @Test
    func bindingShownBelowNonModalCardsOnly() {
        #expect(FocusIslandSection.showsBinding(card: nil))
        #expect(FocusIslandSection.showsBinding(card: .dayStart))
        #expect(FocusIslandSection.showsBinding(card: .returned(sessionID: "a")))
        #expect(!FocusIslandSection.showsBinding(card: .onboarding))
        #expect(!FocusIslandSection.showsBinding(card: .nudge))
        #expect(!FocusIslandSection.showsBinding(card: .overload(newSessionID: "a")))
        #expect(!FocusIslandSection.showsBinding(card: .reEntry(sessionID: "a")))
    }

    private func hubRow(_ id: String, _ group: HubGroup) -> HubRow {
        HubRow(id: id, group: group, taskID: nil, title: id, projectName: nil, detail: "", since: .distantPast, progress: nil)
    }

    @Test
    func hubPrimaryRowIsFirstWaiting() {
        #expect(SessionHubView.primaryRowID(rows: [hubRow("r", .running), hubRow("w1", .waiting), hubRow("w2", .waiting)]) == "w1")
        #expect(SessionHubView.primaryRowID(rows: [hubRow("r", .running), hubRow("v", .review)]) == nil)
        #expect(SessionHubView.primaryRowID(rows: []) == nil)
    }

    @Test
    func hubHeaderCountPluralizesSessions() {
        #expect(SessionHubView.headerCount(live: 4, limit: 3) == "4 sessions · your limit 3")
        #expect(SessionHubView.headerCount(live: 1, limit: 3) == "1 session · your limit 3")
        #expect(SessionHubView.headerCount(live: 5, limit: 6) == "5 sessions · your limit 6")
        #expect(SessionHubView.headerCount(live: 11, limit: 3) == "11 sessions · your limit 3")
        #expect(SessionHubView.headerCount(live: 21, limit: 3) == "21 sessions · your limit 3")
        #expect(SessionHubView.headerCount(live: 0, limit: 3) == "0 sessions · your limit 3")
    }

    @Test
    func hubLiveCountSkipsParked() {
        #expect(SessionHubView.liveCount(rows: [hubRow("a", .running), hubRow("b", .parked), hubRow("c", .unbound)]) == 2)
    }

    @Test
    func hubGroupsKeepOrderAndSkipEmpty() {
        let rows = [hubRow("p", .parked), hubRow("r", .running), hubRow("w", .waiting), hubRow("r2", .running)]
        let groups = SessionHubView.groups(rows: rows)
        #expect(groups.map(\.group) == [.waiting, .running, .parked])
        #expect(groups[1].rows.map(\.id) == ["r", "r2"])
        #expect(SessionHubView.groupCaption(.running, count: 2) == "Working · 2")
    }

    @Test
    func hubRowActions() {
        #expect(SessionHubView.actionTitle(group: .waiting) == "Reply")
        #expect(SessionHubView.actionTitle(group: .review) == "Review")
        #expect(SessionHubView.actionTitle(group: .running) == "Open session")
        #expect(SessionHubView.actionTitle(group: .idle) == "Open session")
        #expect(SessionHubView.actionTitle(group: .unbound) == "Link")
        #expect(SessionHubView.actionTitle(group: .parked) == "Restore")
        #expect(SessionHubView.isPrimary(row: hubRow("w1", .waiting), primaryID: "w1"))
        #expect(!SessionHubView.isPrimary(row: hubRow("w2", .waiting), primaryID: "w1"))
        #expect(!SessionHubView.isPrimary(row: hubRow("r", .running), primaryID: nil))
    }

    @Test
    func hubDurationLabel() {
        #expect(SessionHubView.durationLabel(seconds: 7800) == "2h 10m")
        #expect(SessionHubView.durationLabel(seconds: 7200) == "2h")
        #expect(SessionHubView.durationLabel(seconds: 360) == "6 min")
        #expect(SessionHubView.durationLabel(seconds: 59) == "0 min")
        #expect(SessionHubView.durationLabel(seconds: -5) == "0 min")
    }

    @Test
    func hubFooterText() {
        #expect(SessionHubView.footerText(focusSeconds: 7800, distractionSeconds: 360) == "Today: focus 2h 10m · distractions 6 min")
        #expect(SessionHubView.footerText(focusSeconds: 0, distractionSeconds: 0) == "Today: focus 0 min · distractions 0 min")
    }

    @Test
    func hubFocusTitleFallsBack() {
        #expect(SessionHubView.focusTitle(nil) == "Not selected")
        #expect(SessionHubView.focusTitle("Рефакторинг auth") == "Рефакторинг auth")
    }

    @Test
    func hubDaySummaryNotificationTargetsToday() {
        #expect(SessionHubView.daySummaryUserInfo["tab"] as? String == "today")
    }

    @Test
    func panelActionableSessionsKeepOnlyApprovalAndQuestion() {
        func session(_ id: String, _ phase: SessionPhase) -> AgentSession {
            AgentSession(id: id, title: id, tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: .distantPast)
        }
        let sessions = [session("r", .running), session("a", .waitingForApproval), session("c", .completed), session("q", .waitingForAnswer)]
        #expect(IslandPanelView.actionableSessions(sessions).map(\.id) == ["a", "q"])
        #expect(IslandPanelView.actionableSessions([session("r", .running)]).isEmpty)
    }

    private func hubRow(_ id: String, _ group: HubGroup, taskID: String? = "t1") -> HubRow {
        HubRow(id: id, group: group, taskID: taskID, title: id, projectName: nil, detail: "", since: .distantPast, progress: nil)
    }

    private func record(_ id: String, start: TimeInterval, end: TimeInterval, message: String? = nil) -> SessionRecord {
        SessionRecord(id: id, cwd: nil, projectName: nil, title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: message, startedAt: Date(timeIntervalSince1970: start), lastActivityAt: Date(timeIntervalSince1970: end), endedAt: Date(timeIntervalSince1970: end), status: .ended, taskId: "t1", transcriptPath: nil)
    }

    @Test
    func boardTabParsesUserInfo() {
        #expect(BoardTab.from(userInfo: ["tab": "today"]) == .today)
        #expect(BoardTab.from(userInfo: ["tab": "week"]) == .week)
        #expect(BoardTab.from(userInfo: ["tab": "history"]) == .history)
        #expect(BoardTab.from(userInfo: ["tab": "board"]) == .board)
        #expect(BoardTab.from(userInfo: ["tab": "bogus"]) == .board)
        #expect(BoardTab.from(userInfo: ["tab": 3]) == .board)
        #expect(BoardTab.from(userInfo: nil) == .board)
        #expect(BoardTab.from(userInfo: SessionHubView.daySummaryUserInfo) == .today)
    }

    @Test
    func boardTabTitles() {
        #expect(BoardTab.allCases.map(\.title) == ["Board", "Today", "Week", "History"])
    }

    @Test
    func borderStylePrefersWaitingThenRunningThenReview() {
        #expect(TaskCardView.borderStyle(rows: [hubRow("a", .running), hubRow("b", .waiting), hubRow("c", .review)]) == .waiting)
        #expect(TaskCardView.borderStyle(rows: [hubRow("a", .review), hubRow("b", .running)]) == .running)
        #expect(TaskCardView.borderStyle(rows: [hubRow("a", .review)]) == .review)
        #expect(TaskCardView.borderStyle(rows: [hubRow("a", .idle), hubRow("b", .parked), hubRow("c", .unbound)]) == TaskCardBorder.none)
        #expect(TaskCardView.borderStyle(rows: []) == TaskCardBorder.none)
    }

    @Test
    func pastSummaryCountsOnlyNonLiveSessions() {
        let records = [record("a", start: 0, end: 1200), record("b", start: 2000, end: 2960), record("live", start: 4000, end: 9000)]
        #expect(TaskCardView.pastSummary(records: records, live: ["live"]) == "2 more sessions · 36 min")
        #expect(TaskCardView.pastSummary(records: [record("a", start: 0, end: 600)], live: []) == "1 more session · 10 min")
        #expect(TaskCardView.pastSummary(records: [record("live", start: 0, end: 600)], live: ["live"]) == nil)
        #expect(TaskCardView.pastSummary(records: [], live: []) == nil)
    }

    @Test
    func sessionsWordAgrees() {
        #expect(TaskCardView.pastSummary(records: (0..<5).map { record("s\($0)", start: 0, end: 60) }, live: []) == "5 more sessions · 5 min")
        #expect(TaskCardView.pastSummary(records: (0..<21).map { record("s\($0)", start: 0, end: 60) }, live: []) == "21 more sessions · 21 min")
    }

    @Test
    func boardDurationFormatting() {
        #expect(BoardView.duration(0) == "0 min")
        #expect(BoardView.duration(20) == "1 min")
        #expect(BoardView.duration(52 * 60) == "52 min")
        #expect(BoardView.duration(65 * 60) == "1 h 05 min")
        #expect(BoardView.duration(120 * 60) == "2 h")
    }

    @Test
    func toolbarCountsGroupRows() {
        let rows = [hubRow("a", .running), hubRow("b", .running), hubRow("c", .waiting), hubRow("d", .review), hubRow("e", .idle)]
        let counts = BoardView.toolbarCounts(rows: rows)
        #expect(counts == BoardToolbarCounts(working: 2, waiting: 1, review: 1))
        #expect(BoardView.workingLabel(2) == "2 working")
        #expect(BoardView.workingLabel(1) == "1 working")
        #expect(BoardView.waitingLabel(1) == "1 waiting for you")
        #expect(BoardView.waitingLabel(3) == "3 waiting for you")
        #expect(BoardView.reviewLabel(1) == "1 done")
    }

    @Test
    func doneCaptionShowsDaySessionsAndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_000_000)
        let yesterday = now.addingTimeInterval(-86_400)
        let records = [record("a", start: 0, end: 1800), record("b", start: 0, end: 1800), record("c", start: 0, end: 1800)]
        #expect(TaskCardView.doneCaption(doneAt: yesterday, records: records, now: now, calendar: calendar) == "yesterday · 3 sessions · 1 h 30 min")
        #expect(TaskCardView.doneCaption(doneAt: now, records: [], now: now, calendar: calendar) == "today")
        #expect(TaskCardView.doneCaption(doneAt: nil, records: records, now: now, calendar: calendar) == "3 sessions · 1 h 30 min")
        #expect(TaskCardView.doneCaption(doneAt: yesterday, records: [record("a", start: 0, end: 1080)], now: now, calendar: calendar) == "yesterday · 1 session · 18 min")
    }

    @Test
    func waitMinutesLabel() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(TaskCardView.waitLabel(since: now.addingTimeInterval(-180), now: now) == "3 min")
        #expect(TaskCardView.waitLabel(since: now.addingTimeInterval(-10), now: now) == "0 min")
    }

    @Test
    func taskTimeTotalsUnionSpans() {
        let t = Date(timeIntervalSince1970: 0)
        func span(_ kind: ActivityKind, _ start: TimeInterval, _ end: TimeInterval?) -> ActivitySpan {
            ActivitySpan(kind: kind, sessionId: nil, taskId: "t1", startedAt: t.addingTimeInterval(start), endedAt: end.map { t.addingTimeInterval($0) })
        }
        let spans = [span(.claude, 0, 600), span(.claude, 300, 900), span(.you, 800, 1200), span(.waiting, 1200, 2000), span(.distraction, 0, 5000), span(.claude, 3000, nil)]
        let totals = TaskDetailView.timeTotals(spans: spans, now: t.addingTimeInterval(3300))
        #expect(totals.claudeSeconds == 1200)
        #expect(totals.totalSeconds == 1500)
        #expect(TaskDetailView.timeSummary(totals) == "total 25 min · agents 20 min")
        #expect(TaskDetailView.timeSummary(TaskTimeTotals(totalSeconds: 0, claudeSeconds: 0)) == nil)
    }

    @Test
    func detailCaptions() {
        #expect(TaskDetailView.criteriaCaption(CriteriaProgress(done: 1, total: 2)) == "Completion criteria · 1 of 2")
        #expect(TaskDetailView.criteriaCaption(nil) == "Completion criteria")
        #expect(TaskDetailView.sessionsCaption(count: 3) == "Sessions · 3")
    }

    @Test
    func pastSessionSubtitleTrimsMessage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_000_000)
        let message = String(repeating: "я", count: 100)
        let rec = SessionRecord(id: "p", cwd: nil, projectName: nil, title: "p", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: message, startedAt: now.addingTimeInterval(-86_400 - 1440), lastActivityAt: now.addingTimeInterval(-86_400), endedAt: now.addingTimeInterval(-86_400), status: .ended, taskId: "t1", transcriptPath: nil)
        let subtitle = TaskDetailView.pastSubtitle(record: rec, now: now, calendar: calendar)
        #expect(subtitle.hasPrefix("yesterday, "))
        #expect(subtitle.contains(" · 24 min · "))
        #expect(subtitle.hasSuffix(String(repeating: "я", count: 60)))
        let bare = SessionRecord(id: "p", cwd: nil, projectName: nil, title: "p", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: now.addingTimeInterval(-600), lastActivityAt: now, endedAt: now, status: .ended, taskId: "t1", transcriptPath: nil)
        #expect(TaskDetailView.pastSubtitle(record: bare, now: now, calendar: calendar).hasSuffix(" · 10 min"))
    }

    @Test
    func liveSessionSubtitle() {
        let progress = PlanProgress(completed: 2, total: 7, currentTitle: nil)
        #expect(TaskDetailView.liveSubtitle(progress: progress, group: .running) == "now · step 3 of 7")
        #expect(TaskDetailView.liveSubtitle(progress: nil, group: .running) == "now")
        #expect(TaskDetailView.liveSubtitle(progress: nil, group: .waiting) == "waiting for an answer")
        #expect(TaskDetailView.liveSubtitle(progress: nil, group: .review) == "finished, not reviewed")
    }

    @Test
    func newSessionCwdFallsBackToHome() {
        #expect(TaskDetailView.newSessionCwd(projectPath: "/tmp/proj", home: "/Users/x") == "/tmp/proj")
        #expect(TaskDetailView.newSessionCwd(projectPath: nil, home: "/Users/x") == "/Users/x")
        #expect(TaskDetailView.newSessionCwd(projectPath: "", home: "/Users/x") == "/Users/x")
    }

    @Test
    func boardTabExplicitIsNilWithoutValidTab() {
        #expect(BoardTab.explicit(userInfo: ["tab": "week"]) == .week)
        #expect(BoardTab.explicit(userInfo: nil) == nil)
        #expect(BoardTab.explicit(userInfo: ["tab": "bogus"]) == nil)
        #expect(BoardTab.explicit(userInfo: SessionHubView.boardUserInfo) == .board)
    }

    @Test
    func liveRecordsWithoutRowStayVisible() {
        let a = record("a", start: 0, end: 60)
        let b = record("b", start: 0, end: 60)
        let c = record("c", start: 0, end: 60)
        let rows = [hubRow("a", .running)]
        #expect(TaskDetailView.unrowedLive(records: [a, b, c], rows: rows, live: ["a", "b"]).map(\.id) == ["b"])
    }

    private func daySummaryCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func summaryTask(_ id: String, _ title: String, column: BoardColumn, updatedAt: Date, doneAt: Date? = nil) -> FocusTask {
        FocusTask(id: id, title: title, details: nil, boardColumn: column, position: 1, projectPath: nil, note: nil, createdAt: Date(timeIntervalSince1970: 0), updatedAt: updatedAt, doneAt: doneAt)
    }

    private func summaryReport(lanes: [TaskLane] = [], first: Date? = nil, last: Date? = nil) -> DayReport {
        DayReport(youSeconds: 19_200, claudeSeconds: 13_500, waitingSeconds: 2_880, distractionSeconds: 660, distractionCount: 4, returnedCount: 3, maxParallel: 4, firstAt: first, lastAt: last, lanes: lanes, distractionLane: [])
    }

    @Test
    func daySummaryDurationFormatsHoursAndMinutes() {
        #expect(DaySummaryFormatter.duration(19_200) == "5 h 20 min")
        #expect(DaySummaryFormatter.duration(2_880) == "48 min")
        #expect(DaySummaryFormatter.duration(3_600) == "1 h")
        #expect(DaySummaryFormatter.duration(0) == "0 min")
        #expect(DaySummaryFormatter.duration(-5) == "0 min")
        #expect(DaySummaryFormatter.duration(29) == "0 min")
        #expect(DaySummaryFormatter.duration(31) == "1 min")
    }

    @Test
    func daySummaryTitleAndRange() {
        let calendar = daySummaryCalendar()
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        let title = DaySummaryFormatter.title(day, calendar: calendar)
        #expect(title == "Friday, October 9")
        let first = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9, minute: 14))!
        let last = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 18, minute: 40))!
        #expect(DaySummaryFormatter.range(first: first, last: last, calendar: calendar) == "09:14 – 18:40")
        #expect(DaySummaryFormatter.range(first: nil, last: nil, calendar: calendar) == nil)
    }

    @Test
    func daySummaryDistractionDetail() {
        #expect(DaySummaryFormatter.distractionDetail(count: 4, returned: 3) == "4 times, returned 3")
        #expect(DaySummaryFormatter.distractionDetail(count: 1, returned: 0) == "1 time, returned 0")
        #expect(DaySummaryFormatter.distractionDetail(count: 5, returned: 5) == "5 times, returned 5")
        #expect(DaySummaryFormatter.distractionDetail(count: 0, returned: 0) == nil)
    }

    @Test
    func daySummarySelectsDoneTasksOfTheDay() {
        let calendar = daySummaryCalendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9))!
        let end = start.addingTimeInterval(86_400)
        let tasks = [
            summaryTask("a", "Сегодня", column: .done, updatedAt: start, doneAt: start.addingTimeInterval(3_600)),
            summaryTask("b", "Вчера", column: .done, updatedAt: start, doneAt: start.addingTimeInterval(-60)),
            summaryTask("c", "Завтра", column: .done, updatedAt: start, doneAt: end),
            summaryTask("d", "Без даты", column: .done, updatedAt: start, doneAt: nil),
            summaryTask("e", "В работе", column: .inProgress, updatedAt: start, doneAt: nil)
        ]
        #expect(DaySummaryFormatter.done(tasks: tasks, dayStart: start, dayEnd: end).map(\.id) == ["a"])
    }

    @Test
    func daySummarySelectsOpenTasksWithActivity() {
        let calendar = daySummaryCalendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9))!
        let end = start.addingTimeInterval(86_400)
        let report = DayReport(youSeconds: 0, claudeSeconds: 0, waitingSeconds: 0, distractionSeconds: 0, distractionCount: 0, returnedCount: 0, maxParallel: 0, firstAt: nil, lastAt: nil, lanes: [], distractionLane: [], activeTaskIDs: ["a"])
        let tasks = [
            summaryTask("a", "По ленте", column: .inProgress, updatedAt: start.addingTimeInterval(-86_400)),
            summaryTask("b", "По обновлению", column: .inProgress, updatedAt: start.addingTimeInterval(60)),
            summaryTask("c", "Без активности", column: .inProgress, updatedAt: start.addingTimeInterval(-86_400)),
            summaryTask("d", "Не в работе", column: .todo, updatedAt: start.addingTimeInterval(60)),
            summaryTask("e", "Сделано", column: .done, updatedAt: start.addingTimeInterval(60), doneAt: start.addingTimeInterval(60))
        ]
        #expect(DaySummaryFormatter.open(tasks: tasks, report: report, dayStart: start, dayEnd: end).map(\.id) == ["a", "b"])
    }

    @Test
    func daySummaryOpenSubtitle() {
        #expect(DaySummaryFormatter.openSubtitle(progress: CriteriaProgress(done: 1, total: 2), hasQueuedPrompt: true) == "criteria 1 of 2 · prompt queued")
        #expect(DaySummaryFormatter.openSubtitle(progress: CriteriaProgress(done: 0, total: 3), hasQueuedPrompt: false) == "criteria 0 of 3")
        #expect(DaySummaryFormatter.openSubtitle(progress: nil, hasQueuedPrompt: true) == "prompt queued")
        #expect(DaySummaryFormatter.openSubtitle(progress: nil, hasQueuedPrompt: false) == nil)
    }

    @Test
    func daySummaryMarkdownIncludesAllSections() {
        let calendar = daySummaryCalendar()
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        let start = calendar.startOfDay(for: day)
        let done = [summaryTask("a", "Hero copy", column: .done, updatedAt: start, doneAt: start)]
        let open = [summaryTask("b", "Рефакторинг auth", column: .inProgress, updatedAt: start)]
        let text = DaySummaryFormatter.markdown(report: summaryReport(), done: done, open: open, tomorrow: "Проверить алерты", day: day, calendar: calendar)
        let expected = """
        # Friday, October 9

        - You working: 5 h 20 min
        - Agents working: 3 h 45 min
        - Claude working: 3 h 45 min
        - Codex working: 0 min
        - Sessions waiting for you: 48 min
        - Distractions: 11 min (4 times, returned 3)
        - Peak parallel sessions: 4

        ## Completed
        - Hero copy

        ## Still open
        - Рефакторинг auth

        ## Start tomorrow with
        Проверить алерты
        """
        #expect(text == expected)
    }

    @Test
    func daySummaryMarkdownSkipsEmptySections() {
        let calendar = daySummaryCalendar()
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        let text = DaySummaryFormatter.markdown(report: summaryReport(), done: [], open: [], tomorrow: "  ", day: day, calendar: calendar)
        #expect(!text.contains("## Completed"))
        #expect(!text.contains("## Still open"))
        #expect(!text.contains("## Start tomorrow with"))
        #expect(text.hasPrefix("# Friday, October 9"))
        let nilTomorrow = DaySummaryFormatter.markdown(report: summaryReport(), done: [], open: [], tomorrow: nil, day: day, calendar: calendar)
        #expect(nilTomorrow == text)
    }

    @Test
    func daySummaryMarkdownOmitsDistractionDetailWhenNone() {
        let calendar = daySummaryCalendar()
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        let quiet = DayReport(youSeconds: 60, claudeSeconds: 0, waitingSeconds: 0, distractionSeconds: 0, distractionCount: 0, returnedCount: 0, maxParallel: 0, firstAt: nil, lastAt: nil, lanes: [], distractionLane: [])
        let text = DaySummaryFormatter.markdown(report: quiet, done: [], open: [], tomorrow: nil, day: day, calendar: calendar)
        #expect(text.contains("- Distractions: 0 min\n"))
    }

    @Test
    func timelineAxisSpansWholeHours() throws {
        let calendar = daySummaryCalendar()
        let first = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9, minute: 14))!
        let last = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 18, minute: 40))!
        let axis = try #require(DayTimelineView.axis(first: first, last: last, calendar: calendar))
        #expect(axis.hours.count == 11)
        #expect(calendar.component(.hour, from: axis.start) == 9)
        #expect(calendar.component(.hour, from: axis.end) == 19)
        #expect(axis.fraction(axis.start) == 0)
        #expect(axis.fraction(axis.end) == 1)
        #expect(axis.fraction(axis.start.addingTimeInterval(-100)) == 0)
        #expect(axis.fraction(axis.end.addingTimeInterval(100)) == 1)
        #expect(abs(axis.fraction(axis.start.addingTimeInterval(5 * 3_600)) - 0.5) < 0.0001)
    }

    @Test
    func timelineAxisHasMinimumOneHourAndNilWithoutData() {
        let calendar = daySummaryCalendar()
        let exact = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9))!
        let axis = DayTimelineView.axis(first: exact, last: exact, calendar: calendar)
        #expect(axis?.hours.count == 2)
        #expect(DayTimelineView.axis(first: nil, last: nil, calendar: calendar) == nil)
    }

    @Test
    func timelineAccessibilitySummaryListsLanes() {
        let start = Date(timeIntervalSince1970: 0)
        let lane = TaskLane(id: "a", taskID: "a", title: "Рефакторинг auth", segments: [
            LaneSegment(kind: .claude, start: start, end: start.addingTimeInterval(3_600)),
            LaneSegment(kind: .you, start: start.addingTimeInterval(3_600), end: start.addingTimeInterval(5_400)),
            LaneSegment(kind: .waiting, start: start.addingTimeInterval(5_400), end: start.addingTimeInterval(6_000))
        ])
        let report = DayReport(youSeconds: 1_800, claudeSeconds: 3_600, waitingSeconds: 600, distractionSeconds: 300, distractionCount: 1, returnedCount: 1, maxParallel: 1, firstAt: start, lastAt: start, lanes: [lane], distractionLane: [])
        let text = DayTimelineView.accessibilitySummary(report)
        #expect(text.contains("Рефакторинг auth: Claude 1 h, you 30 min, waiting 10 min"))
        #expect(text.contains("Distractions: 5 min"))
        #expect(DayTimelineView.accessibilitySummary(summaryReport()) == "No data for this day")
    }

    @Test
    func daySummaryOpenIncludesTasksFoldedIntoOtherLane() {
        let calendar = daySummaryCalendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9))!
        let end = start.addingTimeInterval(86_400)
        let old = start.addingTimeInterval(-86_400)
        let spans = (1...7).map { index in
            ActivitySpan(kind: .claude, sessionId: "s\(index)", taskId: "t\(index)", startedAt: start.addingTimeInterval(Double(index) * 100), endedAt: start.addingTimeInterval(Double(index) * 100 + Double(100 - index)))
        }
        let tasks = (1...7).map { summaryTask("t\($0)", "Задача \($0)", column: .inProgress, updatedAt: old) }
        let report = ReportBuilder.day(spans: spans, episodes: [], tasks: tasks, dayStart: start, dayEnd: end)
        #expect(report.lanes.last?.id == "other")
        #expect(DaySummaryFormatter.open(tasks: tasks, report: report, dayStart: start, dayEnd: end).count == 7)
    }

    @Test
    func daySummaryRolloverDetectsNewCalendarDay() {
        let calendar = daySummaryCalendar()
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 23, minute: 59))!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 0, minute: 1))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 1))!
        #expect(DaySummaryFormatter.rolledOver(from: evening, to: morning, calendar: calendar))
        #expect(!DaySummaryFormatter.rolledOver(from: earlier, to: evening, calendar: calendar))
    }

    @Test
    func daySummaryListItemFlattensNewlinesAndEscapesHash() {
        #expect(DaySummaryFormatter.listItem("Первая\nвторая\r\n  третья") == "- Первая вторая третья")
        #expect(DaySummaryFormatter.listItem("# Заголовок") == "- \\# Заголовок")
        #expect(DaySummaryFormatter.listItem("Тег #1") == "- Тег #1")
    }

    @Test
    func timelineAccessibilitySkipsLanesWithoutDescribableSegments() {
        let start = Date(timeIntervalSince1970: 0)
        let empty = TaskLane(id: "e", taskID: "e", title: "Пустая", segments: [])
        let full = TaskLane(id: "f", taskID: "f", title: "Полная", segments: [LaneSegment(kind: .claude, start: start, end: start.addingTimeInterval(600))])
        let report = DayReport(youSeconds: 0, claudeSeconds: 600, waitingSeconds: 0, distractionSeconds: 0, distractionCount: 0, returnedCount: 0, maxParallel: 1, firstAt: start, lastAt: start, lanes: [empty, full], distractionLane: [])
        #expect(DayTimelineView.accessibilitySummary(report) == "Полная: Claude 10 min")
        let onlyEmpty = DayReport(youSeconds: 0, claudeSeconds: 0, waitingSeconds: 0, distractionSeconds: 0, distractionCount: 0, returnedCount: 0, maxParallel: 0, firstAt: start, lastAt: start, lanes: [empty], distractionLane: [])
        #expect(DayTimelineView.accessibilitySummary(onlyEmpty) == "No data for this day")
    }

    @Test
    func barHeightsScaleToTallestDay() {
        let day = Date(timeIntervalSince1970: 0)
        let days = [
            DayBar(day: day, youSeconds: 3600, waitingSeconds: 1800, distractionSeconds: 600),
            DayBar(day: day, youSeconds: 1800, waitingSeconds: 0, distractionSeconds: 0),
            DayBar(day: day, youSeconds: 0, waitingSeconds: 0, distractionSeconds: 0)
        ]
        let heights = WeekSummaryView.barHeights(days: days, maxHeight: 200)
        #expect(heights.count == 3)
        #expect(heights[0] == 200)
        #expect(abs(heights[1] - 200 * 1800 / 6000) < 0.001)
        #expect(heights[2] == 0)
    }

    @Test
    func barHeightsAreZeroWithoutData() {
        let day = Date(timeIntervalSince1970: 0)
        let days = [DayBar(day: day, youSeconds: 0, waitingSeconds: 0, distractionSeconds: 0)]
        #expect(WeekSummaryView.barHeights(days: days, maxHeight: 100) == [0])
        #expect(WeekSummaryView.barHeights(days: [], maxHeight: 100).isEmpty)
    }

    @Test
    func segmentHeightsSplitBarProportionally() {
        let day = Date(timeIntervalSince1970: 0)
        let bar = DayBar(day: day, youSeconds: 600, waitingSeconds: 300, distractionSeconds: 100)
        let parts = WeekSummaryView.segmentHeights(day: bar, barHeight: 100)
        #expect(abs(parts.you - 60) < 0.001)
        #expect(abs(parts.waiting - 30) < 0.001)
        #expect(abs(parts.distraction - 10) < 0.001)
        let empty = WeekSummaryView.segmentHeights(day: DayBar(day: day, youSeconds: 0, waitingSeconds: 0, distractionSeconds: 0), barHeight: 0)
        #expect(empty.you == 0 && empty.waiting == 0 && empty.distraction == 0)
    }

    @Test
    func previousWeekDetailsFormatDeltas() {
        #expect(WeekSummaryView.previousCount(6) == "last week 6")
        #expect(WeekSummaryView.previousCount(nil) == "last week —")
        #expect(WeekSummaryView.previousDuration(11_100) == "last week 3 h 5 min")
        #expect(WeekSummaryView.previousDuration(nil) == "last week —")
    }

    @Test
    func kpiDetailsHandleMissingData() {
        #expect(WeekSummaryView.boundShareDetail(0.87) == "with a task 87%")
        #expect(WeekSummaryView.boundShareDetail(nil) == "with a task —")
        #expect(WeekSummaryView.averageWaitDetail(360) == "average 6 min to reply")
        #expect(WeekSummaryView.averageWaitDetail(10) == "average 1 min to reply")
        #expect(WeekSummaryView.averageWaitDetail(nil) == "no data")
        #expect(WeekSummaryView.reactionValue(12.4) == "12 s")
        #expect(WeekSummaryView.reactionValue(nil) == "—")
    }

    @Test
    func hoursLabelUsesOneDecimal() {
        #expect(WeekSummaryView.hoursLabel(14_760) == "4.1")
        #expect(WeekSummaryView.hoursLabel(0) == "0")
    }

    @Test
    func tableRowsScaleSharesAndStatuses() {
        let rows = [
            TaskTimeRow(id: "a", taskID: "a", title: "A", projectName: "p", seconds: 4000, sessions: 3, isDone: false),
            TaskTimeRow(id: "b", taskID: "b", title: "B", projectName: nil, seconds: 1000, sessions: 1, isDone: true),
            TaskTimeRow(id: "none", taskID: nil, title: "Без задачи", projectName: nil, seconds: 0, sessions: 2, isDone: false)
        ]
        let shares = WeekSummaryView.shareWidths(rows: rows, maxWidth: 90)
        #expect(shares == [90, 22.5, 0])
        #expect(WeekSummaryView.shareWidths(rows: [], maxWidth: 90).isEmpty)
        #expect(WeekSummaryView.status(rows[0]) == "in progress")
        #expect(WeekSummaryView.status(rows[1]) == "done")
        #expect(WeekSummaryView.status(rows[2]) == "—")
    }

    @Test
    func weekRangeTitleHandlesMonthBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let same = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3)) ?? .now
        #expect(WeekSummaryView.rangeTitle(start: same, calendar: calendar) == "October 3 – October 9")
        let cross = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28)) ?? .now
        #expect(WeekSummaryView.rangeTitle(start: cross, calendar: calendar) == "September 28 – October 4")
    }

    @Test
    func dayLabelUsesSelectedLanguage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let friday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9)) ?? .now
        #expect(WeekSummaryView.dayLabel(friday, calendar: calendar) == "fr")
    }

    @Test
    func historyActionTitleDependsOnLiveness() {
        #expect(HistoryRow.actionTitle(isLive: true) == "Open session")
        #expect(HistoryRow.actionTitle(isLive: false) == "Resume")
    }

    @Test
    func historyDayTitleMarksTodayAndYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12)) ?? .now
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let older = calendar.date(byAdding: .day, value: -3, to: today) ?? today
        #expect(HistoryView.dayTitle(today, now: now, calendar: calendar) == "Today · Friday, October 9")
        #expect(HistoryView.dayTitle(yesterday, now: now, calendar: calendar) == "Yesterday · Thursday, October 8")
        #expect(HistoryView.dayTitle(older, now: now, calendar: calendar) == "Tuesday, October 6")
    }

    @Test
    func settingsStepperBoundsAreClamped() {
        #expect(FocusSettingsPane.maxParallelRange == 1...6)
        #expect(FocusSettingsPane.stalledReminderRange == 5...60)
        #expect(FocusSettingsPane.hooksTitle(installed: true) == "Agent hooks configured")
        #expect(FocusSettingsPane.hooksTitle(installed: false) == "Connect Claude Code or Codex")
        #expect(FocusSettingsPane.hooksPathText(path: "/Users/me/.claude/settings.json", home: "/Users/me") == "~/.claude/settings.json")
        #expect(FocusSettingsPane.hooksPathText(path: "/etc/x.json", home: "/Users/me") == "/etc/x.json")
        #expect(FocusSettingsPane.hooksPathText(path: "/Users/meow/x.json", home: "/Users/me") == "/Users/meow/x.json")
    }

    @Test
    func pomodoroTimerTextIsZeroPaddedMinutesAndSeconds() {
        #expect(PomodoroFormat.timerText(remainingSeconds: 1445) == "24:05")
        #expect(PomodoroFormat.timerText(remainingSeconds: 59) == "00:59")
        #expect(PomodoroFormat.timerText(remainingSeconds: -3) == "00:00")
        #expect(PomodoroFormat.timerText(remainingSeconds: 6000) == "100:00")
    }

    @Test
    func pomodoroCaptions() {
        #expect(PomodoroFormat.remainingCaption(plannedSeconds: 1500) == "remaining of 25 min")
        #expect(PomodoroFormat.cycleCaption(index: 2, cycle: 4) == "Pomodoro 2 of 4")
        #expect(PomodoroFormat.todayCaption(seconds: 12 * 60) == "12 min on this task today")
        #expect(PomodoroFormat.todayCaption(seconds: 0) == nil)
        #expect(PomodoroFormat.breakCaption(minutes: 5) == "then 5 min break")
        #expect(PomodoroFormat.startButtonTitle(minutes: 25) == "Start · 25 min")
        #expect(PomodoroFormat.startButtonTitle(minutes: nil) == "Start")
        #expect(PomodoroFormat.quickStartTitle(minutes: 50) == "Start 50 min")
        #expect(PomodoroFormat.pauseTitle(isPaused: false) == "Pause")
        #expect(PomodoroFormat.pauseTitle(isPaused: true) == "Resume")
    }

    @Test
    func sessionSubtitleNamesBoundTask() {
        let bound = BindableSession(id: "a", title: "t", detail: "d", projectName: nil, boundTaskTitle: "Фикс", isSameProject: true, defaultSelected: false)
        let free = BindableSession(id: "b", title: "t", detail: "d", projectName: nil, boundTaskTitle: nil, isSameProject: true, defaultSelected: true)
        #expect(PomodoroFormat.sessionTag(bound) == "for task “Фикс”")
        #expect(PomodoroFormat.sessionTag(free) == nil)
        #expect(StartTaskSheet.initialSelection([bound, free]) == ["b"])
    }

    @Test
    func timerChoiceMapsToMinutes() {
        #expect(StartTimerChoice.initial(defaultMinutes: 25) == .m25)
        #expect(StartTimerChoice.initial(defaultMinutes: 50) == .m50)
        #expect(StartTimerChoice.initial(defaultMinutes: 40) == .custom)
        #expect(StartTimerChoice.none.minutes(custom: 40) == nil)
        #expect(StartTimerChoice.m25.minutes(custom: 40) == 25)
        #expect(StartTimerChoice.m50.minutes(custom: 40) == 50)
        #expect(StartTimerChoice.custom.minutes(custom: 40) == 40)
        #expect(StartTimerChoice.custom.minutes(custom: 2) == 5)
        #expect(StartTimerChoice.custom.minutes(custom: 500) == 120)
        #expect(StartTimerChoice.custom.title == "Custom…")
        #expect(StartTimerChoice.allCases.map(\.title) == ["Without a timer", "25 min", "50 min", "90 min", "Custom…"])
    }

    @Test
    func movingIntoInProgressRequestsStartOnlyFromOtherColumns() {
        #expect(PomodoroFormat.shouldRequestStart(from: .todo, to: .inProgress))
        #expect(PomodoroFormat.shouldRequestStart(from: .backlog, to: .inProgress))
        #expect(PomodoroFormat.shouldRequestStart(from: .done, to: .inProgress))
        #expect(!PomodoroFormat.shouldRequestStart(from: .inProgress, to: .inProgress))
        #expect(!PomodoroFormat.shouldRequestStart(from: .inProgress, to: .done))
        #expect(!PomodoroFormat.shouldRequestStart(from: nil, to: .inProgress))
    }

    @Test
    func todaySecondsClipsSpansToStartOfDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = calendar.startOfDay(for: now)
        let spans = [
            ActivitySpan(kind: .you, sessionId: nil, taskId: "t", startedAt: start.addingTimeInterval(-600), endedAt: start.addingTimeInterval(300)),
            ActivitySpan(kind: .claude, sessionId: nil, taskId: "t", startedAt: start.addingTimeInterval(200), endedAt: start.addingTimeInterval(500)),
            ActivitySpan(kind: .you, sessionId: nil, taskId: "t", startedAt: start.addingTimeInterval(-900), endedAt: start.addingTimeInterval(-700))
        ]
        #expect(TaskDetailView.todaySeconds(spans: spans, now: now, calendar: calendar) == 500)
    }

    @Test
    func quickStartOnlyForInProgressTasks() {
        #expect(TaskPomodoroSection.showsQuickStart(column: .inProgress))
        #expect(!TaskPomodoroSection.showsQuickStart(column: .todo))
        #expect(!TaskPomodoroSection.showsQuickStart(column: .done))
        #expect(!TaskPomodoroSection.showsQuickStart(column: nil))
    }

    @Test
    func resumableIDsKeepLiveAndExistingPaths() {
        let records = [
            SessionRecord(id: "live", cwd: nil, projectName: nil, title: "live", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: .distantPast, lastActivityAt: .distantPast, endedAt: nil, status: .ended, taskId: nil, transcriptPath: nil),
            SessionRecord(id: "gone", cwd: "/definitely/missing/path", projectName: nil, title: "gone", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: .distantPast, lastActivityAt: .distantPast, endedAt: nil, status: .ended, taskId: nil, transcriptPath: nil),
            SessionRecord(id: "here", cwd: NSTemporaryDirectory(), projectName: nil, title: "here", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: .distantPast, lastActivityAt: .distantPast, endedAt: nil, status: .ended, taskId: nil, transcriptPath: nil),
            SessionRecord(id: "none", cwd: nil, projectName: nil, title: "none", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: .distantPast, lastActivityAt: .distantPast, endedAt: nil, status: .ended, taskId: nil, transcriptPath: nil)
        ]
        #expect(TaskDetailView.resumableIDs(records: records, live: ["live"]) == ["live", "here"])
    }

    @Test
    func replaceCaptionOnlyForOtherTasksPomodoro() {
        let running = PomodoroSnapshot(id: "p", taskID: "a", taskTitle: "A", phase: .focus, plannedSeconds: 1500, remainingSeconds: 900, progress: 0.4, isPaused: false, cycleIndex: 1, cycle: 4)
        let loose = PomodoroSnapshot(id: "q", taskID: nil, taskTitle: nil, phase: .break, plannedSeconds: 300, remainingSeconds: 100, progress: 0.6, isPaused: false, cycleIndex: 1, cycle: 4)
        #expect(PomodoroFormat.replaceCaption(pomodoro: running, startingTaskID: "b") == "Pomodoro “A” is running")
        #expect(PomodoroFormat.replaceCaption(pomodoro: running, startingTaskID: "a") == nil)
        #expect(PomodoroFormat.replaceCaption(pomodoro: nil, startingTaskID: "b") == nil)
        #expect(PomodoroFormat.replaceCaption(pomodoro: loose, startingTaskID: "b") == "A pomodoro is running")
        #expect(PomodoroFormat.replaceButtonTitle == "Replace")
    }

    @Test
    func activeElsewhereCaptionNamesTask() {
        #expect(PomodoroFormat.activeElsewhereCaption(taskTitle: "Фикс") == "Pomodoro “Фикс” is running")
        #expect(PomodoroFormat.activeElsewhereCaption(taskTitle: nil) == "A pomodoro is running")
    }
    @Test
    func pickTaskTodoCaption() {
        #expect(PickTaskCard.todoCaption(3) == "Todo · 3")
    }

    @Test
    func pickTaskPrimaryIsFirstWithSessions() {
        let options = [
            PickTaskOption(taskID: "a", title: "A", projectName: "p", liveSessionCount: 1, sessionStateText: ""),
            PickTaskOption(taskID: "b", title: "B", projectName: nil, liveSessionCount: 0, sessionStateText: "")
        ]
        #expect(PickTaskCard.primaryOptionID(options) == "a")
        #expect(PickTaskCard.primaryOptionID(Array(options.dropFirst())) == nil)
        #expect(PickTaskCard.primaryOptionID([]) == nil)
    }

    @Test
    func pomodoroEndHeadlineAndTitle() {
        #expect(PomodoroEndCard.headline(cycleIndex: 1, cycle: 4) == "Focus 1 of 4 complete")
        #expect(PomodoroEndCard.title(minutes: 25, taskTitle: "Чат-бот") == "25 minutes on “Чат-бот”")
        #expect(PomodoroEndCard.title(minutes: 21, taskTitle: "X") == "21 minutes on “X”")
        #expect(PomodoroEndCard.title(minutes: 22, taskTitle: "X") == "22 minutes on “X”")
        #expect(PomodoroEndCard.title(minutes: 25, taskTitle: "") == "25 minutes of focus")
    }

    @Test
    func pomodoroEndKpiValuesAndDistractionDetail() {
        #expect(PomodoroEndCard.minutesValue(1260) == "21 min")
        #expect(PomodoroEndCard.minutesValue(0) == "0 min")
        #expect(PomodoroEndCard.distractionDetail(count: 1, returned: 1) == "1 time, returned")
        #expect(PomodoroEndCard.distractionDetail(count: 2, returned: 0) == "2 times")
        #expect(PomodoroEndCard.distractionDetail(count: 3, returned: 1) == "3 times, returned 1")
        #expect(PomodoroEndCard.distractionDetail(count: 0, returned: 0) == nil)
    }

    @Test
    func pomodoroEndWhileRunningItems() {
        let items = PomodoroEndCard.whileRunningItems(finishedSessionTitles: ["добавь проверку"], checkedCriteria: ["Бот отвечает"])
        #expect(items == [
            PomodoroEndCard.Item(text: "“добавь проверку” — the agent finished", isCriterion: false),
            PomodoroEndCard.Item(text: "Criterion “Бот отвечает” checked", isCriterion: true)
        ])
        #expect(PomodoroEndCard.whileRunningItems(finishedSessionTitles: [], checkedCriteria: []).isEmpty)
    }

    @Test
    func pomodoroEndButtonTitles() {
        #expect(PomodoroEndCard.continueTitle(minutes: 50) == "Skip break — another 50 min")
        #expect(PomodoroEndCard.breakTitle(minutes: 10) == "☕ Start break · 10 min")
        #expect(PomodoroEndCard.breakHeadline(minutes: 10, secondsLeft: 4) == "10 min break starts in 4 s")
        #expect(PomodoroEndCard.breakHeadline(minutes: 10, secondsLeft: nil) == "10 min break")
        #expect(PomodoroEndCard.afterBreakCaption(focusMinutes: 50) == "then 50 min of focus")
        #expect(PomodoroEndCard.countdownProgress(secondsLeft: 5) == 1)
        #expect(PomodoroEndCard.countdownProgress(secondsLeft: 0) == 0)
        #expect(PomodoroEndCard.prefill(note: "  Шаг  ") == "Шаг")
        #expect(PomodoroEndCard.prefill(note: nil) == "")
    }

    @Test
    func breakEndTexts() {
        #expect(BreakEndCard.title(taskTitle: "Чат-бот") == "Return to “Чат-бот”")
        #expect(BreakEndCard.title(taskTitle: "") == "Return to task")
        #expect(BreakEndCard.restedLine(finishedSessionTitles: []) == nil)
        #expect(BreakEndCard.restedLine(finishedSessionTitles: ["a", "b"]) == "While you rested, the agent finished «a», «b»")
        #expect(BreakEndCard.extendTitle(minutes: 5) == "5 more min of rest")
        #expect(BreakEndCard.noteText(" ") == nil)
        #expect(BreakEndCard.noteText(" Шаг ") == "Шаг")
    }

    @Test
    func hubTimerCaptionAndFooterWithPomodoros() {
        let focusSnap = PomodoroSnapshot(id: "p", taskID: "t", taskTitle: "T", phase: .focus, plannedSeconds: 1500, remainingSeconds: 1122, progress: 0.25, isPaused: false, cycleIndex: 1, cycle: 4)
        let breakSnap = PomodoroSnapshot(id: "b", taskID: "t", taskTitle: "T", phase: .break, plannedSeconds: 300, remainingSeconds: 192, progress: 0.36, isPaused: false, cycleIndex: 1, cycle: 4)
        #expect(SessionHubView.timerCaption(focusSnap, breakMinutes: 10, focusMinutes: 50) == "Focus 1 of 4 · of 25 min · then 10 min break")
        #expect(SessionHubView.timerCaption(breakSnap, breakMinutes: 10, focusMinutes: 50) == "Break · of 5 min · then 50 min focus")
    }

    @Test
    func newSessionHintDetailShowsProjectAndFirstPromptLine() {
        #expect(SessionHubView.newSessionDetail(cwd: "/Users/me/focus", prompt: "хочу приложение\nи ещё") == "· focus · «хочу приложение»")
        #expect(SessionHubView.newSessionDetail(cwd: nil, prompt: "  ") == "")
        #expect(SessionHubView.newSessionDetail(cwd: "/tmp/dashboard-metrics", prompt: "<system-reminder>ctx</system-reminder>\nДобавь метрики") == "· dashboard-metrics · «Добавь метрики»")
        #expect(SessionHubView.newSessionDetail(cwd: "/tmp/dashboard-metrics", prompt: "<system-reminder>") == "· dashboard-metrics")
        #expect(SessionHubView.newSessionDetail(cwd: "/tmp/p", prompt: String(repeating: "а", count: 70)) == "· p · «" + String(repeating: "а", count: 60) + "…»")
        #expect(SessionHubView.footerText(focusSeconds: 1860, distractionSeconds: 0, pomodoroCount: 1) == "Today: focus 31 min · pomodoros 1 · distractions 0 min")
        #expect(SessionHubView.footerText(focusSeconds: 1860, distractionSeconds: 0, pomodoroCount: 0) == "Today: focus 31 min · distractions 0 min")
    }

    @Test
    func daySummaryMarkdownListsPomodorosWhenAny() {
        let calendar = daySummaryCalendar()
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        let with = DaySummaryFormatter.markdown(report: summaryReport(), done: [], open: [], tomorrow: nil, day: day, pomodoroCount: 3, calendar: calendar)
        #expect(with.contains("- Distractions: 11 min (4 times, returned 3)\n- Pomodoros: 3\n- Peak parallel sessions: 4"))
        let without = DaySummaryFormatter.markdown(report: summaryReport(), done: [], open: [], tomorrow: nil, day: day, pomodoroCount: 0, calendar: calendar)
        #expect(!without.contains("Pomodoros"))
    }

    @Test
    func pomodoroEndDraftSavedOnlyWhenChanged() {
        #expect(PomodoroEndCard.draftToSave(text: "  новый шаг ", saved: "старый") == "новый шаг")
        #expect(PomodoroEndCard.draftToSave(text: "старый ", saved: "старый") == nil)
        #expect(PomodoroEndCard.draftToSave(text: "   ", saved: "старый") == nil)
        #expect(PomodoroEndCard.draftToSave(text: "шаг", saved: "") == "шаг")
    }

    @Test
    func pickTaskTodoSummaryCollapsesTail() {
        #expect(PickTaskCard.todoSummary(titles: []) == "")
        #expect(PickTaskCard.todoSummary(titles: ["A"]) == "A")
        #expect(PickTaskCard.todoSummary(titles: ["A", "B"]) == "A · B")
        #expect(PickTaskCard.todoSummary(titles: ["A", "B", "C"]) == "A · B · 1 more")
        #expect(PickTaskCard.todoSummary(titles: ["A", "B", "C", "D", "E"]) == "A · B · 3 more")
    }

    @Test
    func pickTaskCaptionsAndExpansion() {
        #expect(PickTaskCard.inProgressCaption(2) == "In progress · 2")
        #expect(PickTaskCard.showsTodoList(inProgressIsEmpty: true, userExpanded: false))
        #expect(!PickTaskCard.showsTodoList(inProgressIsEmpty: false, userExpanded: false))
        #expect(PickTaskCard.showsTodoList(inProgressIsEmpty: false, userExpanded: true))
        #expect(PickTaskCard.showsEmptyCaption(inProgressIsEmpty: true, todoIsEmpty: false))
        #expect(!PickTaskCard.showsEmptyCaption(inProgressIsEmpty: true, todoIsEmpty: true))
        #expect(!PickTaskCard.showsEmptyCaption(inProgressIsEmpty: false, todoIsEmpty: false))
    }

    @Test
    func pickTaskStateColorWarnsOnlyWithoutSessions() {
        let none = PickTaskOption(taskID: "a", title: "A", projectName: nil, liveSessionCount: 0, sessionStateText: "нет сессий — добавишь следующим шагом")
        let some = PickTaskOption(taskID: "b", title: "B", projectName: nil, liveSessionCount: 2, sessionStateText: "2 сессии · ждёт 3 мин")
        #expect(PickTaskCard.stateIsWarning(none))
        #expect(!PickTaskCard.stateIsWarning(some))
    }

    @Test
    func taskSessionsPickerSectionsAndTitles() {
        func choice(_ id: String, bound: Bool = false, same: Bool = true, other: String? = nil) -> BindableSession {
            BindableSession(id: id, title: id, detail: "", projectName: nil, boundTaskTitle: other, isSameProject: same, defaultSelected: bound || (same && other == nil), isBound: bound)
        }
        let choices = [choice("b", bound: true), choice("s"), choice("t", other: "Фикс"), choice("o", same: false)]
        let sections = TaskSessionsPicker.sections(choices, projectName: "wb")
        #expect(sections.map(\.title) == ["Linked · 1", "Open · project wb", "Open · other projects"])
        #expect(sections.map { $0.rows.map(\.id) } == [["b"], ["s", "t"], ["o"]])
        #expect(TaskSessionsPicker.sections([choice("o", same: false)], projectName: nil).map(\.title) == ["Open sessions"])
        #expect(TaskSessionsPicker.applyTitle((add: ["s"], remove: [])) == "Add 1")
        #expect(TaskSessionsPicker.applyTitle((add: [], remove: [])) == "Add 0")
        #expect(TaskSessionsPicker.applyTitle((add: ["s"], remove: ["b"])) == "Save")
        #expect(TaskSessionsPicker.cancelTitle(hasBound: false) == "Later")
        #expect(TaskSessionsPicker.cancelTitle(hasBound: true) == "Cancel")
        #expect(TaskSessionsPicker.trailingLabel(choices[0]) == nil)
        #expect(TaskSessionsPicker.trailingLabel(choices[1]) == "no task")
        #expect(TaskSessionsPicker.trailingLabel(choices[2]) == "for task “Фикс”")
        #expect(TaskSessionsPicker.footerHint((add: ["t"], remove: []), choices: choices) == "This session will move from “Фикс” to this task")
        #expect(TaskSessionsPicker.footerHint((add: [], remove: ["b"]), choices: choices) == "Deselected sessions will be unlinked from the task")
        #expect(TaskSessionsPicker.footerHint((add: ["s"], remove: []), choices: choices) == "Sessions in other tasks stay there unless you select them")
    }

    @Test
    func closeTaskTexts() {
        #expect(ClosedTaskBanner.text("A") == "“A” closed · moved to Done")
        #expect(TaskDetailView.showsCloseTask(column: .inProgress))
        #expect(TaskDetailView.showsCloseTask(column: .todo))
        #expect(!TaskDetailView.showsCloseTask(column: .done))
        #expect(!TaskDetailView.showsCloseTask(column: nil))
    }

    @Test
    func hubFocusBlockTexts() {
        #expect(SessionHubView.focusBlockCaption(3) == "Task sessions · 3")
        #expect(PomodoroFormat.startFocusTitle(minutes: 50) == "▶ Start focus · 50 min")
        #expect(SessionHubView.hereDetail("ждёт ответа", isHere: true) == "you are here · ждёт ответа")
        #expect(SessionHubView.hereDetail("ждёт ответа", isHere: false) == "ждёт ответа")
        #expect(SessionHubView.hereDetail("", isHere: true) == "you are here")
    }

    @Test
    func timerLengthChoices() {
        #expect(PomodoroFormat.focusChoices == [25, 50, 90])
        #expect(PomodoroFormat.breakChoices == [5, 10, 15, 20])
        #expect(PomodoroFormat.choiceTitle(50, defaultMinutes: 50) == "50 min · default")
        #expect(PomodoroFormat.choiceTitle(25, defaultMinutes: 50) == "25 min")
        #expect(PomodoroFormat.breakButtonTitle(minutes: 10) == "10 min break")
        #expect(PomodoroFormat.clampFocus(500) == 120)
        #expect(PomodoroFormat.clampFocus(2) == 5)
        #expect(StartTimerChoice.allCases.map(\.title) == ["Without a timer", "25 min", "50 min", "90 min", "Custom…"])
        #expect(StartTimerChoice.initial(defaultMinutes: 50) == .m50)
        #expect(StartTimerChoice.initial(defaultMinutes: 90) == .m90)
        #expect(StartTimerChoice.m90.minutes(custom: 0) == 90)
    }

    @Test
    func waitingOutsideTexts() {
        #expect(WaitingOutsideSection.caption(2) == "Waiting outside task · 2")
        #expect(WaitingOutsideSection.buttonTitle(2, expanded: false) == "Waiting outside task · 2 ▸")
        #expect(WaitingOutsideSection.buttonTitle(2, expanded: true) == "Waiting outside task · 2 ▾")
        #expect(WaitingOutsideSection.explainer(taskTitle: "Воронка") == "The agents in these sessions have finished and are waiting for you. They are not part of “Воронка”.")
        #expect(WaitingOutsideSection.ownerText(taskTitle: nil) == "no task")
        #expect(WaitingOutsideSection.ownerText(taskTitle: "Онбординг") == "for task “Онбординг”")
        #expect(WaitingOutsideSection.addTitle(taskTitle: "Воронка") == "Add to “Воронка”")
    }

    @Test
    func withoutTaskHubShowsOnlyTaskChoice() {
        #expect(SessionHubView.showsOnlyTaskChoice(hasTask: false, pomodoroActive: false))
        #expect(!SessionHubView.showsOnlyTaskChoice(hasTask: true, pomodoroActive: false))
        #expect(!SessionHubView.showsOnlyTaskChoice(hasTask: false, pomodoroActive: true))
    }

    @Test
    func returnedCardIsLeftToTheCompletionCard() {
        #expect(!FocusIslandSection.showsCardView(nil))
        #expect(!FocusIslandSection.showsCardView(.returned(sessionID: "s")))
        #expect(FocusIslandSection.showsCardView(.pomodoroEnd(pomodoroID: "p")))
        #expect(FocusIslandSection.showsCardView(.dayStart))
    }
}
