import AppKit
import FocusCore
import OpenIslandCore
import SwiftUI

struct OnboardingCard: View {
    enum Stage: Equatable {
        case connect
        case firstTask
        case started
    }

    @Bindable var focus: FocusCoordinator
    let agent: AgentTool
    let configureAgents: () -> Void
    @State private var taskText = ""
    @State private var criterionText = ""
    @State private var selected: Set<String> = []
    @State private var anchorID: String?

    init(focus: FocusCoordinator, agent: AgentTool = .claudeCode, configureAgents: @escaping () -> Void) {
        self.focus = focus
        self.agent = agent
        self.configureAgents = configureAgents
    }

    private var stage: Stage {
        Self.stage(hooksInstalled: focus.hooksInstalled, taskAdded: focus.onboardingTaskAdded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch stage {
            case .connect: connectStage
            case .firstTask: firstTaskStage
            case .started: startedStage
            }
        }
    }

    private var connectStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepDots(current: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Focus Island").font(FocusStyle.titleFont)
                Text(L10n.tr("focus.keep_track_of_claude_code_and_codex_sessions_and_tasks_connect_an_agen"))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("focus.claude_code_and_codex")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(L10n.tr("focus.choose_agents_in_setup_install_check_or_remove_their_hooks_there"))
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.tr("focus.connect"), action: configureAgents)
                    .buttonStyle(FocusButtonStyle(kind: .primary))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: FocusStyle.cardRadius).fill(FocusStyle.surface))
            footer(caption: L10n.tr("focus.everything_stays_on_this_mac"), buttonTitle: L10n.tr("focus.later"))
        }
    }

    private var firstTaskStage: some View {
        let candidates = focus.firstTaskCandidates()
        let typing = Self.canAddTask(text: taskText)
        return VStack(alignment: .leading, spacing: 12) {
            StepDots(current: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("focus.what_are_you_working_on")).font(FocusStyle.titleFont)
                Text(L10n.tr("focus.one_task_in_focus_island_tracks_its_sessions_and_time_so_you_can_focus"))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(2)
            }
            TextField(L10n.tr("focus.for_example_switch_auth_to_tokens"), text: $taskText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(FocusStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(typing ? FocusStyle.link : FocusStyle.hairline, lineWidth: 1))
                .onSubmit { start(candidates: candidates) }
                .accessibilityLabel(L10n.tr("focus.task_name"))
                .onChange(of: typing) { _, isTyping in
                    if isTyping, anchorID == nil {
                        selected = OnboardingCard.preselection(candidates: candidates, anchorID: nil)
                    }
                }
            if typing {
                if !candidates.isEmpty {
                    FocusSectionCaption(L10n.tr("focus.sessions_for_this_task"))
                    ForEach(candidates) { candidate in
                        candidateToggle(candidate)
                    }
                }
                HStack(spacing: 8) {
                    Text(L10n.tr("focus.done_when"))
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .fixedSize()
                    TextField(L10n.tr("focus.optional"), text: $criterionText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { start(candidates: candidates) }
                        .accessibilityLabel(L10n.tr("focus.done_when"))
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(FocusStyle.surface))
                HStack(spacing: 8) {
                    Button(L10n.tr("focus.skip")) { focus.dismissOnboarding() }
                        .buttonStyle(FocusButtonStyle(kind: .quiet, height: 28, horizontalPadding: 6))
                    Spacer(minLength: 0)
                    Button(L10n.tr("focus.start_task")) { start(candidates: candidates) }
                        .buttonStyle(FocusButtonStyle(kind: .primary, height: 34, horizontalPadding: 18))
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                if !candidates.isEmpty {
                    FocusSectionCaption(L10n.tr("focus.or_continue_work_already_in_progress"))
                    ForEach(candidates.prefix(FocusCoordinator.firstTaskSuggestionLimit)) { candidate in
                        suggestionRow(candidate, candidates: candidates)
                    }
                }
                footer(caption: L10n.tr("focus.macos_will_ask_for_automation_permission_the_first_time_you_open_a_ses"), buttonTitle: L10n.tr("focus.skip"))
            }
        }
    }

    private var startedStage: some View {
        let task = focus.currentTask
        let rows = focus.focusTaskSessions
        let minutes = PomodoroFormat.clampFocus(focus.settings.pomodoroFocusMinutes)
        return VStack(alignment: .leading, spacing: 12) {
            StepDots(current: 3)
            if !rows.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(FocusStyle.working)
                        .accessibilityHidden(true)
                    Text(Self.startedToast(sessionCount: rows.count))
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.tagText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(FocusStyle.working.opacity(0.12)))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("focus.in_focus_126"))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                Text(task?.title ?? L10n.tr("focus.task_127"))
                    .font(FocusStyle.titleFont)
                    .lineLimit(2)
            }
            if rows.isEmpty {
                waitingForSession(projectPath: task?.projectPath)
            } else {
                ForEach(rows) { row in
                    startedRow(row)
                }
            }
            VStack(spacing: 6) {
                Button {
                    if let task {
                        focus.startPomodoro(taskID: task.id, minutes: minutes)
                    }
                    focus.dismissOnboarding()
                } label: {
                    Text(L10n.tr("focus.focus_for_minutes", "\(minutes)"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FocusButtonStyle(kind: .primary, height: 38))
                .font(.system(size: 15, weight: .semibold))
                .keyboardShortcut(.defaultAction)
                Text(rows.isEmpty ? L10n.tr("focus.you_can_start_now_sessions_will_appear_as_you_work") : L10n.tr("focus.during_focus_the_agent_only_interrupts_when_needed_then_take_a_minute_", "\(focus.settings.pomodoroBreakMinutes)"))
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(2)
            }
            footer(caption: L10n.tr("focus.all_tasks_on_the_board", "\(focus.settings.boardHotKey.title)"), buttonTitle: L10n.tr("focus.without_a_timer"))
        }
    }

    private func suggestionRow(_ candidate: FirstTaskCandidate, candidates: [FirstTaskCandidate]) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FocusStyle.primaryText)
                    .lineLimit(1)
                Text(Self.candidateDetail(cwd: candidate.cwd, appName: candidate.appName))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let status = SessionStatusKind.of(candidate.group) {
                SessionStatusBadge(kind: status)
            }
            Button(L10n.tr("focus.choose")) {
                anchorID = candidate.id
                selected = Self.preselection(candidates: candidates, anchorID: candidate.id)
                taskText = candidate.title
            }
            .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).fill(FocusStyle.surface))
    }

    private func candidateToggle(_ candidate: FirstTaskCandidate) -> some View {
        let isOn = selected.contains(candidate.id)
        return Button {
            if isOn { selected.remove(candidate.id) } else { selected.insert(candidate.id) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? FocusStyle.accent : Color.clear)
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isOn ? FocusStyle.accent : Color.white.opacity(0.3), lineWidth: 1.5)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isOn ? FocusStyle.primaryText : FocusStyle.secondaryText)
                        .lineLimit(1)
                    Text(Self.candidateDetail(cwd: candidate.cwd, appName: candidate.appName))
                        .font(.system(size: 11))
                        .foregroundStyle(FocusStyle.captionText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let status = SessionStatusKind.of(candidate.group) {
                    SessionStatusBadge(kind: status)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.title)
        .accessibilityValue(isOn ? L10n.tr("focus.in_task") : L10n.tr("focus.not_in_task"))
    }

    private func startedRow(_ row: HubRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(focus.sessionLabel(row.id) ?? focus.sessionTitle(row.id))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(row.detail)
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let status = SessionStatusKind.of(row.group) {
                SessionStatusBadge(kind: status)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
    }

    private func waitingForSession(projectPath: String?) -> some View {
        let command = Self.launchCommand(projectPath: projectPath, agent: agent)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(FocusStyle.link)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(FocusStyle.link.opacity(0.25), lineWidth: 5))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("focus.waiting_for_the_first_session", "\(agent.displayName)"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(agent == .codex
                         ? L10n.tr("focus.run_codex_in_your_terminal_review_trust_in_hooks_and_send_a_prompt_the")
                         : L10n.tr("focus.run_claude_in_your_terminal_ide_or_claude_app_the_session_will_join_th"))
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(FocusStyle.link.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            HStack(spacing: 10) {
                Text("$ " + command)
                    .font(FocusStyle.monoFont)
                    .foregroundStyle(FocusStyle.tagText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.tr("focus.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(FocusButtonStyle(kind: .secondary, height: 24, horizontalPadding: 10))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.35)))
        }
    }

    private func footer(caption: String, buttonTitle: String) -> some View {
        HStack(spacing: 8) {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(FocusStyle.captionText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(buttonTitle) { focus.dismissOnboarding() }
                .buttonStyle(FocusButtonStyle(kind: .quiet, height: 26))
        }
    }

    private func start(candidates: [FirstTaskCandidate]) {
        guard Self.canAddTask(text: taskText) else { return }
        let ids = candidates.map(\.id).filter { selected.contains($0) }
        focus.startFirstTask(title: taskText, sessionIDs: ids, criterion: criterionText)
        taskText = ""
        criterionText = ""
    }

    nonisolated static func stage(hooksInstalled: Bool?, taskAdded: Bool) -> Stage {
        if taskAdded { return .started }
        return hooksInstalled == true ? .firstTask : .connect
    }

    nonisolated static func canAddTask(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func preselection(candidates: [FirstTaskCandidate], anchorID: String?) -> Set<String> {
        FocusCoordinator.firstTaskPreselection(candidates: candidates, anchorID: anchorID)
    }

    nonisolated static func startedToast(sessionCount: Int) -> String {
        L10n.tr("focus.task_in_progress_included", "\(FocusCoordinator.sessionCountText(sessionCount))")
    }

    nonisolated static func candidateDetail(cwd: String?, appName: String?) -> String {
        var parts: [String] = []
        if let cwd, !cwd.isEmpty {
            parts.append(Self.shortPath(cwd))
        }
        if let appName, !appName.isEmpty {
            parts.append(appName)
        }
        return parts.isEmpty ? L10n.tr("focus.agent_session_140") : parts.joined(separator: " · ")
    }

    nonisolated static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    nonisolated static func launchCommand(projectPath: String?, agent: AgentTool = .claudeCode) -> String {
        let executable = agent == .codex ? "codex" : "claude"
        guard let projectPath, !projectPath.isEmpty else { return executable }
        let target = projectPath.contains(" ") ? "\"\(projectPath)\"" : shortPath(projectPath)
        return "cd \(target) && \(executable)"
    }
}

private struct StepDots: View {
    let current: Int
    let total = 3

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { index in
                Capsule()
                    .fill(index < current ? FocusStyle.working : index == current ? FocusStyle.link : Color.white.opacity(0.18))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
            Text(L10n.tr("focus.step_of", "\(current)", "\(total)"))
                .font(.system(size: 11))
                .foregroundStyle(FocusStyle.captionText)
                .padding(.leading, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("focus.step_of", "\(current)", "\(total)"))
    }
}
