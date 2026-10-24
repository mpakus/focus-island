import Foundation
import Testing
@testable import OpenIslandCore
@testable import OpenIslandApp

actor UsageReaderFixture {
    var calls = 0
    var failure = false
    func fail() { failure = true }
    func read() async throws -> CodexUsageSnapshot {
        calls += 1
        try await Task.sleep(for: .milliseconds(20))
        if failure { throw CodexUsageError.signInRequired }
        return try CodexUsageSnapshot.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":10080}}}"#.utf8))
    }
}

@MainActor
struct CodexUsageCoordinatorTests {
    @Test func refreshDoesNotOverlapAndClearsPreviousAccountDataOnFailure() async throws {
        let fixture = UsageReaderFixture()
        let coordinator = CodexUsageCoordinator(read: { try await fixture.read() })
        coordinator.refresh(); coordinator.refresh()
        await coordinator.operation?.value
        #expect(await fixture.calls == 1)
        #expect(coordinator.snapshot != nil && coordinator.error == nil && !coordinator.isRefreshing)
        await fixture.fail()
        coordinator.refresh(); await coordinator.operation?.value
        #expect(coordinator.snapshot == nil && coordinator.error == CodexUsageError.signInRequired.localizedDescription)
    }
}
