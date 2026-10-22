import FocusCore
import OpenIslandCore
import SwiftUI

struct ReEntryCard: View {
    @Bindable var focus: FocusCoordinator
    let sessionID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            noteBox
            claudeBox
            waitingBox
            breadcrumbRow
            if !isWaiting {
                footer
            } else {
                HStack {
                    Spacer()
                    Button(L10n.tr("focus.later")) { focus.perform(.dismiss) }
                        .buttonStyle(FocusButtonStyle(kind: .quiet))
                }
            }
        }
    }

    private var session: AgentSession? {
        focus.session(sessionID)
    }

    private var task: FocusTask? {
        focus.board.task(id: focus.taskID(forSession: sessionID))
    }

    private var isWaiting: Bool {
        guard let phase = session?.phase else { return false }
        return phase == .waitingForApproval || phase == .waitingForAnswer
    }

    private var header: some View {
        let record = focus.record(sessionID)
        let project = focus.hubRows.first { $0.id == sessionID }?.projectName ?? record?.projectName
        let lastSeen = record?.lastSeenAt ?? record?.lastActivityAt
        return HStack(alignment: .center, spacing: 10) {
            StatusDot(color: session.map { FocusStyle.phaseColor($0.phase) } ?? FocusStyle.captionText)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("focus.returning_to_your_task"))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                Text(task?.title ?? focus.sessionTitle(sessionID))
                    .font(FocusStyle.titleFont)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.originLine(project: project, minutes: lastSeen.map { FocusText.minutes(context.date.timeIntervalSince($0)) }))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 180, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var noteBox: some View {
        if let note = task?.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            FocusBox(spacing: 6) {
                FocusSectionCaption(L10n.tr("focus.where_you_left_off"))
                Text("«\(note)»").font(.system(size: 13)).lineLimit(6)
            }
        }
    }

    @ViewBuilder
    private var claudeBox: some View {
        if let message = focus.record(sessionID)?.lastAssistantMessage.map({ FocusText.truncated($0, limit: FocusText.cardMessageLimit) }), !message.isEmpty {
            FocusBox(spacing: 6) {
                FocusSectionCaption(L10n.tr("focus.what_the_agent_did"))
                Text(message).font(.system(size: 13)).lineLimit(8)
            }
        }
    }

    @ViewBuilder
    private var waitingBox: some View {
        if isWaiting {
            FocusBox(fill: FocusStyle.waiting.opacity(0.12), border: FocusStyle.waiting.opacity(0.35), spacing: 6) {
                FocusSectionCaption(L10n.tr("focus.waiting_for_you_191"), color: FocusStyle.waitingText)
                HStack(spacing: 10) {
                    Text(Self.waitingDetail(session))
                        .font(FocusStyle.monoFont)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.tr("focus.open_terminal")) { focus.perform(.confirmJump(sessionID: sessionID)) }
                        .buttonStyle(FocusButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder
    private var breadcrumbRow: some View {
        if let row = focusRow, let text = Self.breadcrumb(
            taskTitle: focus.currentTask?.title,
            progress: row.progress,
            hasQueuedPrompt: focus.queuedPrompt(sessionID: row.id) != nil,
            isRunning: row.group == .running
        ) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FocusStyle.working)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(FocusStyle.primaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: FocusStyle.rowRadius)
                    .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
    }

    private var focusRow: HubRow? {
        guard let currentID = focus.currentTask?.id else { return nil }
        return focus.hubRows.first { $0.taskID == currentID && $0.group == .running && $0.id != sessionID }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(L10n.tr("focus.open_session")) { focus.perform(.confirmJump(sessionID: sessionID)) }
                .buttonStyle(FocusButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            Spacer(minLength: 0)
            Button(L10n.tr("focus.later")) { focus.perform(.dismiss) }
                .buttonStyle(FocusButtonStyle(kind: .quiet))
        }
    }

    nonisolated static func breadcrumb(taskTitle: String?, progress: PlanProgress?, hasQueuedPrompt: Bool, isRunning: Bool) -> String? {
        guard isRunning, let taskTitle, !taskTitle.isEmpty else { return nil }
        var parts = [L10n.tr("focus.continues", "\(taskTitle)")]
        if let progress {
            parts.append(L10n.tr("focus.step_of_194", "\(min(progress.total, progress.completed + 1))", "\(progress.total)"))
        }
        if hasQueuedPrompt { parts.append(L10n.tr("focus.prompt_queued")) }
        parts.append(L10n.tr("focus.i_ll_notify_you_when_it_s_done"))
        return parts.joined(separator: " · ")
    }

    nonisolated static func agoText(minutes: Int) -> String {
        if minutes < 1 { return L10n.tr("focus.just_now") }
        if minutes < 60 { return L10n.tr("focus.min_ago", "\(minutes)") }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? L10n.tr("focus.h_ago", "\(hours)") : L10n.tr("focus.h_min_ago", "\(hours)", "\(rest)")
    }

    nonisolated static func originLine(project: String?, minutes: Int?) -> String {
        var parts: [String] = []
        if let project, !project.isEmpty { parts.append(project) }
        if let minutes { parts.append(L10n.tr("focus.last_seen", "\(agoText(minutes: minutes))")) }
        return parts.joined(separator: " · ")
    }

    nonisolated static func waitingDetail(_ session: AgentSession?) -> String {
        guard let session else { return "" }
        if session.phase == .waitingForApproval {
            let request = session.permissionRequest
            return [request?.summary, request?.toolName, request?.title].compactMap { $0 }.first { !$0.isEmpty } ?? L10n.tr("focus.permission_11")
        }
        return session.questionPrompt?.title ?? L10n.tr("focus.question")
    }
}
