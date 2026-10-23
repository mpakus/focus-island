import OpenIslandCore
import FocusCore
import SwiftUI

struct FocusSettingsPane: View {
    @Bindable var focus: FocusCoordinator
    var hooksInstalled = false
    var configureAgents: () -> Void = {}
    @State private var appsText = ""
    @State private var domainsText = ""

    nonisolated static let maxParallelRange = FocusSettings.maxParallelRange
    nonisolated static let stalledReminderRange = FocusSettings.stalledReminderRange

    nonisolated static func hooksTitle(installed: Bool) -> String {
        installed ? L10n.tr("focus.agent_hooks_configured") : L10n.tr("focus.connect_claude_code_or_codex")
    }

    nonisolated static func hooksPathText(path: String, home: String) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: hooksInstalled ? "checkmark" : "exclamationmark.triangle")
                        .foregroundStyle(hooksInstalled ? FocusStyle.working : FocusStyle.waiting)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.hooksTitle(installed: hooksInstalled)).fontWeight(.semibold)
                        Text(L10n.tr("focus.claude_code_and_codex_installation_and_checks_in_setup"))
                            .font(FocusStyle.secondaryFont)
                            .foregroundStyle(FocusStyle.secondaryText)
                    }
                    Spacer()
                    Button(L10n.tr("focus.configure_agents"), action: configureAgents)
                }
            }
            if let backup = focus.storeRecoveredBackupURL {
                Text(L10n.tr("focus.the_focus_database_was_damaged_and_recreated_backup", "\(backup.path)"))
                    .foregroundStyle(.orange)
            }
            if focus.storeIsInMemoryFallback {
                Text(L10n.tr("focus.could_not_open_the_focus_database_changes_will_be_lost_when_you_quit"))
                    .foregroundStyle(.orange)
            }
            Section(L10n.tr("focus.what_s_next")) {
                Toggle(L10n.tr("focus.show_hints_while_the_agent_works"), isOn: $focus.settings.nextActionEnabled)
                Stepper(L10n.tr("focus.after_s", "\(Int(focus.settings.nextActionDelay))"), value: $focus.settings.nextActionDelay, in: 5...120, step: 5)
            }
            Section(L10n.tr("focus.focus_timer")) {
                Stepper(L10n.tr("focus.focus_min", "\(focus.settings.pomodoroFocusMinutes)"), value: $focus.settings.pomodoroFocusMinutes, in: FocusSettings.pomodoroFocusRange, step: 5)
                Stepper(L10n.tr("focus.min_break", "\(focus.settings.pomodoroBreakMinutes)"), value: $focus.settings.pomodoroBreakMinutes, in: FocusSettings.pomodoroBreakRange)
                Stepper(L10n.tr("focus.pomodoros_per_cycle", "\(focus.settings.pomodoroCycle)"), value: $focus.settings.pomodoroCycle, in: FocusSettings.pomodoroCycleRange)
                Toggle(L10n.tr("focus.start_breaks_automatically"), isOn: $focus.settings.autoBreakEnabled)
                Toggle(L10n.tr("focus.play_sound_when_a_break_starts"), isOn: $focus.settings.breakSoundEnabled)
                    .disabled(!focus.settings.autoBreakEnabled)
                Text(L10n.tr("focus.a_5_second_countdown_follows_focus_without_auto_break_the_card_waits_f"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("focus.new_values_apply_to_the_next_pomodoro"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.tr("focus.sessions_299")) {
                Stepper(L10n.tr("focus.comfortable_parallel_sessions", "\(focus.settings.maxParallelSessions)"), value: $focus.settings.maxParallelSessions, in: Self.maxParallelRange)
                Stepper(L10n.tr("focus.remind_me_about_waiting_sessions_after_min", "\(focus.settings.stalledReminderMinutes)"), value: $focus.settings.stalledReminderMinutes, in: Self.stalledReminderRange)
                Toggle(L10n.tr("focus.show_the_morning_start_the_day_screen"), isOn: $focus.settings.dayStartEnabled)
            }
            Section(L10n.tr("focus.distractions")) {
                Toggle(L10n.tr("focus.detect_distractions"), isOn: $focus.settings.distractionEnabled)
                Stepper(L10n.tr("focus.threshold_s", "\(Int(focus.settings.distractionThreshold))"), value: $focus.settings.distractionThreshold, in: 5...300, step: 5)
                Toggle(L10n.tr("focus.play_reminder_sound"), isOn: $focus.settings.nudgeSoundEnabled)
                Text(L10n.tr("focus.apps_bundle_id_one_per_line")).font(.caption)
                TextEditor(text: $appsText).frame(minHeight: 60)
                Text(L10n.tr("focus.domains_one_per_line")).font(.caption)
                TextEditor(text: $domainsText).frame(minHeight: 100)
                HStack {
                    Button(L10n.tr("focus.save_blocklist")) {
                        focus.settings.stopList = StopList(appBundleIDs: appLines(appsText), domains: lines(domainsText))
                    }
                    Button(L10n.tr("focus.defaults")) {
                        focus.settings.stopList = .default
                        loadStopList()
                    }
                }
                Text(L10n.tr("focus.reading_safari_chrome_or_arc_tab_addresses_requires_automation_permiss"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.tr("focus.terminal_and_board")) {
                Picker(L10n.tr("focus.terminal_for_resume"), selection: $focus.settings.resumeTerminal) {
                    ForEach(ResumeTerminal.allCases) { Text($0.title).tag($0) }
                }
                Picker(L10n.tr("focus.board_shortcut"), selection: $focus.settings.boardHotKey) {
                    ForEach(BoardHotKey.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadStopList)
    }

    private func loadStopList() {
        appsText = focus.settings.stopList.appBundleIDs.joined(separator: "\n")
        domainsText = focus.settings.stopList.domains.joined(separator: "\n")
    }

    private func appLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { line -> String in
                var value = line.trimmingCharacters(in: .whitespaces).lowercased()
                if value.hasPrefix("www.") { value.removeFirst(4) }
                while value.hasSuffix(".") { value.removeLast() }
                return value
            }
            .filter { !$0.isEmpty }
    }
}
