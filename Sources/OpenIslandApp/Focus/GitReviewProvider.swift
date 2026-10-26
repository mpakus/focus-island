import Foundation
import OpenIslandCore

struct ReviewFile: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let status: String
}

struct GitReviewSnapshot: Equatable, Sendable {
    let root: String
    let branch: String
    let hasHead: Bool
    let files: [ReviewFile]
    let omittedFiles: Int
}

enum GitReviewError: LocalizedError {
    case unavailable, tooLarge, timeout, unsafeFile

    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.tr("review.unavailable")
        case .tooLarge: L10n.tr("review.too_large")
        case .timeout: L10n.tr("review.timeout")
        case .unsafeFile: L10n.tr("review.unsafe_file")
        }
    }
}

struct GitReviewProvider: Sendable {
    static let diffLimit = 256 * 1024

    func snapshot(cwd: String) async throws -> GitReviewSnapshot {
        let rootResult = try await git(cwd, ["rev-parse", "--show-toplevel"])
        guard rootResult.status == 0 else { throw GitReviewError.unavailable }
        let root = String(decoding: rootResult.data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let head = try await git(root, ["rev-parse", "--verify", "HEAD"])
        let branch = try await git(root, ["symbolic-ref", "--short", "-q", "HEAD"])
        let branchName = branch.status == 0 ? String(decoding: branch.data, as: UTF8.self).trimmingCharacters(in: .newlines)
            : L10n.tr("review.detached", String(String(decoding: head.data, as: UTF8.self).prefix(12)))
        let changed = try await git(root, head.status == 0
            ? ["diff", "--no-ext-diff", "--no-textconv", "--name-status", "-z", "--no-renames", "HEAD", "--"]
            : ["ls-files", "-z"])
        let untracked = try await git(root, ["ls-files", "--others", "--exclude-standard", "-z"])
        guard changed.status == 0, untracked.status == 0 else { throw GitReviewError.unavailable }
        var files = head.status == 0 ? Self.parseStatus(changed.data)
            : Self.paths(changed.data).map { ReviewFile(path: $0, status: "A") }
        files += Self.paths(untracked.data).map { ReviewFile(path: $0, status: "?") }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return GitReviewSnapshot(root: root, branch: branchName, hasHead: head.status == 0,
            files: Array(files.prefix(500)), omittedFiles: max(0, files.count - 500))
    }

    func diff(file: ReviewFile, snapshot: GitReviewSnapshot) async throws -> String {
        guard snapshot.files.contains(file), Self.safeRelativePath(file.path) else { throw GitReviewError.unsafeFile }
        if file.status == "?" || !snapshot.hasHead {
            let root = URL(fileURLWithPath: snapshot.root).resolvingSymlinksInPath()
            let url = root.appendingPathComponent(file.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw GitReviewError.unsafeFile }
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.diffLimit else { throw GitReviewError.tooLarge }
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw GitReviewError.unsafeFile }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw GitReviewError.unsafeFile }
            let data = try handle.read(upToCount: Self.diffLimit + 1) ?? Data()
            guard data.count <= Self.diffLimit else { throw GitReviewError.tooLarge }
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return L10n.tr("review.binary") }
            return text.isEmpty ? L10n.tr("review.empty_file") : text
        }
        let result = try await git(snapshot.root,
            ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "HEAD", "--", file.path], limit: Self.diffLimit)
        guard result.status == 0 else { throw GitReviewError.unavailable }
        let text = String(decoding: result.data, as: UTF8.self)
        return text.isEmpty ? L10n.tr("review.no_diff") : text
    }

    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    private static func paths(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    static func parseStatus(_ data: Data) -> [ReviewFile] {
        let fields = paths(data)
        return stride(from: 0, to: fields.count - (fields.count % 2), by: 2).compactMap { index in
            guard safeRelativePath(fields[index + 1]) else { return nil }
            return ReviewFile(path: fields[index + 1], status: fields[index])
        }
    }

    private func git(_ cwd: String, _ arguments: [String], limit: Int = 2 * 1024 * 1024) async throws -> (data: Data, status: Int32) {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("focus-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-C", cwd] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw GitReviewError.timeout }
            let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
            guard size?.intValue ?? 0 <= limit else { throw GitReviewError.tooLarge }
            try await Task.sleep(for: .milliseconds(20))
        }
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw GitReviewError.tooLarge }
        return (data, process.terminationStatus)
    }
}
