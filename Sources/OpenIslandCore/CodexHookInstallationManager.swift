import Foundation

public enum CodexConfigDirectory {
    public static func resolved(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
}

public struct CodexHookInstallationStatus: Equatable, Sendable {
    public var configURL: URL
    public var configured: Bool
    public var binaryAvailable: Bool
    public var inlineConflict: Bool

    public var readyForVerification: Bool { configured && binaryAvailable && !inlineConflict }
}

public enum CodexHookInstallationError: Error, LocalizedError {
    case malformedConfiguration
    case inlineConflict

    public var errorDescription: String? {
        switch self {
        case .malformedConfiguration: L10n.tr("core.codex_hooks_configuration_is_malformed_no_files_were_changed")
        case .inlineConflict: L10n.tr("core.focus_island_codex_hooks_already_appear_in_config_toml_remove_that_duplicat")
        }
    }
}

public enum CodexHookInstaller {
    public static func command(binaryURL: URL) -> String {
        "'" + binaryURL.path.replacingOccurrences(of: "'", with: "'\\''") + "' --source codex"
    }

    public static func mutate(_ data: Data?, command: String, previousCommand: String?, install: Bool) throws -> Data {
        var root: [String: Any] = [:]
        if let data {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CodexHookInstallationError.malformedConfiguration
            }
            root = object
        }
        if let hooks = root["hooks"], !(hooks is [String: Any]) {
            throw CodexHookInstallationError.malformedConfiguration
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { throw CodexHookInstallationError.malformedConfiguration }
            var kept: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw CodexHookInstallationError.malformedConfiguration }
                let filtered = handlers.filter { handler in
                    guard let value = handler["command"] as? String else { return true }
                    return value != command && value != previousCommand
                }
                if filtered.count == handlers.count {
                    kept.append(group)
                } else if !filtered.isEmpty {
                    group["hooks"] = filtered
                    kept.append(group)
                }
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = kept }
        }
        if install {
            for event in CodexHookAdapter.events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 1]]])
                hooks[event] = groups
            }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func containsAllEvents(_ data: Data?, command: String) throws -> Bool {
        guard let data else { return false }
        _ = try mutate(data, command: command, previousCommand: nil, install: false)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = root?["hooks"] as? [String: Any] ?? [:]
        return CodexHookAdapter.events.allSatisfy { event in
            let groups = hooks[event] as? [[String: Any]] ?? []
            return groups.contains { group in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                return handlers.contains { ($0["command"] as? String) == command && ($0["type"] as? String) == "command" }
            }
        }
    }
}

public struct CodexHookInstallationManager: Sendable {
    public let directory: URL
    public let managedBinaryURL: URL

    private struct Manifest: Codable { var command: String }
    private var configURL: URL { directory.appendingPathComponent("hooks.json") }
    private var manifestURL: URL { directory.appendingPathComponent("focus-island-codex-hooks-install.json") }

    public init(directory: URL = CodexConfigDirectory.resolved(), managedBinaryURL: URL = ManagedHooksBinary.defaultURL()) {
        self.directory = directory
        self.managedBinaryURL = managedBinaryURL
    }

    private func dataIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func manifest() throws -> Manifest? {
        try dataIfPresent(manifestURL).map { try JSONDecoder().decode(Manifest.self, from: $0) }
    }

    private func hasInlineConflict() throws -> Bool {
        guard let data = try dataIfPresent(directory.appendingPathComponent("config.toml")),
              let text = String(data: data, encoding: .utf8) else { return false }
        // Refuse to rewrite TOML; only detect our own command, leaving other hook sources intact.
        return text.split(separator: "\n").contains {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                && $0.contains("OpenIslandHooks") && $0.contains("--source codex")
        }
    }

    public func status() throws -> CodexHookInstallationStatus {
        let command = try manifest()?.command ?? CodexHookInstaller.command(binaryURL: managedBinaryURL)
        return try CodexHookInstallationStatus(
            configURL: configURL,
            configured: CodexHookInstaller.containsAllEvents(dataIfPresent(configURL), command: command),
            binaryAvailable: FileManager.default.isExecutableFile(atPath: managedBinaryURL.path),
            inlineConflict: hasInlineConflict()
        )
    }

    @discardableResult
    public func install(hooksBinaryURL: URL) throws -> CodexHookInstallationStatus {
        guard try !hasInlineConflict() else { throw CodexHookInstallationError.inlineConflict }
        let previous = try manifest()
        let data = try dataIfPresent(configURL)
        let command = CodexHookInstaller.command(binaryURL: managedBinaryURL)
        let updated = try CodexHookInstaller.mutate(data, command: command, previousCommand: previous?.command, install: true)
        // Validate before copying the shared helper or touching user files.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try ManagedHooksBinary.install(from: hooksBinaryURL, to: managedBinaryURL)
        try writeConfig(updated, previous: data)
        try JSONEncoder().encode(Manifest(command: command)).write(to: manifestURL, options: .atomic)
        return try status()
    }

    @discardableResult
    public func uninstall() throws -> CodexHookInstallationStatus {
        let previous = try manifest()
        if let data = try dataIfPresent(configURL) {
            let updated = try CodexHookInstaller.mutate(data,
                command: CodexHookInstaller.command(binaryURL: managedBinaryURL),
                previousCommand: previous?.command, install: false)
            try writeConfig(updated, previous: data)
        }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            try FileManager.default.removeItem(at: manifestURL)
        }
        // The helper is shared with Claude and remains installed.
        return try status()
    }

    private func writeConfig(_ updated: Data, previous: Data?) throws {
        guard previous != updated else { return }
        if let previous {
            try previous.write(to: configURL.appendingPathExtension("backup.\(UUID().uuidString)"), options: .atomic)
        }
        try updated.write(to: configURL, options: .atomic)
    }
}
