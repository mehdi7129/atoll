import XCTest
@testable import AtollCore

final class CodexAccountClientTests: XCTestCase {
    /// Explicit opt-in only; ordinary CI never touches an account or network.
    func testLiveReadOnlyAccount() throws {
        guard ProcessInfo.processInfo.environment["ATOLL_CODEX_LIVE_TEST"] == "1" else {
            throw XCTSkip("Live account test is opt-in")
        }
        let path = ProcessInfo.processInfo.environment["ATOLL_CODEX_EXECUTABLE"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path
        switch CodexAccountClient.read(executable: URL(fileURLWithPath: path)) {
        case .available(let quota):
            XCTAssertFalse(quota.buckets.isEmpty)
            print("Codex live read: \(quota.buckets.count) quota bucket(s), no thread started")
        case .unavailable(let reason): XCTFail(reason)
        }
    }
    private func withServer(_ script: String, run: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atoll-rpc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-codex")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try run(executable)
    }

    private let handshake = """
    IFS= read -r line
    case "$line" in *'"method":"initialize"'*) ;; *) exit 2;; esac
    printf '%s\\n' '{"id":1,"result":{}}'
    IFS= read -r line
    case "$line" in *'"method":"initialized"'*) ;; *) exit 3;; esac
    IFS= read -r line
    case "$line" in *'"method":"account/read"'*) ;; *) exit 4;; esac
    case "$line" in *'"refreshToken":false'*) ;; *) exit 5;; esac
    """

    func testHandshakeReadOnlyMethodsAndFragmentedLines() throws {
        try withServer(handshake + "\n" + """
        printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
        IFS= read -r line
        case "$line" in *'"method":"account/rateLimits/read"'*) ;; *) exit 6;; esac
        printf '%s\\n' '{"method":"unrelated/notification","params":{}}'
        printf '%s' '{"id":3,"result":{"rateLimits":'
        printf '%s\\n' '{"primary":{"usedPercent":37,"windowDurationMins":300}}}}'
        """) { executable in
            guard case .available(let quota) = CodexAccountClient.read(executable: executable, timeout: 2) else {
                return XCTFail("Handshake/quota failed")
            }
            XCTAssertEqual(quota.primaryBucket?.windows.first?.usedFraction, 0.37)
        }
    }

    func testAPIAccountDoesNotReadSubscriptionLimits() throws {
        try withServer(handshake + "\nprintf '%s\\n' '{\"id\":2,\"result\":{\"account\":{\"type\":\"apiKey\"}}}'\n") { executable in
            guard case .unavailable(let reason) = CodexAccountClient.read(executable: executable, timeout: 2) else {
                return XCTFail("API key is not subscription usage")
            }
            XCTAssertTrue(reason.contains("hors abonnement"))
        }
    }

    func testLoggedOutAndErrorDoNotLeakServerDiagnostics() throws {
        for response in [#"{"id":2,"result":{"account":null}}"#,
                         #"{"id":2,"error":{"message":"SECRET_TOKEN_DO_NOT_LOG"}}"#] {
            try withServer(handshake + "\nprintf '%s\\n' '\(response)'\n") { executable in
                guard case .unavailable(let reason) = CodexAccountClient.read(executable: executable, timeout: 2) else {
                    return XCTFail("Unavailable expected")
                }
                XCTAssertFalse(reason.contains("SECRET_TOKEN"))
            }
        }
    }

    func testTimeoutTerminatesChildAndCancellationIsBounded() throws {
        try withServer("exec /bin/sleep 30\n") { executable in
            let started = Date()
            guard case .unavailable = CodexAccountClient.read(executable: executable, timeout: 0.15) else {
                return XCTFail("Timeout expected")
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
            let cancelled = Date()
            _ = CodexAccountClient.read(executable: executable, cancelled: { true })
            XCTAssertLessThan(Date().timeIntervalSince(cancelled), 3)
        }
    }

    func testEarlyExitDoesNotCrashHostWithSIGPIPE() throws {
        try withServer("exit 1\n") { executable in
            guard case .unavailable = CodexAccountClient.read(executable: executable, timeout: 1) else {
                return XCTFail("Unavailable expected")
            }
        }
    }
}
