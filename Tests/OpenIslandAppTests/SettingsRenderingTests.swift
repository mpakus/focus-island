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
        try VNImageRequestHandler(url: imageURL).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
