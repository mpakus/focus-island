import OpenIslandCore
import FocusCore
import SwiftUI

struct OverloadCard: View {
    @Bindable var focus: FocusCoordinator
    let newSessionID: String

    private var suggestion: OverloadSuggestion? {
        focus.overloadSuggestion
    }

    private var slots: [HubRow] {
        focus.hubRows.filter { !$0.group.isSettled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(liveCount: slots.count))
                    .font(FocusStyle.titleFont)
                    .lineLimit(2)
                Text(Self.subtitle(limit: focus.settings.maxParallelSessions))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForEach(slots) { row in
                    chip(row)
                }
                newSlot
            }
            if let suggestion, suggestion.attend != nil || suggestion.park != nil {
                FocusSectionCaption(L10n.tr("focus.first_consider"))
                if let attend = suggestion.attend {
                    attendOption(attend)
                }
                if let park = suggestion.park {
                    parkOption(park)
                }
            }
            HStack(spacing: 8) {
                Text(L10n.tr("focus.change_the_limit_in_settings"))
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(L10n.tr("focus.start_anyway")) { focus.perform(.dismiss) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 30))
            }
        }
    }

    private func chip(_ row: HubRow) -> some View {
        HStack(spacing: 5) {
            Image(systemName: Self.stateIcon(row.group))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.stateColor(row.group))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.projectName ?? row.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(Self.stateText(row.group))
                    .font(.system(size: 10))
                    .foregroundStyle(Self.stateColor(row.group))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .center)
        .background(RoundedRectangle(cornerRadius: FocusStyle.chipRadius).fill(Self.stateColor(row.group).opacity(0.16)))
        .accessibilityElement(children: .combine)
    }

    private var newSlot: some View {
        Text(L10n.tr("focus.new"))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FocusStyle.captionText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 34)
            .overlay(
                RoundedRectangle(cornerRadius: FocusStyle.chipRadius)
                    .strokeBorder(FocusStyle.captionText.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }

    private func attendOption(_ row: HubRow) -> some View {
        optionRow(
            title: L10n.tr("focus.reply_to_it_takes_a_minute", "\(row.projectName ?? row.title)"),
            detail: row.detail.isEmpty ? Self.waitingDetail(row: row, now: .now) : "\(row.detail) · \(Self.waitingDetail(row: row, now: .now))",
            buttonTitle: L10n.tr("focus.open_session"),
            primary: true
        ) { focus.perform(.jump(sessionID: row.id)) }
    }

    private func parkOption(_ row: HubRow) -> some View {
        optionRow(
            title: L10n.tr("focus.pause", "\(row.projectName ?? row.title)"),
            detail: L10n.tr("focus.hide_it_from_the_hub_remember_where_you_left_off_and_remind_you_when_a"),
            buttonTitle: L10n.tr("focus.pause_149"),
            primary: false
        ) { focus.perform(.park(sessionID: row.id)) }
    }

    private func optionRow(title: String, detail: String, buttonTitle: String, primary: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(detail)
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(buttonTitle, action: action)
                .buttonStyle(FocusButtonStyle(kind: primary ? .primary : .secondary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: FocusStyle.cardRadius).fill(FocusStyle.surface))
    }

    nonisolated static func title(liveCount: Int) -> String {
        L10n.tr("focus.session_in_this_task", "\(liveCount)")
    }

    nonisolated static func subtitle(limit: Int) -> String {
        L10n.tr("focus.you_usually_manage_comfortably_more_sessions_can_be_hard_to_track_clea", "\(limit)")
    }

    nonisolated static func waitingDetail(row: HubRow, now: Date = .now) -> String {
        L10n.tr("focus.waiting_min_152", "\(FocusText.minutes(now.timeIntervalSince(row.since)))")
    }

    nonisolated static func stateText(_ group: HubGroup) -> String {
        switch group {
        case .waiting: L10n.tr("focus.waiting")
        case .running: L10n.tr("focus.working_28")
        case .review: L10n.tr("focus.done_153")
        case .idle: L10n.tr("focus.your_turn_27")
        case .unbound: L10n.tr("focus.no_task_154")
        case .parked: L10n.tr("focus.paused_29")
        case .done: L10n.tr("focus.done_155")
        }
    }

    nonisolated static func stateIcon(_ group: HubGroup) -> String {
        switch group {
        case .waiting: "hourglass"
        case .running: "circle.fill"
        case .review: "checkmark.circle.fill"
        case .idle: "arrow.uturn.left.circle"
        case .unbound: "questionmark.circle"
        case .parked: "pause.circle"
        case .done: "checkmark.circle"
        }
    }

    static func stateColor(_ group: HubGroup) -> Color {
        switch group {
        case .waiting: FocusStyle.waitingText
        case .running: FocusStyle.working
        case .review: FocusStyle.done
        case .idle, .unbound, .parked, .done: FocusStyle.secondaryText
        }
    }
}
