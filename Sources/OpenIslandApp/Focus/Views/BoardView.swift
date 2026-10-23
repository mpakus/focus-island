import OpenIslandCore
import FocusCore
import Foundation
import SwiftUI

extension FocusStyle {
    static let windowBackground = Color(focusHex: 0x1E1E1E)
    static let barBackground = Color(focusHex: 0x262628)
    static let columnFill = Color(focusHex: 0x1A1A1C)
    static let cardFill = Color(focusHex: 0x2A2A2D)
    static let segmentFill = Color(focusHex: 0x2C2C2E)
    static let segmentSelected = Color(focusHex: 0x5A5A5E)
    static let segmentText = Color(focusHex: 0xD1D1D6)
    static let fieldFill = Color(focusHex: 0x1C1C1E)
    static let fieldBorder = Color.white.opacity(0.12)
    static let menuFill = Color(focusHex: 0x3A3A3C)
    static let parkedDot = Color(focusHex: 0x636366)
    static let badgeFill = Color(focusHex: 0x0A84FF).opacity(0.25)
    static let badgeText = Color(focusHex: 0xB5D4FF)
}

enum BoardTab: String, CaseIterable, Sendable {
    case board
    case today
    case week
    case history

    var title: String {
        switch self {
        case .board: L10n.tr("focus.board")
        case .today: L10n.tr("focus.today")
        case .week: L10n.tr("focus.week")
        case .history: L10n.tr("focus.history")
        }
    }

    nonisolated static func explicit(userInfo: [AnyHashable: Any]?) -> BoardTab? {
        (userInfo?["tab"] as? String).flatMap { BoardTab(rawValue: $0) }
    }

    nonisolated static func from(userInfo: [AnyHashable: Any]?) -> BoardTab {
        guard let raw = userInfo?["tab"] as? String else { return .board }
        return BoardTab(rawValue: raw) ?? .board
    }
}

enum TaskCardBorder: Equatable, Sendable {
    case waiting
    case running
    case review
    case none
}

struct BoardToolbarCounts: Equatable, Sendable {
    var working: Int
    var waiting: Int
    var review: Int
}

@MainActor
@Observable
final class BoardWindowState {
    var tab: BoardTab = .board
}

struct BoardRootView: View {
    @Bindable var focus: FocusCoordinator
    @Bindable var state: BoardWindowState
    @State private var projectFilter: String?
    @State private var showsArchive = false
    @State private var showsJira = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(FocusStyle.hairline)
            content
        }
        .background(FocusStyle.windowBackground)
        .frame(minWidth: 900, minHeight: 520)
        .preferredColorScheme(.dark)
        .environment(\.locale, LanguageManager.shared.locale)
        .onChange(of: LanguageManager.shared.language) { _, _ in BoardWindowController.shared.refreshTitle() }
        .sheet(item: startTaskBinding) { item in
            StartTaskSheet(focus: focus, taskID: item.id).id(item.id)
        }
        .sheet(isPresented: $showsJira) { JiraImportView(focus: focus) }
    }

    private var startTaskBinding: Binding<StartTaskItem?> {
        Binding(
            get: { focus.pendingStartTaskID.map { StartTaskItem(id: $0) } },
            set: { if $0 == nil { focus.clearPendingStartTask() } }
        )
    }

    private var toolbar: some View {
        let counts = BoardView.toolbarCounts(rows: focus.hubRows)
        return HStack(spacing: 16) {
            HStack(spacing: 0) {
                ForEach(BoardTab.allCases, id: \.self) { tab in
                    Button {
                        state.tab = tab
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(state.tab == tab ? Color.white : FocusStyle.segmentText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(state.tab == tab ? FocusStyle.segmentSelected : .clear))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(state.tab == tab ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(FocusStyle.segmentFill))
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                StatusDot(color: FocusStyle.working)
                Text(BoardView.workingLabel(counts.working))
            }
            HStack(spacing: 6) {
                StatusDot(color: FocusStyle.waiting)
                Text(BoardView.waitingLabel(counts.waiting))
            }
            HStack(spacing: 6) {
                Text("✓").foregroundStyle(FocusStyle.done)
                Text(BoardView.reviewLabel(counts.review))
            }
            if state.tab == .board {
                Menu("Jira") {
                    Button(L10n.tr("jira.sync_assigned")) { focus.jira.syncAssignedIssues(links: Array(focus.board.jiraLinks.values)) }
                        .disabled(focus.jira.connection == nil || focus.jira.isBusy || focus.storeIsInMemoryFallback)
                    Button(L10n.tr("jira.add_from_jira")) { showsJira = true }
                    Button(L10n.tr("jira.refresh_linked")) { focus.jira.refresh(links: Array(focus.board.jiraLinks.values)) }
                        .disabled(focus.jira.connection == nil || focus.jira.isBusy)
                    Divider()
                    Button(L10n.tr("jira.reconnect")) { focus.jira.reconnect() }
                        .disabled(focus.jira.isBusy)
                    Button(L10n.tr("jira.disconnect")) { focus.jira.disconnect() }
                        .disabled(focus.jira.connection == nil && focus.jira.error == nil && !focus.jira.isBusy)
                }
                .fixedSize()
                filterMenu
            }
        }
        .font(FocusStyle.secondaryFont)
        .foregroundStyle(FocusStyle.segmentText)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(FocusStyle.barBackground)
    }

    private var filterMenu: some View {
        Menu {
            Picker(L10n.tr("focus.project"), selection: $projectFilter) {
                Text(L10n.tr("focus.all_projects")).tag(String?.none)
                ForEach(focus.knownProjectPaths(), id: \.self) { path in
                    Text(URL(fileURLWithPath: path).lastPathComponent).tag(String?.some(path))
                }
            }
            Divider()
            Toggle(L10n.tr("focus.completed_archive"), isOn: $showsArchive)
        } label: {
            Text(projectFilter.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L10n.tr("focus.all_projects"))
                .font(.system(size: 13))
                .foregroundStyle(FocusStyle.primaryText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).fill(FocusStyle.segmentFill))
    }

    @ViewBuilder
    private var content: some View {
        switch state.tab {
        case .board:
            VStack(spacing: 0) {
                JiraOperationStatus(jira: focus.jira).padding(.horizontal, 16)
                BoardView(focus: focus, projectFilter: projectFilter, showsArchive: showsArchive)
            }
        case .today:
            DaySummaryView(focus: focus)
        case .week:
            WeekSummaryView(focus: focus)
        case .history:
            HistoryView(focus: focus)
        }
    }
}

struct BoardTabPlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(FocusStyle.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BoardView: View {
    @Bindable var focus: FocusCoordinator
    var projectFilter: String?
    var showsArchive: Bool
    @State private var editingTask: FocusTask?
    @State private var pendingStartAfterEdit: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(BoardColumn.allCases) { column in
                BoardColumnView(
                    focus: focus,
                    column: column,
                    tasks: visibleTasks(in: column),
                    onOpen: { editingTask = $0 }
                )
            }
        }
        .padding(16)
        .sheet(item: $editingTask, onDismiss: {
            if let id = pendingStartAfterEdit {
                pendingStartAfterEdit = nil
                focus.requestStartTask(taskID: id)
            }
        }) { task in
            TaskDetailView(focus: focus, task: task, onRequestStart: { pendingStartAfterEdit = $0 })
        }
        .onChange(of: focus.pendingStartTaskID) { _, pending in
            if pending != nil, editingTask != nil {
                editingTask = nil
            }
        }
    }

    private func visibleTasks(in column: BoardColumn) -> [FocusTask] {
        var tasks = focus.board.tasks(in: column)
        if let projectFilter {
            tasks = tasks.filter { $0.projectPath == projectFilter }
        }
        if column == .done && !showsArchive {
            let cutoff = Date.now.addingTimeInterval(-7 * 86_400)
            tasks = tasks.filter { ($0.doneAt ?? .distantPast) >= cutoff }
        }
        return tasks
    }

    nonisolated static func toolbarCounts(rows: [HubRow]) -> BoardToolbarCounts {
        BoardToolbarCounts(
            working: rows.filter { $0.group == .running }.count,
            waiting: rows.filter { $0.group == .waiting }.count,
            review: rows.filter { $0.group == .review }.count
        )
    }

    nonisolated static func workingLabel(_ count: Int) -> String {
        L10n.tr(L10n.pluralKey(count, one: "board.working.one", few: "board.working.many", many: "board.working.many"), "\(count)")
    }

    nonisolated static func waitingLabel(_ count: Int) -> String {
        L10n.tr(L10n.pluralKey(count, one: "board.waiting.one", few: "board.waiting.many", many: "board.waiting.many"), "\(count)")
    }

    nonisolated static func reviewLabel(_ count: Int) -> String {
        L10n.tr("focus.done", "\(count)")
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return L10n.tr("focus.0_min") }
        let minutes = FocusText.roundedUpMinutes(seconds)
        guard minutes >= 60 else { return L10n.tr("focus.min", "\(minutes)") }
        let rest = minutes % 60
        return rest == 0 ? L10n.tr("focus.h", "\(minutes / 60)") : String(format: L10n.tr("focus.d_h_02d_min"), minutes / 60, rest)
    }

    nonisolated static func sessionsWord(_ count: Int) -> String {
        return L10n.tr(L10n.pluralKey(count, one: "focus.session_47", few: "focus.sessions_48", many: "focus.sessions_49"))
    }
}

struct BoardColumnView: View {
    @Bindable var focus: FocusCoordinator
    let column: BoardColumn
    let tasks: [FocusTask]
    let onOpen: (FocusTask) -> Void
    @State private var newTitle = ""
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(column.title).font(.system(size: 13, weight: .semibold))
                Text("\(tasks.count)").font(.system(size: 13, weight: .medium)).foregroundStyle(FocusStyle.captionText)
            }
            .foregroundStyle(FocusStyle.primaryText)
            .padding(.horizontal, 2)
            .padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCardView(focus: focus, task: task)
                            .onTapGesture(count: 2) { onOpen(task) }
                            .draggable(task.id)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first, id != task.id else { return false }
                                drop(id: id, before: task.id)
                                return true
                            }
                    }
                }
            }
            TextField(L10n.tr("focus.task"), text: $newTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: FocusStyle.smallRadius)
                        .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .onSubmit {
                    focus.createTask(title: newTitle, column: column, projectPath: nil)
                    newTitle = ""
                }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? FocusStyle.accent.opacity(0.18) : FocusStyle.columnFill)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(FocusStyle.hairline.opacity(0.6), lineWidth: 1))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            drop(id: id, before: nil)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func drop(id: String, before beforeID: String?) {
        let previous = focus.board.task(id: id)?.boardColumn
        focus.moveTask(id: id, to: column, before: beforeID)
        if PomodoroFormat.shouldRequestStart(from: previous, to: column) {
            focus.requestStartTask(taskID: id)
        }
    }
}

struct TaskCardView: View {
    @Bindable var focus: FocusCoordinator
    let task: FocusTask

    var body: some View {
        let rows = focus.hubRows.filter { $0.taskID == task.id }
        let aggregate = focus.aggregate(taskID: task.id)
        let records = aggregate.records
        let live = focus.liveSessionIDs
        let isDone = task.boardColumn == .done
        let border = Self.borderStyle(rows: rows)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isDone ? FocusStyle.secondaryText : FocusStyle.primaryText)
                    .strikethrough(isDone, color: FocusStyle.captionText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let path = task.projectPath {
                    ProjectTag(URL(fileURLWithPath: path).lastPathComponent)
                }
                if focus.currentTask?.id == task.id && !isDone {
                    Text(L10n.tr("focus.in_focus"))
                        .font(.system(size: 11))
                        .foregroundStyle(FocusStyle.badgeText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(FocusStyle.badgeFill))
                }
            }
            ForEach(rows) { row in
                sessionLine(row)
            }
            if let link = focus.board.jiraLinks[task.id] { JiraTaskBadge(link: link) }
            if let summary = Self.pastSummary(records: records, live: live), !isDone {
                HStack(spacing: 8) {
                    StatusDot(color: FocusStyle.parkedDot)
                    Text(summary)
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
            }
            if isDone {
                Text(Self.doneCaption(doneAt: task.doneAt, records: records, now: .now, calendar: .current))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
            }
            if let footer = Self.footerText(aggregate: aggregate) {
                Text(footer)
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(FocusStyle.cardFill))
        .overlay(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).stroke(Self.borderColor(border), lineWidth: 1))
        .opacity(isDone ? 0.8 : 1)
        .accessibilityElement(children: .combine)
    }

    private func sessionLine(_ row: HubRow) -> some View {
        let isWaiting = row.group == .waiting
        return HStack(spacing: 8) {
            if row.group == .review {
                Text("✓").font(.system(size: 11, weight: .bold)).foregroundStyle(FocusStyle.done)
            } else {
                StatusDot(color: Self.dotColor(row.group))
            }
            Text(row.detail)
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(isWaiting ? FocusStyle.waitingText : FocusStyle.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.group == .running, let progress = row.progress {
                PlanProgressBar(progress: progress, width: 48)
            }
            if isWaiting {
                Text(Self.waitLabel(since: row.since, now: .now))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.waitingText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).fill(isWaiting ? FocusStyle.waiting.opacity(0.14) : Color.black.opacity(0.28)))
    }

    nonisolated static func footerText(aggregate: TaskAggregate) -> String? {
        var parts: [String] = []
        if let progress = aggregate.criteria {
            parts.append(L10n.tr("focus.criteria_of", "\(progress.done)", "\(progress.total)"))
        }
        if !aggregate.sessionIDsWithQueuedPrompt.isEmpty {
            parts.append(L10n.tr("focus.prompt_queued"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    nonisolated static func dotColor(_ group: HubGroup) -> Color {
        switch group {
        case .running: FocusStyle.working
        case .waiting: FocusStyle.waiting
        case .review: FocusStyle.done
        case .idle, .unbound, .parked, .done: FocusStyle.parkedDot
        }
    }

    nonisolated static func borderColor(_ border: TaskCardBorder) -> Color {
        switch border {
        case .waiting: FocusStyle.waiting.opacity(0.5)
        case .running: FocusStyle.working.opacity(0.45)
        case .review: FocusStyle.done.opacity(0.45)
        case .none: FocusStyle.hairline.opacity(0.6)
        }
    }

    nonisolated static func borderStyle(rows: [HubRow]) -> TaskCardBorder {
        if rows.contains(where: { $0.group == .waiting }) { return .waiting }
        if rows.contains(where: { $0.group == .running }) { return .running }
        if rows.contains(where: { $0.group == .review }) { return .review }
        return .none
    }

    nonisolated static func sessionSeconds(_ record: SessionRecord) -> TimeInterval {
        max(0, (record.endedAt ?? record.lastActivityAt).timeIntervalSince(record.startedAt))
    }

    nonisolated static func pastSummary(records: [SessionRecord], live: Set<String>) -> String? {
        let past = records.filter { !live.contains($0.id) }
        guard !past.isEmpty else { return nil }
        let total = past.reduce(0) { $0 + sessionSeconds($1) }
        return L10n.tr("focus.more", "\(past.count)", "\(BoardView.sessionsWord(past.count))", "\(BoardView.duration(total))")
    }

    nonisolated static func waitLabel(since: Date, now: Date) -> String {
        L10n.tr("focus.min_55", "\(FocusText.minutes(now.timeIntervalSince(since)))")
    }

    nonisolated static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L10n.tr("focus.today_56") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.tr("focus.yesterday")
        }
        let formatter = DateFormatter()
        formatter.locale = LanguageManager.shared.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        return formatter.string(from: date)
    }

    nonisolated static func doneCaption(doneAt: Date?, records: [SessionRecord], now: Date, calendar: Calendar) -> String {
        var parts: [String] = []
        if let doneAt {
            parts.append(dayLabel(doneAt, now: now, calendar: calendar))
        }
        if !records.isEmpty {
            let total = records.reduce(0) { $0 + sessionSeconds($1) }
            parts.append("\(records.count) \(BoardView.sessionsWord(records.count))")
            parts.append(BoardView.duration(total))
        }
        return parts.joined(separator: " · ")
    }
}
