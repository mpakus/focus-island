import Foundation
import Darwin
import OpenIslandCore

@main
struct OpenIslandHooksCLI {
    private static let interactiveClaudeHookTimeout: TimeInterval = 24 * 60 * 60

    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let sourceString = rawSourceString(arguments: arguments)
            // Allow wrappers to delegate one child process away from Open Island without changing global hook installation.
            // 允许外部控制器只让当前子进程跳过 Open Island hook，不影响全局安装状态。
            if HookSkipConfiguration.shouldSkipHooks(environment: ProcessInfo.processInfo.environment) {
                if sourceString == "codex" { FileHandle.standardOutput.write(Data("{}\n".utf8)) }
                return
            }

            guard let sourceString else { return }
            if sourceString == "codex" {
                processCodex()
                return
            }
            guard sourceString == "claude" else {
                return
            }

            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard !input.isEmpty else {
                return
            }

            let decoder = JSONDecoder()
            let client = BridgeCommandClient(socketURL: BridgeSocketLocation.currentURL())

            var payload = try decoder
                .decode(ClaudeHookPayload.self, from: input)
                .withRuntimeContext(environment: ProcessInfo.processInfo.environment)
            payload.hookSource = sourceString

            let timeout = payload.hookEventName == .permissionRequest
                ? interactiveClaudeHookTimeout
                : 45

            guard let response = try? client.send(.processClaudeHook(payload), timeout: timeout) else {
                logStderr("bridge unavailable for claude hook (\(payload.hookEventName.rawValue))")
                return
            }

            if let output = try ClaudeHookOutputEncoder.standardOutput(for: response) {
                FileHandle.standardOutput.write(output)
            }
        } catch {
            // Hooks should fail open so the CLI continues working even if the bridge is unavailable.
            logStderr("hook failed: \(error)")
        }
    }

    private static func processCodex() {
        // A valid no-op for Stop and for the other supported command hooks, including failures.
        FileHandle.standardOutput.write(Data("{}\n".utf8))
        // Bound the entire helper, including stalled stdin/connect (socket receive timeouts alone do not).
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(750)) { exit(EXIT_SUCCESS) }
        do {
            let limit = 1_048_576
            var input = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, limit + 1 - input.count)), !chunk.isEmpty {
                input.append(chunk)
                guard input.count <= limit else { return }
            }
            guard !input.isEmpty else { return }
            var payload = try JSONDecoder().decode(CodexHookPayload.self, from: input)
            payload.observedAt = .now
            payload.terminalApp = ProcessInfo.processInfo.environment["TERM_PROGRAM"]
            guard payload.isValid else { return }
            let client = BridgeCommandClient(socketURL: BridgeSocketLocation.currentURL())
            _ = try client.send(.processCodexHook(payload), timeout: 0.25)
        } catch {
            logStderr("Codex monitoring unavailable; continuing without monitoring.")
        }
    }

    private static func logStderr(_ message: String) {
        guard let data = "[OpenIslandHooks] \(message)\n".data(using: .utf8) else { return }
        SafeFileDescriptorWriter.write(data)
    }

    private static func rawSourceString(arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--source", index + 1 < arguments.count {
                return arguments[index + 1]
            }

            index += 1
        }

        return nil
    }
}
