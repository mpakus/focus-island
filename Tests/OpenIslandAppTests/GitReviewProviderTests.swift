import Foundation
import Testing
@testable import OpenIslandApp

struct GitReviewProviderTests {
    @Test func reviewsStagedUnstagedUntrackedDeletedAndUnusualPathsFromSubdirectory() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["space name.txt", "line\nbreak.txt", "tab\tname.txt", "-flag.txt", "delete.txt"]
        for name in names { try Data("before\n".utf8).write(to: root.appendingPathComponent(name)) }
        try git(root, ["add", "."])
        try git(root, ["commit", "-qm", "fixture"])
        for name in names.dropLast() { try Data("after\n".utf8).write(to: root.appendingPathComponent(name)) }
        try git(root, ["add", "--", "space name.txt"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("delete.txt"))
        try Data("new content\n".utf8).write(to: root.appendingPathComponent("new.txt"))
        let subdirectory = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let provider = GitReviewProvider()
        let snapshot = try await provider.snapshot(cwd: subdirectory.path)
        #expect(snapshot.branch == "main")
        #expect(URL(fileURLWithPath: snapshot.root).resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        #expect(Set(snapshot.files.map(\.path)) == Set(names + ["new.txt"]))
        for file in snapshot.files {
            let text = try await provider.diff(file: file, snapshot: snapshot)
            #expect(!text.isEmpty)
            if file.path == "new.txt" { #expect(text == "new content\n") }
            else { #expect(text.contains("-before")) }
        }
    }

    @Test func supportsUnbornRepositoryAndRejectsSymlinksAndOversizedFiles() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first\n".utf8).write(to: root.appendingPathComponent("first.txt"))
        try git(root, ["add", "."])
        try Data(repeating: 65, count: GitReviewProvider.diffLimit + 1).write(to: root.appendingPathComponent("large.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("first.txt"))
        let provider = GitReviewProvider()
        let snapshot = try await provider.snapshot(cwd: root.path)
        #expect(!snapshot.hasHead)
        #expect(try await provider.diff(file: #require(snapshot.files.first { $0.path == "first.txt" }), snapshot: snapshot) == "first\n")
        for name in ["large.txt", "link.txt"] {
            let file = try #require(snapshot.files.first { $0.path == name })
            await #expect(throws: GitReviewError.self) { try await provider.diff(file: file, snapshot: snapshot) }
        }
        #expect(!GitReviewProvider.safeRelativePath("../secret"))
        #expect(!GitReviewProvider.safeRelativePath("/etc/passwd"))
    }

    @Test func cleanDetachedAndInvalidRepositoriesHaveDistinctOutcomes() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, ["commit", "--allow-empty", "-qm", "fixture"])
        try git(root, ["checkout", "--detach", "-q"])
        let provider = GitReviewProvider()
        let snapshot = try await provider.snapshot(cwd: root.path)
        #expect(snapshot.hasHead && snapshot.files.isEmpty)
        #expect(snapshot.branch != "main")
        await #expect(throws: GitReviewError.self) { try await provider.snapshot(cwd: root.appendingPathComponent("missing").path) }
    }

    func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("focus review \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(root, ["init", "-q", "-b", "main"])
        return root
    }

    func git(_ root: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "user.name=Focus Tests", "-c", "user.email=tests@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
