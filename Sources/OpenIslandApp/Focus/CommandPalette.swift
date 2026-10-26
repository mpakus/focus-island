import AppKit
import FocusCore
import OpenIslandCore
import SwiftUI

enum PaletteAction: Equatable, Sendable {
    case task(String), session(String), review(String), capture(String)
    case startTimer, pauseTimer, resumeTimer, board
}

struct PaletteCommand: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let action: PaletteAction

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            (title + " " + detail).localizedStandardContains(String($0))
        }
    }
}

extension FocusCoordinator {
    func paletteCommands(query: String) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        for row in hubRows where row.group != .done && row.group != .parked {
            let review = row.group == .review
            commands.append(PaletteCommand(id: "session:" + row.id,
                title: L10n.tr(review ? "palette.review_session" : "palette.open_session", sessionTitle(row.id)),
                detail: [row.group.title, row.projectName, board.task(id: row.taskID)?.title].compactMap { $0 }.joined(separator: " · "),
                symbol: review ? "doc.text.magnifyingglass" : "terminal",
                action: review ? .review(row.id) : .session(row.id)))
        }
        if let pomodoro {
            commands.append(PaletteCommand(id: "timer", title: L10n.tr(pomodoro.isPaused ? "palette.resume_timer" : "palette.pause_timer"),
                detail: pomodoro.taskTitle ?? "", symbol: pomodoro.isPaused ? "play" : "pause",
                action: pomodoro.isPaused ? .resumeTimer : .pauseTimer))
        } else if let task = currentTask {
            commands.append(PaletteCommand(id: "timer", title: L10n.tr("palette.start_timer"), detail: task.title, symbol: "timer", action: .startTimer))
        }
        commands.append(PaletteCommand(id: "board", title: L10n.tr("palette.open_board"), detail: "", symbol: "rectangle.split.3x1", action: .board))
        let tasks = board.tasks.filter { $0.boardColumn != .done }.sorted {
            if ($0.id == currentTask?.id) != ($1.id == currentTask?.id) { return $0.id == currentTask?.id }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.id < $1.id
        }
        for task in tasks {
            commands.append(PaletteCommand(id: "task:" + task.id, title: L10n.tr("palette.focus_task", task.title),
                detail: [task.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }, board.jiraLinks[task.id]?.key, board.clickUpLinks[task.id]?.displayID].compactMap { $0 }.joined(separator: " · "),
                symbol: "scope", action: .task(task.id)))
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        commands = Array(commands.filter { $0.matches(text) }.prefix(40))
        if !text.isEmpty {
            commands.append(PaletteCommand(id: "capture", title: L10n.tr("palette.capture", text), detail: L10n.tr("focus.from_to_do"), symbol: "plus", action: .capture(text)))
        }
        return commands
    }

    func performPalette(_ action: PaletteAction) {
        switch action {
        case let .task(id):
            guard let task = board.task(id: id), task.boardColumn != .done else { return }
            requestStartTask(taskID: id)
            BoardWindowController.shared.show(focus: self, tab: .board)
        case let .session(id):
            guard liveSessionIDs.contains(id) else { return }
            perform(.jump(sessionID: id))
        case let .review(id): showReview(sessionID: id)
        case let .capture(title):
            let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            createTask(title: text, column: .todo, projectPath: nil)
        case .startTimer:
            if pomodoro == nil, let task = currentTask { _ = startPomodoro(taskID: task.id, minutes: settings.pomodoroFocusMinutes) }
        case .pauseTimer: if pomodoro?.isPaused == false { pausePomodoro() }
        case .resumeTimer: if pomodoro?.isPaused == true { resumePomodoro() }
        case .board: BoardWindowController.shared.show(focus: self)
        }
    }
}

@MainActor
final class CommandPaletteController {
    static let shared = CommandPaletteController()
    private var panel: NSPanel?

    func show(focus: FocusCoordinator) {
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        let panel = panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 450),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = L10n.tr("palette.title")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: CommandPaletteView(focus: focus) { [weak panel] action in
            panel?.orderOut(nil)
            if let action { focus.performPalette(action) }
        })
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

struct CommandPaletteView: View {
    @Bindable var focus: FocusCoordinator
    var execute: (PaletteAction?) -> Void
    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var searching: Bool

    private var commands: [PaletteCommand] { focus.paletteCommands(query: query) }

    var body: some View {
        VStack(spacing: 0) {
            TextField(L10n.tr("palette.search"), text: $query)
                .textFieldStyle(.plain).font(.title3).padding(18)
                .focused($searching)
                .onSubmit { runSelected() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(commands) { command in
                            Button { execute(command.action) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: command.symbol).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(command.title).lineLimit(1)
                                        if !command.detail.isEmpty { Text(command.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                    if command.id == selectedID { Image(systemName: "return") }
                                }
                                .padding(10).contentShape(Rectangle())
                                .background(RoundedRectangle(cornerRadius: 7).fill(command.id == selectedID ? Color.accentColor.opacity(0.25) : .clear))
                            }
                            .buttonStyle(.plain).id(command.id)
                            .accessibilityAddTraits(command.id == selectedID ? .isSelected : [])
                        }
                    }.padding(8)
                }
                .onChange(of: selectedID) { _, id in if let id { reader.scrollTo(id) } }
            }
            Divider()
            Text(L10n.tr("palette.hint")).font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(width: 620, height: 450)
        .background(FocusStyle.windowBackground).preferredColorScheme(.dark)
        .onAppear { searching = true; selectedID = commands.first?.id }
        .onChange(of: commands.map(\.id)) { _, ids in
            if !ids.contains(selectedID ?? "") { selectedID = ids.first }
        }
        .onExitCommand { execute(nil) }
    }

    private func runSelected() {
        if let command = commands.first(where: { $0.id == selectedID }) ?? commands.first { execute(command.action) }
    }

    private func move(_ offset: Int) {
        guard !commands.isEmpty else { return }
        let index = commands.firstIndex { $0.id == selectedID } ?? 0
        selectedID = commands[min(commands.count - 1, max(0, index + offset))].id
    }
}
