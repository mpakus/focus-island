import Foundation
import Testing
@testable import OpenIslandCore

struct CodexUsageTests {
    @Test func windowsUseTheirActualDurationsAndMultiBucketOverridesLegacy() throws {
        let snapshot = try CodexUsageSnapshot.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1800000000},"secondary":null},"extra":{"limitName":"Extra","primary":{"usedPercent":120,"windowDurationMins":300},"secondary":{"usedPercent":-5}}}}"#.utf8))
        #expect(snapshot.buckets.count == 2)
        #expect(snapshot.buckets[0].windows[0].label == "7d")
        #expect(snapshot.buckets[0].windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(snapshot.buckets[1].windows.map(\.usedPercentage) == [100, 0])
        #expect(snapshot.buckets[1].windows.map(\.label) == ["5h", "Secondary"])
        #expect(snapshot.buckets[1].windows[0].resetsAt == nil)
    }

    @Test func emptyAndMalformedAreNeverZeroUsage() throws {
        for json in ["{}", #"{"rateLimits":{"primary":null,"secondary":null}}"#] {
            #expect(throws: CodexUsageError.unavailable) { try CodexUsageSnapshot.decode(Data(json.utf8)) }
        }
        for json in ["bad", #"{"rateLimits":{"primary":{"usedPercent":"25"}}}"#] {
            #expect(throws: CodexUsageError.invalidResponse) { try CodexUsageSnapshot.decode(Data(json.utf8)) }
        }
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":90}},"rateLimitsByLimitId":{}}"#.utf8)
        #expect(try CodexUsageSnapshot.decode(data).buckets[0].windows[0].label == "90m")
    }

    @Test(arguments: ["ok", "signedOut", "apiKey", "error", "oversized", "earlyExit", "exitAfterInitialize", "timeout"])
    func boundedProcessOnlyReadsAccountQuotas(mode: String) async throws {
        let (directory, executable) = try fixture(mode)
        defer { try? FileManager.default.removeItem(at: directory) }
        if mode == "ok" {
            let snapshot = try await CodexUsageClient.read(executable: executable, timeout: 3)
            #expect(snapshot.buckets[0].windows[0].usedPercentage == 25)
        } else {
            let error: CodexUsageError = switch mode {
            case "signedOut": .signInRequired
            case "apiKey": .unsupportedAccount
            case "oversized": .invalidResponse
            case "timeout": .timedOut
            default: .unavailable
            }
            await #expect(throws: error) { try await CodexUsageClient.read(executable: executable, timeout: mode == "timeout" ? 0.15 : 3) }
        }
        if let pid = try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8), let value = Int32(pid) {
            #expect(kill(value, 0) == -1)
        }
    }

    @Test func cancellationReapsChildAndMissingExecutableIsHandled() async throws {
        await #expect(throws: CodexUsageError.unavailable) { try await CodexUsageClient.read(executable: nil) }
        let (directory, executable) = try fixture("timeout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task { try await CodexUsageClient.read(executable: executable) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("pid").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(Int32(String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOCUS_ISLAND_CODEX_USAGE_LIVE"] == "1"))
    func liveQuotaOnlyRead() async throws {
        let snapshot = try await CodexUsageClient.read()
        #expect(!snapshot.buckets.isEmpty)
        #expect(snapshot.buckets.allSatisfy { !$0.windows.isEmpty && $0.windows.allSatisfy { (0...100).contains($0.usedPercentage) } })
    }

    private func fixture(_ mode: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("codex")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys, time
        mode = "MODE"
        open(os.path.join(os.path.dirname(__file__), 'pid'), 'w').write(str(os.getpid()))
        def receive(method):
            value = json.loads(sys.stdin.readline())
            assert value['method'] == method
            return value
        def reply(value):
            sys.stdout.write(json.dumps(value) + '\n'); sys.stdout.flush()
        first = receive('initialize')
        assert first['params']['capabilities'] == {'explicitGatewayOauth': True}
        if mode == 'earlyExit': sys.exit(0)
        if mode == 'timeout': time.sleep(30)
        if mode == 'oversized':
            sys.stdout.write('a' * 300000); sys.stdout.flush(); time.sleep(30)
        reply({'method':'account/updated','params':{}})
        reply({'id':1,'result':{}})
        if mode == 'exitAfterInitialize': sys.exit(0)
        receive('initialized')
        account = receive('account/read')
        assert account['params'] == {'refreshToken': False}
        reply({'id':2,'result':{'account':None if mode == 'signedOut' else {'type':'apiKey' if mode == 'apiKey' else 'chatgpt'}}})
        if mode in ['signedOut', 'apiKey']: sys.exit(0)
        limits = receive('account/rateLimits/read')
        assert limits['params'] == {'excludeResetCreditDetails':True}
        response = {'id':3,'error':{'code':-32601}} if mode == 'error' else {'id':3,'result':{'rateLimits':{'primary':{'usedPercent':25,'windowDurationMins':10080}}}}
        text = json.dumps(response) + '\n'
        sys.stdout.write(text[:7]); sys.stdout.flush(); time.sleep(.01)
        sys.stdout.write(text[7:]); sys.stdout.flush()
        assert sys.stdin.read() == ''
        """#.replacingOccurrences(of: "MODE", with: mode)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return (directory, file)
    }
}
