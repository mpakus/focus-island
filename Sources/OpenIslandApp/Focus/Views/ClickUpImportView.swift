import AppKit
import FocusCore
import OpenIslandCore
import SwiftUI

struct ClickUpConnectionView: View {
    @Bindable var focus: FocusCoordinator
    private var clickUp: ClickUpCoordinator { focus.clickUp }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let connection = clickUp.connection {
                Text(connection.workspaceName).fontWeight(.medium)
                Text(connection.username).foregroundStyle(.secondary)
                Button(L10n.tr("clickup.sync_assigned")) { clickUp.syncAssignedTasks(links: Array(focus.board.clickUpLinks.values)) }
                    .disabled(clickUp.isBusy || focus.storeIsInMemoryFallback)
                Text(L10n.tr("clickup.sync_hint")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.tr("clickup.reconnect")) { clickUp.reconnect() }.disabled(clickUp.isBusy)
                Button(L10n.tr("clickup.disconnect")) { clickUp.disconnect() }
                Text(L10n.tr("clickup.disconnect_hint")).font(.caption).foregroundStyle(.secondary)
                Link(L10n.tr("clickup.access_settings"), destination: URL(string: "https://clickup.com/blog/how-to-use-clickup-mcp-server/")!).font(.caption)
            } else {
                Text(L10n.tr("clickup.setup_hint"))
                Button(L10n.tr("clickup.authorize")) { clickUp.reconnect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(clickUp.isBusy)
                if clickUp.isBusy { Button(L10n.tr("focus.cancel")) { clickUp.disconnect() } }
                else if clickUp.error != nil { Button(L10n.tr("clickup.disconnect")) { clickUp.disconnect() } }
            }
            ClickUpOperationStatus(clickUp: clickUp)
        }
    }
}

struct ClickUpOperationStatus: View {
    @Bindable var clickUp: ClickUpCoordinator

    var body: some View {
        if clickUp.isBusy {
            HStack { ProgressView().controlSize(.small); Text(L10n.tr(clickUp.isAuthorizing ? "clickup.authorizing" : "clickup.loading")) }
        }
        if let error = clickUp.error {
            Text(error).foregroundStyle(.orange).textSelection(.enabled)
        }
        if let date = clickUp.lastRefresh {
            Text(L10n.tr("clickup.refreshed", date.formatted(date: .abbreviated, time: .shortened)))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ClickUpImportView: View {
    @Bindable var focus: FocusCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var column = BoardColumn.backlog
    @State private var projectPath: String?
    @State private var editingTask: FocusTask?

    private var imported: [String: String] {
        Dictionary(uniqueKeysWithValues: focus.board.clickUpLinks.values
            .filter { $0.workspaceID == focus.clickUp.connection?.workspaceID }.map { ($0.remoteTaskID, $0.taskId) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("clickup.add_from_clickup")).font(.title2)
            if focus.clickUp.connection == nil {
                ClickUpConnectionView(focus: focus)
            } else {
                Text(L10n.tr("clickup.import_hint")).foregroundStyle(.secondary)
                TextField(L10n.tr("clickup.search"), text: $search)
                List {
                    ForEach(focus.clickUp.tasks.filter { search.isEmpty || "\($0.displayID) \($0.title)".localizedCaseInsensitiveContains(search) }) { issue in
                        HStack {
                            Toggle(isOn: Binding(get: { selected.contains(issue.id) }, set: { if $0 { selected.insert(issue.id) } else { selected.remove(issue.id) } })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(issue.displayID) · \(issue.title)")
                                    Text([issue.status, issue.listName].joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(imported[issue.id] != nil || focus.clickUp.isBusy)
                            if let taskID = imported[issue.id] {
                                Button(L10n.tr("clickup.on_board")) { editingTask = focus.board.task(id: taskID) }
                            }
                        }
                    }
                }
                .frame(minHeight: 200)
                if focus.clickUp.tasks.isEmpty && !focus.clickUp.isBusy && focus.clickUp.error == nil {
                    Text(L10n.tr("clickup.no_tasks")).foregroundStyle(.secondary)
                }
                HStack {
                    Picker(L10n.tr("focus.column"), selection: $column) {
                        Text(BoardColumn.backlog.title).tag(BoardColumn.backlog)
                        Text(BoardColumn.todo.title).tag(BoardColumn.todo)
                    }
                    Picker(L10n.tr("focus.project"), selection: $projectPath) {
                        Text(L10n.tr("focus.no_project_402")).tag(String?.none)
                        ForEach(Array(Set(focus.knownProjectPaths() + [projectPath].compactMap { $0 })).sorted(), id: \.self) { path in
                            Text(URL(fileURLWithPath: path).lastPathComponent).tag(String?.some(path))
                        }
                    }
                    Button(L10n.tr("clickup.choose_folder")) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK { projectPath = panel.url?.path }
                    }
                }
                ClickUpOperationStatus(clickUp: focus.clickUp)
                HStack {
                    Button(L10n.tr("clickup.reload_tasks")) { focus.clickUp.loadTasks() }.disabled(focus.clickUp.isBusy)
                    Spacer()
                    Button(L10n.tr("clickup.import_selected", "\(selected.count)")) {
                        focus.clickUp.importTasks(ids: selected, column: column, projectPath: projectPath)
                    }
                    .disabled(selected.isEmpty || focus.clickUp.isBusy || focus.storeIsInMemoryFallback)
                }
            }
            HStack { Spacer(); Button(L10n.tr("ui.done")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 740, height: focus.clickUp.connection == nil ? 340 : 540)
        .onAppear { if focus.clickUp.connection != nil { focus.clickUp.loadTasks() } }
        .onChange(of: imported) { _, links in selected.subtract(links.keys) }
        .onChange(of: focus.clickUp.tasks.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .onChange(of: focus.clickUp.connection) { _, _ in selected = [] }
        .sheet(item: $editingTask) { task in TaskDetailView(focus: focus, task: task) }
    }
}

struct ClickUpTaskBadge: View {
    let link: ClickUpTaskLink
    var body: some View {
        HStack(spacing: 6) {
            if let url = link.url { Link(link.displayID, destination: url) }
            Text(L10n.tr("clickup.status", link.status))
            if link.unavailable { Image(systemName: "exclamationmark.triangle").help(L10n.tr("clickup.unavailable")) }
        }
        .font(.caption)
        .accessibilityLabel("\(link.displayID), \(L10n.tr("clickup.status", link.status))\(link.unavailable ? ", " + L10n.tr("clickup.unavailable") : "")")
    }
}
