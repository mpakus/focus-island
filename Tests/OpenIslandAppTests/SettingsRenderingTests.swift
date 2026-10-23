import AppKit
import FocusCore
import MarkdownUI
@testable import OpenIslandCore
import SwiftUI
import Testing
import Vision
@testable import OpenIslandApp

@MainActor
@Suite(.serialized)
struct SettingsRenderingTests {
    // Run separately per language so changing the shared UI preference cannot race other suites.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOCUS_ISLAND_PREVIEW_LANGUAGE"] != nil))
    func localizedSettingsPreview() async throws {
        let code = try #require(ProcessInfo.processInfo.environment["FOCUS_ISLAND_PREVIEW_LANGUAGE"])
        let language = try #require(LanguageManager.AppLanguage(rawValue: code))
        let previous = LanguageManager.shared.language
        defer { LanguageManager.shared.language = previous }
        LanguageManager.shared.language = language
        let model = AppModel(focusStore: try FocusStore.inMemory(), claudeRegistry: .temporaryForTesting(), runBackfill: false)
        model.hooks.hooksBinaryURL = URL(fileURLWithPath: "/fixture/OpenIslandHooks")
        let general = try await render(GeneralSettingsPane(model: model), name: "general-\(code)", model: model)
        #expect(general.contains("English"))
        #expect(general.contains("Español"))
        let setup = try await render(SetupSettingsPane(model: model), name: "setup-\(code)", model: model)
        #expect(setup.contains("Codex"))
        #expect(setup.contains("/hooks"))
        let focus = try await render(FocusSettingsPane(focus: model.focus), name: "focus-\(code)", model: model)
        let expected = language == .en ? "Focus timer" : language == .es ? "Temporizador" : "Фокус"
        #expect(focus.contains(expected))
        let state = BoardWindowState()
        _ = try await render(BoardRootView(focus: model.focus, state: state), name: "board-\(code)", model: model)
        let today = DaySummaryFormatter.title(Date(timeIntervalSince1970: 1_791_547_200))
        #expect(!today.isEmpty)
    }

    @Test(arguments: [false, true])
    func setupExposesBothAgentsAndCodexTrustInstructions(installed: Bool) async throws {
        let model = AppModel(focusStore: try FocusStore.inMemory(), claudeRegistry: .temporaryForTesting(), runBackfill: false)
        model.hooks.hooksBinaryURL = URL(fileURLWithPath: "/fixture/OpenIslandHooks")
        if installed {
            model.hooks.codexHookStatus = CodexHookInstallationStatus(
                configURL: URL(fileURLWithPath: "/fixture/codex/hooks.json"),
                configured: true, binaryAvailable: true, inlineConflict: false
            )
        }
        let text = try await render(SetupSettingsPane(model: model), name: installed ? "setup-configured" : "setup", model: model)
        #expect(text.contains("Claude Code"))
        #expect(text.contains("Codex"))
        #expect(text.contains("/hooks"))
        #expect(text.contains("trust"))
        #expect(text.contains("Install"))
        #expect(text.contains("Jira authorization"))
        #expect(text.contains("Integrate Jira"))
        if installed {
            #expect(text.contains("Configured"))
            #expect(text.contains("Uninstall"))
            #expect(text.contains("Reinstall Codex hooks"))
        }
    }

    @Test func completionThemeRendersItsMarkdownBlockStyles() async throws {
        let model = AppModel(focusStore: try FocusStore.inMemory(), claudeRegistry: .temporaryForTesting(), runBackfill: false)
        let markdown = """
        # Heading one
        ## Heading two
        ### Heading three
        **Strong** and `inline code` with a [link](https://example.com).

        ```swift
        let answer = 42
        ```

        > Quoted text

        - First item
        - Second item

        | Agent | Status |
        | --- | --- |
        | Codex | Ready |
        """
        let content = Markdown(markdown).markdownTheme(.completionCard).padding()
        let text = try await render(content, name: "markdown", model: model)
        #expect(text.contains("Heading one"))
        #expect(text.contains("Quoted text"))
        #expect(text.contains("Codex"))
    }

    @Test func aboutShowsUpdatesAndBothGenerationsOfCredits() async throws {
        let model = AppModel(focusStore: try FocusStore.inMemory(), claudeRegistry: .temporaryForTesting(), runBackfill: false)
        let text = try await render(AboutSettingsPane(model: model), name: "about", model: model)
        for label in ["Check for Updates", "GitHub releases", "Renat", "MpaK", "aomega.co", "Austin", "Texas", "Dias Zhanabayev", "Open Vibe Island"] {
            #expect(text.contains(label))
        }
    }

    @Test func jiraSetupImportAndLinkedTaskRender() async throws {
        let store = try FocusStore.inMemory()
        let model = AppModel(focusStore: store, claudeRegistry: .temporaryForTesting(), runBackfill: false)
        let defaults = UserDefaults(suiteName: "JiraRendering.\(UUID().uuidString)")!
        let focus = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), runBackfill: false, jiraClient: StubJiraClient())
        focus.start(initialSessions: [])
        let setup = try await render(JiraConnectionView(focus: focus).padding(), name: "jira-setup", model: model)
        #expect(setup.contains("Integrate Jira"))
        #expect(setup.contains("Connect signed-in Atlassian CLI"))
        #expect(setup.contains("brew trust") && setup.contains("atlassian/acli/acli"))
        focus.jira.connect()
        await focus.jira.operation?.value
        let connected = try await render(JiraConnectionView(focus: focus).padding(), name: "jira-connected", model: model)
        #expect(connected.contains("Sync my Jira tasks"))
        #expect(connected.contains("Reconnect Jira"))
        #expect(connected.contains("Forget Jira"))
        let picker = try await render(JiraImportView(focus: focus), name: "jira-import", model: model)
        #expect(picker.contains("TEST-1"))
        #expect(picker.contains("Backlog"))
        focus.jira.importIssues(ids: ["10001"], column: .backlog, projectPath: nil)
        await focus.jira.operation?.value
        let task = try #require(focus.board.tasks.first)
        let detail = try await render(TaskDetailView(focus: focus, task: task), name: "jira-task", model: model)
        #expect(detail.contains("Jira: In Progress"))
        #expect(detail.contains("Detach from Jira"))
        #expect(detail.contains("Source description"))
    }

    private func render(_ view: some View, name: String, model: AppModel) async throws -> String {
        _ = NSApplication.shared
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = ProcessInfo.processInfo.environment["FOCUS_ISLAND_TEST_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        let directory = (output ?? temporary).appendingPathComponent(name)
        defer { if output == nil { try? FileManager.default.removeItem(at: temporary) } }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: view.preferredColorScheme(.dark).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: 0.12)))
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        let configuration = HarnessLaunchConfiguration(environment: ["OPEN_ISLAND_HARNESS_ARTIFACT_DIR": directory.path])
        try HarnessArtifactRecorder.record(configuration: configuration, model: model, launchedAt: .now)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(HarnessArtifactReport.self, from: Data(contentsOf: directory.appendingPathComponent("report.json")))
        let window = try #require(report.windows.first)
        let imageURL = directory.appendingPathComponent(window.imagePath)
        // SwiftUI's accessibility tree is incomplete in the CLI runner; verify the visible text.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["en-US", "es-ES", "ru-RU"].filter { supported.contains($0) }
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(url: imageURL).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
