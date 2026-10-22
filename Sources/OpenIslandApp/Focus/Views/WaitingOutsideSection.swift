import OpenIslandCore
import FocusCore
import SwiftUI

struct WaitingOutsideSection: View {
    @Bindable var focus: FocusCoordinator
    let task: FocusTask

    var body: some View {
        let rows = focus.waitingOutside
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .stroke(FocusStyle.waiting, lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                FocusSectionCaption(Self.caption(rows.count), color: FocusStyle.waitingText)
                Spacer(minLength: 0)
                Button(L10n.tr("focus.collapse")) { focus.toggleWaitingOutside() }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 24, horizontalPadding: 6))
            }
            Text(Self.explainer(taskTitle: task.title))
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .lineLimit(2)
            ForEach(rows) { row in
                rowView(row)
            }
            HStack(spacing: 8) {
                Text(L10n.tr("focus.opening_a_session_does_not_change_the_focused_task"))
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.tr("focus.snooze_all")) { focus.deferWaitingOutside(sessionIDs: rows.map(\.id)) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 26, horizontalPadding: 6))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(FocusStyle.waiting.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(FocusStyle.waiting.opacity(0.25), lineWidth: 1))
        )
        .accessibilityElement(children: .contain)
    }

    private func rowView(_ row: HubRow) -> some View {
        HStack(spacing: 12) {
            Text(Self.ageLabel(seconds: Date.now.timeIntervalSince(row.since)))
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(FocusStyle.waitingText)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FocusStyle.primaryText)
                        .lineLimit(1)
                    if let project = row.projectName {
                        ProjectTag(project)
                    }
                }
                Text(Self.ownerText(taskTitle: focus.board.task(id: row.taskID)?.title))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.tr("focus.open_session")) { focus.requestJump(sessionID: row.id) }
                .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
            Menu {
                Button(Self.addTitle(taskTitle: task.title)) { focus.bind(sessionID: row.id, taskID: task.id) }
                Button(L10n.tr("focus.snooze_pause")) { focus.deferWaitingOutside(sessionIDs: [row.id]) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(FocusStyle.secondaryText)
            .frame(width: 28, height: 28)
            .accessibilityLabel(L10n.tr("focus.more_actions"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).fill(Color.white.opacity(0.05)))
    }

    nonisolated static func caption(_ count: Int) -> String {
        L10n.tr("focus.waiting_outside_task", "\(count)")
    }

    nonisolated static func buttonTitle(_ count: Int, expanded: Bool) -> String {
        L10n.tr("focus.waiting_outside_task_438", "\(count)") + (expanded ? "▾" : "▸")
    }

    nonisolated static func explainer(taskTitle: String) -> String {
        L10n.tr("focus.the_agents_in_these_sessions_have_finished_and_are_waiting_for_you_the", "\(taskTitle)")
    }

    nonisolated static func ownerText(taskTitle: String?) -> String {
        guard let taskTitle else { return L10n.tr("focus.no_task_154") }
        return L10n.tr("focus.for_task", "\(taskTitle)")
    }

    nonisolated static func addTitle(taskTitle: String) -> String {
        L10n.tr("focus.add_to", "\(taskTitle)")
    }

    nonisolated static func ageLabel(seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes < 60 ? L10n.tr("focus.min_55", "\(minutes)") : L10n.tr("focus.h", "\(minutes / 60)")
    }
}
