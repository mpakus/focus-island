import AppKit
import FocusCore
import OpenIslandCore
import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @Bindable var focus: FocusCoordinator
    private var backups: BackupCoordinator { focus.backups }

    var body: some View {
        Section(L10n.tr("backup.title")) {
            Toggle(L10n.tr("backup.daily"), isOn: $focus.settings.dailyBackupsEnabled)
                .disabled(!backups.available)
            Text(L10n.tr("backup.retention")).font(.caption).foregroundStyle(.secondary)
            if let date = backups.lastBackup {
                HStack { Text(L10n.tr("backup.last")); Text(date, format: .dateTime.year().month().day().hour().minute()) }
                    .font(.caption)
            }
            HStack {
                Button(L10n.tr("backup.create")) { backups.create() }
                Button(L10n.tr("backup.export"), action: export)
                Button(L10n.tr("backup.restore"), action: chooseRestore)
                Button(L10n.tr("backup.folder")) {
                    if let directory = backups.directory { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path) }
                }
            }
            .disabled(!backups.available || backups.isBusy || backups.restoreReady)
            if backups.isBusy { ProgressView().controlSize(.small) }
            if let error = backups.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if !backups.available { Text(L10n.tr("backup.unavailable")).font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(item: Binding(get: { backups.preview }, set: { if $0 == nil { backups.discardPreview() } })) { preview in
            BackupRestorePreview(preview: preview, currentTasks: focus.board.tasks.count,
                isBusy: backups.isBusy, error: backups.error,
                cancel: { backups.discardPreview() }, restore: { backups.stageRestore() })
                .interactiveDismissDisabled(backups.isBusy)
        }
        .onChange(of: backups.restoreReady) { _, ready in if ready { NSApp.terminate(nil) } }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Focus-Island-\(Int(Date.now.timeIntervalSince1970)).sqlite"
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.canCreateDirectories = true
        panel.begin { result in
            if result == .OK, let url = panel.url { backups.export(to: url) }
        }
    }

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.begin { result in
            if result == .OK, let url = panel.url { backups.inspect(url) }
        }
    }
}

struct BackupRestorePreview: View {
    let preview: BackupPreview
    let currentTasks: Int
    let isBusy: Bool
    let error: String?
    var cancel: () -> Void
    var restore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("backup.preview")).font(.title2)
            Text(preview.sourceName).lineLimit(2).textSelection(.enabled)
            Text(L10n.tr("backup.counts", "\(preview.tasks)", "\(preview.sessions)", "\(preview.notes)", "\(preview.criteria)", "\(preview.pomodoros)"))
            Text(L10n.tr("backup.replace_notice", "\(currentTasks)"))
            Text(L10n.tr("backup.credentials_notice")).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(L10n.tr("focus.cancel_207"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L10n.tr("backup.restore_quit"), action: restore)
            }.disabled(isBusy)
        }.padding(24).frame(width: 500)
    }
}
