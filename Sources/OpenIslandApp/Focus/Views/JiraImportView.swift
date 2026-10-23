import AppKit
import FocusCore
import OpenIslandCore
import SwiftUI

struct JiraConnectionView: View {
    @Bindable var focus: FocusCoordinator
    private var jira: JiraCoordinator { focus.jira }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let connection = jira.connection {
                Text(connection.site).fontWeight(.medium)
                Text(connection.email).foregroundStyle(.secondary)
                Button(L10n.tr("jira.sync_assigned")) { jira.syncAssignedIssues(links: Array(focus.board.jiraLinks.values)) }
                    .disabled(jira.isBusy || focus.storeIsInMemoryFallback)
                Text(L10n.tr("jira.sync_hint")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.tr("jira.disconnect")) { jira.disconnect() }
                Text(L10n.tr("jira.disconnect_hint")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.tr("jira.setup_hint"))
                Link(L10n.tr("jira.install_cli"), destination: URL(string: "https://developer.atlassian.com/cloud/acli/guides/install-macos/")!)
                Button(L10n.tr("jira.authorize")) { jira.authorize() }.disabled(jira.isBusy)
                HStack {
                    Text("acli jira auth login --web").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button(L10n.tr("jira.copy_login")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("acli jira auth login --web", forType: .string)
                    }
                }
                Button(L10n.tr("jira.connect")) { jira.connect() }.disabled(jira.isBusy)
            }
            JiraOperationStatus(jira: jira)
        }
    }
}

struct JiraOperationStatus: View {
    @Bindable var jira: JiraCoordinator

    var body: some View {
        if jira.isBusy {
            HStack { ProgressView().controlSize(.small); Text(L10n.tr("jira.loading")) }
        }
        if let error = jira.error {
            Text(error).foregroundStyle(.orange).textSelection(.enabled)
        }
        if let date = jira.lastRefresh {
            Text(L10n.tr("jira.refreshed", date.formatted(date: .abbreviated, time: .shortened)))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct JiraImportView: View {
    @Bindable var focus: FocusCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var column = BoardColumn.backlog
    @State private var projectPath: String?
    @State private var editingTask: FocusTask?

    private var imported: [String: String] {
        Dictionary(uniqueKeysWithValues: focus.board.jiraLinks.values
            .filter { $0.cloudID == focus.jira.connection?.cloudID }.map { ($0.issueID, $0.taskId) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("jira.add_from_jira")).font(.title2)
            if focus.jira.connection == nil {
                JiraConnectionView(focus: focus)
            } else {
                Text(L10n.tr("jira.import_hint")).foregroundStyle(.secondary)
                TextField(L10n.tr("jira.search"), text: $search)
                List {
                    ForEach(focus.jira.issues.filter { search.isEmpty || "\($0.key) \($0.fields.summary)".localizedCaseInsensitiveContains(search) }) { issue in
                        HStack {
                            Toggle(isOn: Binding(get: { selected.contains(issue.id) }, set: { if $0 { selected.insert(issue.id) } else { selected.remove(issue.id) } })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(issue.key) · \(issue.fields.summary)")
                                    Text([issue.fields.issuetype?.name, issue.fields.status.name, issue.fields.project?.name, issue.fields.priority?.name].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(imported[issue.id] != nil || focus.jira.isBusy)
                            if let taskID = imported[issue.id] {
                                Button(L10n.tr("jira.on_board")) { editingTask = focus.board.task(id: taskID) }
                            }
                        }
                    }
                }
                .frame(minHeight: 200)
                if focus.jira.issues.isEmpty && !focus.jira.isBusy && focus.jira.error == nil {
                    Text(L10n.tr("jira.no_issues")).foregroundStyle(.secondary)
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
                    Button(L10n.tr("jira.choose_folder")) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK { projectPath = panel.url?.path }
                    }
                }
                JiraOperationStatus(jira: focus.jira)
                HStack {
                    Button(L10n.tr("jira.reload_issues")) { focus.jira.loadIssues() }.disabled(focus.jira.isBusy)
                    Spacer()
                    Button(L10n.tr("jira.import_selected", "\(selected.count)")) {
                        focus.jira.importIssues(ids: selected, column: column, projectPath: projectPath)
                    }
                    .disabled(selected.isEmpty || focus.jira.isBusy || focus.storeIsInMemoryFallback)
                }
            }
            HStack { Spacer(); Button(L10n.tr("ui.done")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 740, height: focus.jira.connection == nil ? 350 : 540)
        .onAppear { if focus.jira.connection != nil { focus.jira.loadIssues() } }
        .onChange(of: imported) { _, links in selected.subtract(links.keys) }
        .onChange(of: focus.jira.issues.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .onChange(of: focus.jira.connection) { _, _ in selected = [] }
        .sheet(item: $editingTask) { task in TaskDetailView(focus: focus, task: task) }
    }
}

struct JiraTaskBadge: View {
    let link: JiraTaskLink
    var body: some View {
        HStack(spacing: 6) {
            if let url = link.url { Link(link.key, destination: url) }
            Text(L10n.tr("jira.status", link.status))
            if link.unavailable { Image(systemName: "exclamationmark.triangle").help(L10n.tr("jira.unavailable")) }
        }
        .font(.caption)
        .accessibilityLabel("\(link.key), \(L10n.tr("jira.status", link.status))\(link.unavailable ? ", " + L10n.tr("jira.unavailable") : "")")
    }
}
