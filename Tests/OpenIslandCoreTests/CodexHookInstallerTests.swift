import Foundation
import Testing
@testable import OpenIslandCore

struct CodexHookInstallerTests {
    @Test func preservesOtherHooksAndIsIdempotent() throws {
        let original = Data(#"{"other":"keep","hooks":{"Stop":[{"matcher":"x","extra":true,"hooks":[{"type":"command","command":"echo user-hook","timeout":7}]}],"FutureEvent":[{"hooks":[{"type":"future","extra":42}]}]}}"#.utf8)
        let command = CodexHookInstaller.command(binaryURL: URL(fileURLWithPath: "/tmp/path with 'quote/OpenIslandHooks"))
        let installed = try CodexHookInstaller.mutate(original, command: command, previousCommand: nil, install: true)
        #expect(try CodexHookInstaller.containsAllEvents(installed, command: command))
        #expect(try CodexHookInstaller.mutate(installed, command: command, previousCommand: command, install: true) == installed)
        let removed = try CodexHookInstaller.mutate(installed, command: command, previousCommand: command, install: false)
        let before = try JSONSerialization.jsonObject(with: original) as? NSDictionary
        let after = try JSONSerialization.jsonObject(with: removed) as? NSDictionary
        #expect(before == after)
    }

    @Test func isolatedInstallBacksUpAndUninstallsOnlyOwnedEntries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source-helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let target = folder.appendingPathComponent("bin/OpenIslandHooks")
        let config = folder.appendingPathComponent("hooks.json")
        let original = Data(#"{"extra":"preserved"}"#.utf8)
        try original.write(to: config)
        let manager = CodexHookInstallationManager(directory: folder, managedBinaryURL: target)
        #expect(try manager.install(hooksBinaryURL: source).readyForVerification)
        #expect(try manager.install(hooksBinaryURL: source).readyForVerification)
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("hooks.json.backup.") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
        #expect(try !manager.uninstall().configured)
        #expect(FileManager.default.isExecutableFile(atPath: target.path))
        #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: String]) == ["extra": "preserved"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("hook-trust.json").path))
    }

    @Test func malformedAndInlineConfigFailWithoutModification() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("hooks.json")
        let malformed = Data(#"{"hooks":{"Stop":"invalid"}}"#.utf8)
        try malformed.write(to: config)
        let manager = CodexHookInstallationManager(directory: folder, managedBinaryURL: folder.appendingPathComponent("bin/OpenIslandHooks"))
        #expect(throws: (any Error).self) { try manager.install(hooksBinaryURL: folder.appendingPathComponent("missing")) }
        #expect(try Data(contentsOf: config) == malformed)
        try Data("{}".utf8).write(to: config)
        try Data("command = 'OpenIslandHooks --source codex'\n".utf8).write(to: folder.appendingPathComponent("config.toml"))
        #expect(try manager.status().inlineConflict)
        #expect(throws: (any Error).self) { try manager.install(hooksBinaryURL: folder.appendingPathComponent("missing")) }
        #expect(try Data(contentsOf: config) == Data("{}".utf8))
    }

    @Test func honorsCustomCodexHome() {
        #expect(CodexConfigDirectory.resolved(environment: ["CODEX_HOME": "/tmp/codex-home"]).path == "/tmp/codex-home")
    }
}
