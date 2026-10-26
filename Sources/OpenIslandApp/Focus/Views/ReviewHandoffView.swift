import AppKit
import FocusCore
import OpenIslandCore
import SwiftUI

@MainActor
final class ReviewWindowController {
    static let shared = ReviewWindowController()
    private var window: NSWindow?

    func show(focus: FocusCoordinator, sessionID: String) {
        let window = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = L10n.tr("review.title")
        window.contentView = NSHostingView(rootView: ReviewHandoffView(focus: focus, sessionID: sessionID).id(sessionID))
        if self.window == nil { window.center(); window.setFrameAutosaveName("FocusReviewWindow") }
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

extension FocusCoordinator {
    func showReview(sessionID: String) {
        ReviewWindowController.shared.show(focus: self, sessionID: sessionID)
    }
}

struct ReviewHandoffView: View {
    @Bindable var focus: FocusCoordinator
    let sessionID: String
    @State var snapshot: GitReviewSnapshot?
    @State private var selection: String?
    @State private var patch = ""
    @State private var error: String?
    @State private var diffError: String?
    @State private var refreshing = false
    @State private var revision = 0
    @State private var request = 0
    @State private var summaryExpanded = true
    @State private var criteriaExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(focus.sessionTitle(sessionID)).font(.title2).lineLimit(1)
                Spacer()
                Button(L10n.tr("review.refresh")) { request += 1 }.disabled(refreshing)
                Button(L10n.tr("focus.open_session")) { focus.perform(.jump(sessionID: sessionID)) }
                    .disabled(!focus.liveSessionIDs.contains(sessionID))
            }
            if let summary = focus.record(sessionID)?.lastAssistantMessage ?? focus.session(sessionID)?.summary, !summary.isEmpty {
                DisclosureGroup(L10n.tr("focus.what_was_done"), isExpanded: $summaryExpanded) {
                    ScrollView { Text(summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 130)
                }
            }
            if let taskID = focus.taskID(forSession: sessionID), !focus.criteria(taskID: taskID).isEmpty {
                DisclosureGroup(L10n.tr("focus.your_completion_criteria"), isExpanded: $criteriaExpanded) {
                    ScrollView { CriteriaChecklist(focus: focus, taskID: taskID) }.frame(maxHeight: 120)
                }
            }
            Text(L10n.tr("review.scope")).font(.caption).foregroundStyle(.secondary)
            if let snapshot {
                HStack {
                    Label(snapshot.branch, systemImage: "arrow.triangle.branch")
                    Text(snapshot.root).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button(L10n.tr("review.reveal")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: snapshot.root) }
                }.font(.caption)
                if snapshot.omittedFiles > 0 {
                    Text(L10n.tr("review.omitted", "\(snapshot.omittedFiles)")).foregroundStyle(.orange)
                }
                if snapshot.files.isEmpty {
                    Text(L10n.tr("review.clean")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HSplitView {
                        List(snapshot.files, selection: $selection) { file in
                            HStack {
                                Text(file.status).font(.system(.caption, design: .monospaced)).frame(width: 20)
                                Text(file.path).lineLimit(2)
                            }.tag(file.path)
                        }.frame(minWidth: 190, idealWidth: 240, maxWidth: 370)
                        ScrollView([.horizontal, .vertical]) {
                            Text(diffError ?? patch)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(diffError == nil ? Color.primary : .orange)
                                .textSelection(.enabled).padding(12)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if refreshing {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            Spacer(minLength: 0)
        }
        .padding(18).frame(minWidth: 760, minHeight: 520)
        .background(FocusStyle.windowBackground).preferredColorScheme(.dark)
        .task(id: request) { await refresh() }
        .task(id: "\(revision):\(selection ?? "")") { await loadDiff() }
    }

    private func refresh() async {
        refreshing = true; error = nil
        defer { refreshing = false }
        guard let cwd = focus.sessionCWD(sessionID) else { error = L10n.tr("review.unavailable"); return }
        do {
            let result = try await GitReviewProvider().snapshot(cwd: cwd)
            try Task.checkCancellation()
            snapshot = result
            if !result.files.contains(where: { $0.path == selection }) { selection = result.files.first?.path }
            revision += 1
        } catch is CancellationError { } catch { self.error = error.localizedDescription; snapshot = nil }
    }

    private func loadDiff() async {
        patch = ""; diffError = nil
        guard let snapshot, let file = snapshot.files.first(where: { $0.path == selection }) else { return }
        do {
            let text = try await GitReviewProvider().diff(file: file, snapshot: snapshot)
            try Task.checkCancellation()
            patch = text
        } catch is CancellationError { } catch { diffError = error.localizedDescription }
    }
}
