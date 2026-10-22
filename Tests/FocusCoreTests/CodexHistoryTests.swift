import Foundation
import GRDB
import OpenIslandCore
import Testing
@testable import FocusCore

struct CodexHistoryTests {
    @Test func v6PreservesV5DataAndCreatesRecoverableSnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("focus.sqlite")
        do {
            let old = try DatabaseQueue(path: url.path)
            try FocusStore.migrator(upTo: "v5").migrate(old)
            try old.write { db in
                try db.execute(sql: "INSERT INTO tasks (id,title,boardColumn,position,createdAt,updatedAt) VALUES ('task','Preserve','todo',1,?,?)", arguments: [Date(), Date()])
                try db.execute(sql: "INSERT INTO sessions (id,title,startedAt,lastActivityAt,status,taskId) VALUES ('shared','Claude',?,?,'ended','task')", arguments: [Date(), Date()])
                try db.execute(sql: "INSERT INTO queued_prompts (id,sessionId,text,createdAt) VALUES ('p','shared','keep me',?)", arguments: [Date()])
            }
        }
        let store = try FocusStore(fileURL: url)
        let record = try #require(try SessionHistory(store: store).session(id: "shared"))
        #expect(record.provider == .claudeCode && record.nativeSessionID == "shared")
        #expect(record.taskId == "task")
        #expect(try store.dbQueue.read { try String.fetchOne($0, sql: "SELECT text FROM queued_prompts WHERE id='p'") } == "keep me")
        let backup = try #require(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("before-codex") })
        let snapshot = try DatabaseQueue(path: backup.path)
        #expect(try snapshot.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }.contains("v6") == false)
        #expect(try snapshot.read { try String.fetchOne($0, sql: "SELECT title FROM tasks") } == "Preserve")
    }

    @Test func historyKeepsProvidersSeparateAndResumeUsesNativeID() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        var codex = AgentSession(id: "codex:shared", title: "Codex", tool: .codex, phase: .running, summary: "work", updatedAt: .now, codexMetadata: CodexSessionMetadata(sessionID: "shared"))
        codex.codexMetadata?.initialUserPrompt = "Codex prompt"
        try history.record(SessionObservation(session: codex))
        try history.record(SessionObservation(session: AgentSession(id: "shared", title: "Claude", tool: .claudeCode, phase: .running, summary: "work", updatedAt: .now)))
        #expect(try history.recent(limit: 10).count == 2)
        let record = try #require(try history.session(id: codex.id))
        #expect(record.provider == .codex && record.firstPrompt == "Codex prompt")
        #expect(ResumeCommand.resume(sessionID: record.nativeSessionID, cwd: "/tmp/it's here", provider: record.provider) == "cd '/tmp/it'\\''s here' && codex resume 'shared'")
        #expect(ResumeCommand.newSession(cwd: "/tmp", provider: .codex) == "cd '/tmp' && codex")
        #expect(ResumeCommand.resume(sessionID: "shared", cwd: "/tmp") == "cd '/tmp' && claude --resume 'shared'")
    }

    @Test func mixedProviderReportsUseWallClockUnion() {
        let start = Date(timeIntervalSince1970: 1_000)
        let spans = [
            ActivitySpan(kind: .claude, sessionId: "a", taskId: "t", startedAt: start, endedAt: start.addingTimeInterval(60)),
            ActivitySpan(kind: .codex, sessionId: "codex:b", taskId: "t", startedAt: start.addingTimeInterval(30), endedAt: start.addingTimeInterval(90)),
        ]
        let day = ReportBuilder.day(spans: spans, episodes: [], tasks: [], dayStart: start, dayEnd: start.addingTimeInterval(100))
        #expect(day.claudeSeconds == 60 && day.codexSeconds == 60)
        #expect(day.agentSeconds == 90 && day.maxParallel == 2)
        let week = ReportBuilder.week(spans: spans, episodes: [], tasks: [], sessions: [], weekStart: start, calendar: .current)
        #expect(week.rows.first?.seconds == 90)
    }
}
