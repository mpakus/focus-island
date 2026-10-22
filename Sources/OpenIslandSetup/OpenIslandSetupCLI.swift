import Foundation
import OpenIslandCore

@main
struct OpenIslandSetupCLI {
    static func main() {
        do {
            let command = try SetupCommand(arguments: Array(CommandLine.arguments.dropFirst()))
            try command.run()
        } catch let error as SetupError {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct SetupCommand {
    enum Action: String {
        case installClaude
        case uninstallClaude
        case statusClaude
        case installCodex
        case statusCodex
        case uninstallCodex
    }

    let action: Action
    let claudeDirectory: URL
    let codexDirectory: URL
    let hooksBinary: URL?

    init(arguments: [String]) throws {
        guard let rawAction = arguments.first,
              let action = Action(rawValue: rawAction) else {
            throw SetupError.usage
        }

        self.action = action

        var hooksBinary: URL?
        var claudeDirectory = ClaudeConfigDirectory.resolved()
        var codexDirectory = CodexConfigDirectory.resolved()

        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--hooks-binary":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--hooks-binary")
                }
                hooksBinary = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            case "--codex-dir":
                index += 1
                guard index < arguments.count else { throw SetupError.missingValue("--codex-dir") }
                codexDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            case "--claude-dir":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--claude-dir")
                }
                claudeDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            default:
                throw SetupError.unexpectedArgument(arguments[index])
            }

            index += 1
        }

        if action == .installClaude || action == .installCodex, hooksBinary == nil {
            hooksBinary = HooksBinaryLocator.locate()
        }

        self.claudeDirectory = claudeDirectory
        self.codexDirectory = codexDirectory
        self.hooksBinary = hooksBinary
    }

    func run() throws {
        switch action {
        case .installCodex, .statusCodex, .uninstallCodex:
            let manager = CodexHookInstallationManager(directory: codexDirectory)
            let status: CodexHookInstallationStatus
            switch action {
            case .installCodex:
                guard let hooksBinary else { throw SetupError.usage }
                status = try manager.install(hooksBinaryURL: hooksBinary)
            case .uninstallCodex: status = try manager.uninstall()
            default: status = try manager.status()
            }
            print("Codex hooks: \(status.configured ? "configured" : "not configured")")
            print("Config: \(status.configURL.path)")
            print("Helper available: \(status.binaryAvailable)")
            print("Inline duplicate: \(status.inlineConflict)")
            if status.configured {
                print("Review and trust the hooks in Codex /hooks, then send a prompt to verify monitoring.")
            }
        case .installClaude:
            try installClaude()
        case .uninstallClaude:
            try uninstallClaude()
        case .statusClaude:
            try statusClaude()
        }
    }

    private func installClaude() throws {
        guard let hooksBinary else {
            throw SetupError.usage
        }

        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.install(hooksBinaryURL: hooksBinary)

        print("Installed Open Island Claude hooks.")
        print("Claude dir: \(status.claudeDirectory.path)")
        print("Hooks binary: \(hooksBinary.path)")
        if status.hasClaudeIslandHooks {
            print("Note: claude-island hooks are still present alongside Open Island hooks.")
        }
    }

    private func uninstallClaude() throws {
        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.uninstall()

        print("Removed Open Island Claude hooks.")
        print("Claude dir: \(status.claudeDirectory.path)")
        if status.hasClaudeIslandHooks {
            print("Preserved claude-island hooks.")
        }
    }

    private func statusClaude() throws {
        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.status(hooksBinaryURL: hooksBinary)

        print("Claude dir: \(status.claudeDirectory.path)")
        print("Managed hooks present: \(status.managedHooksPresent ? "yes" : "no")")
        print("claude-island hooks present: \(status.hasClaudeIslandHooks ? "yes" : "no")")
        if let hooksBinary {
            print("Hooks binary: \(hooksBinary.path)")
        }
        if let manifest = status.manifest {
            print("Manifest: present")
            print("Hook command: \(manifest.hookCommand)")
        } else {
            print("Manifest: missing")
        }
    }
}

private enum SetupError: Error, LocalizedError {
    case usage
    case missingValue(String)
    case unexpectedArgument(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            """
            Usage:
              swift run OpenIslandSetup installCodex [--hooks-binary /abs/path/to/OpenIslandHooks] [--codex-dir /abs/path/to/.codex]
              swift run OpenIslandSetup statusCodex [--codex-dir /abs/path/to/.codex]
              swift run OpenIslandSetup uninstallCodex [--codex-dir /abs/path/to/.codex]
              swift run OpenIslandSetup installClaude [--hooks-binary /abs/path/to/OpenIslandHooks] [--claude-dir /abs/path/to/.claude]
              swift run OpenIslandSetup uninstallClaude [--claude-dir /abs/path/to/.claude]
              swift run OpenIslandSetup statusClaude [--hooks-binary /abs/path/to/OpenIslandHooks] [--claude-dir /abs/path/to/.claude]
            """
        case let .missingValue(flag):
            "Missing value for \(flag)"
        case let .unexpectedArgument(argument):
            "Unexpected argument: \(argument)"
        }
    }
}
