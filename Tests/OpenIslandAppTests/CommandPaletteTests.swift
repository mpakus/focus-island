import FocusCore
import Carbon
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct CommandPaletteTests {
    @Test func searchAndCaptureReuseBoardActions() throws {
        let (focus, store, _) = try FocusCoordinatorTests().makeCoordinator()
        let board = BoardService(store: store)
        let task = try board.createTask(title: "Fix Café login", column: .todo, projectPath: "/work/island")
        let done = try board.createTask(title: "Finished", column: .done)
        focus.start(initialSessions: [])
        let matches = focus.paletteCommands(query: "CAFE island")
        #expect(matches.contains { $0.action == .task(task.id) })
        #expect(!focus.paletteCommands(query: "").contains { $0.action == .task(done.id) })
        #expect(matches.last?.action == .capture("CAFE island"))
        focus.performPalette(.capture("  Remember this  "))
        focus.performPalette(.capture(" \n "))
        #expect(focus.board.tasks.count == 3)
        #expect(focus.board.tasks.contains { $0.title == "Remember this" && $0.boardColumn == .todo })
    }

    @Test func timerActionsAndSessionNavigationRespectCurrentState() throws {
        let fixture = FocusCoordinatorTests()
        let (focus, store, _) = try fixture.makeCoordinator()
        let task = try BoardService(store: store).createTask(title: "Work", column: .inProgress)
        focus.start(initialSessions: [fixture.session("waiting", .waitingForAnswer, at: .now)])
        focus.startTask(taskID: task.id, sessionIDs: ["waiting"], focusMinutes: nil)
        #expect(focus.paletteCommands(query: "").contains { $0.action == .startTimer })
        focus.performPalette(.startTimer)
        #expect(focus.pomodoro?.taskID == task.id)
        focus.performPalette(.pauseTimer)
        #expect(focus.pomodoro?.isPaused == true)
        #expect(focus.paletteCommands(query: "").contains { $0.action == .resumeTimer })
        focus.performPalette(.resumeTimer)
        #expect(focus.pomodoro?.isPaused == false)
        var jumped: [String] = []
        focus.jumpToSession = { jumped.append($0) }
        focus.performPalette(.session("missing"))
        focus.performPalette(.session("waiting"))
        #expect(jumped == ["waiting"])
        focus.stopPomodoro()
        focus.performPalette(.resumeTimer)
        #expect(focus.pomodoro == nil)
    }

    @Test func oldPreferencesReceiveSafeDefaultsAndNewPreferencesRoundTrip() throws {
        let old = try JSONDecoder().decode(FocusSettings.self, from: Data("{}".utf8))
        #expect(old.paletteShortcutEnabled && old.dailyBackupsEnabled)
        var settings = old
        settings.paletteShortcutEnabled = false
        settings.dailyBackupsEnabled = false
        let restored = try JSONDecoder().decode(FocusSettings.self, from: JSONEncoder().encode(settings))
        #expect(!restored.paletteShortcutEnabled && !restored.dailyBackupsEnabled)
    }

    @Test func boardAndPaletteHotkeyEventsDispatchIndependently() throws {
        var boardCalls = 0, paletteCalls = 0
        let board = GlobalHotKey(hotKey: .off) { boardCalls += 1 }
        let palette = GlobalHotKey(paletteEnabled: false) { paletteCalls += 1 }
        defer { withExtendedLifetime((board, palette)) {} }
        for identifier: UInt32 in [1, 2] {
            var event: EventRef?
            #expect(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeUserEvent), &event) == noErr)
            let value = try #require(event)
            defer { ReleaseEvent(value) }
            var id = EventHotKeyID(signature: OSType(0x46_4F_43_53), id: identifier)
            #expect(SetEventParameter(value, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr)
            #expect(SendEventToEventTarget(value, GetApplicationEventTarget()) == noErr)
        }
        #expect(boardCalls == 1 && paletteCalls == 1)
    }

    @Test func recommendationTracksWaitAgeAcrossRepeatedSessionUpdates() throws {
        let fixture = FocusCoordinatorTests()
        let (focus, store, _) = try fixture.makeCoordinator()
        let t0 = fixture.t0
        let task = try BoardService(store: store).createTask(title: "Focus", column: .inProgress)
        let running = fixture.session("running", .running, at: t0)
        let inside = fixture.session("inside", .waitingForApproval, at: t0.addingTimeInterval(600))
        var outside = fixture.session("outside", .waitingForAnswer, at: t0)
        focus.start(initialSessions: [running, inside, outside], now: t0.addingTimeInterval(700))
        focus.startTask(taskID: task.id, sessionIDs: ["running", "inside"], focusMinutes: nil, now: t0.addingTimeInterval(700))
        #expect(focus.nudgeSuggestion(now: t0.addingTimeInterval(700)) == .attend(sessionID: "inside", reason: .approval, since: inside.updatedAt))
        outside.updatedAt = t0.addingTimeInterval(901)
        focus.sessionsDidChange([running, inside, outside], now: outside.updatedAt)
        let suggestion = try #require(focus.nudgeSuggestion(now: outside.updatedAt))
        #expect(suggestion == .attend(sessionID: "outside", reason: .question, since: t0))
        #expect(focus.recommendationReason(suggestion, now: outside.updatedAt).contains("15"))
    }
}
