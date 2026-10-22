import Foundation
import OpenIslandCore

public enum ShellQuoting {
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum AppleScriptQuoting {
    public static func string(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum ResumeCommand {
    public static func resume(sessionID: String, cwd: String, provider: AgentTool = .claudeCode) -> String {
        let command = provider == .codex ? "codex resume" : "claude --resume"
        return "cd \(ShellQuoting.singleQuoted(cwd)) && \(command) \(ShellQuoting.singleQuoted(sessionID))"
    }

    public static func newSession(cwd: String, provider: AgentTool = .claudeCode) -> String {
        "cd \(ShellQuoting.singleQuoted(cwd)) && \(provider == .codex ? "codex" : "claude")"
    }
}
