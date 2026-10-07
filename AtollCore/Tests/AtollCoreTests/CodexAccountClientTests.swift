import XCTest
import Darwin
@testable import AtollCore

final class CodexAccountClientTests: XCTestCase {
    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let cancelOnCall: Int
        init(cancelOnCall: Int) { self.cancelOnCall = cancelOnCall }
        func isCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return calls >= cancelOnCall
        }
    }

    /// Le faux serveur reproduit l'effet de bord du chargement des plugins.
    /// Il répond aussi aux vrais échanges RPC : l'absence de staging seule ne
    /// suffirait pas si le correctif empêchait simplement tout démarrage.
    func testQuotaAndModelsAvoidPluginStagingWhileCataloguesRetainIt() throws {
        let cases: [(CodexReadClient.Query, Bool)] = [
            (.quota, false), (.models(), false), (.models(cursor: "page-2"), false),
            (.hooks(cwd: "/fixture/project"), true),
            (.skills(cwd: "/fixture/project"), true), (.plugins(cwd: "/fixture/project"), true)
        ]
        for (query, expectsStaging) in cases {
            try withServer("""
            plugins=1
            while [ "$#" -gt 0 ]; do
                if [ "$1" = '-c' ] && [ "${2-}" = 'features.plugins=false' ]; then plugins=0; fi
                shift
            done
            if [ "$plugins" = 1 ]; then : > "$CODEX_HOME/plugin-staging"; fi
            while IFS= read -r line; do
                case "$line" in
                    *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
                    *'"method":"account/read"'*) printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}' ;;
                    *'"method":"account/rateLimits/read"'*) printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":37}}}}' ;;
                    *'"method":"initialized"'*) ;;
                    *) printf '%s\\n' '{"id":2,"result":{"data":[]}}' ;;
                esac
            done
            """) { executable in
                let home = executable.deletingLastPathComponent()
                guard case .available = CodexReadClient.read(query, executable: executable, home: home, timeout: 2) else {
                    return XCTFail("Lecture indisponible pour \(query)")
                }
                XCTAssertEqual(FileManager.default.fileExists(atPath: home.appendingPathComponent("plugin-staging").path),
                               expectsStaging, "Effet de bord plugin incorrect pour \(query)")
            }
        }
    }

    func testRejectedPluginOverrideNeverRetriesWithPluginsEnabled() throws {
        try withServer("""
        printf x >> "$CODEX_HOME/launches"
        case " $* " in *' -c features.plugins=false '*) exit 2;; esac
        : > "$CODEX_HOME/plugin-staging"
        """) { executable in
            let home = executable.deletingLastPathComponent()
            guard case .unavailable = CodexReadClient.read(.quota, executable: executable, home: home, timeout: 1) else {
                return XCTFail("Le CLI qui refuse l'override doit rester indisponible")
            }
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("launches")), "x")
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("plugin-staging").path))
        }
    }

    func testCancellationBeforePreparationOrLaunchExecutesNoSubprocess() throws {
        for cancelOnCall in [1, 2] {
            try withServer(": > \"$CODEX_HOME/launched\"\n") { executable in
                let home = executable.deletingLastPathComponent()
                let cancellation = CancellationProbe(cancelOnCall: cancelOnCall)
                guard case .unavailable(let reason) = CodexReadClient.read(.quota, executable: executable, home: home,
                    cancelled: { cancellation.isCancelled() }) else { return XCTFail("Annulation attendue") }
                XCTAssertEqual(reason, "lecture annulée")
                XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("launched").path),
                               "Une annulation avant lancement ne doit pas exécuter le CLI")
            }
        }
    }

    func testCancellationAfterLaunchSendsNoInitialize() throws {
        try withServer("""
        : > "$CODEX_HOME/launched"
        while IFS= read -r line; do printf '%s\\n' "$line" >> "$CODEX_HOME/requests"; done
        """) { executable in
            let home = executable.deletingLastPathComponent()
            let cancellation = CancellationProbe(cancelOnCall: 3)
            guard case .unavailable(let reason) = CodexReadClient.read(.quota, executable: executable, home: home,
                cancelled: { cancellation.isCancelled() }) else { return XCTFail("Annulation attendue") }
            XCTAssertEqual(reason, "lecture annulée")
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("launched").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("requests").path))
        }
    }

    func testEOFAllowsCleanupBeforeAnySignal() throws {
        try withServer(handshake + "\n" + """
        trap 'printf term > "$CODEX_HOME/signalled"; exit 9' TERM
        printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
        IFS= read -r line
        printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":37}}}}'
        while IFS= read -r line; do :; done
        /bin/sleep 0.15
        : > "$CODEX_HOME/cleaned"
        """) { executable in
            let home = executable.deletingLastPathComponent()
            guard case .available = CodexReadClient.read(.quota, executable: executable, home: home, timeout: 2) else {
                return XCTFail("Quota attendu")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("cleaned").path),
                          "Le serveur doit disposer d'un délai après l'EOF")
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("signalled").path))
        }
    }

    func testTimeoutEscalatesToKillForAnIdentifiedChildIgnoringEOFAndTerm() throws {
        try withServer("""
        printf '%s' "$$" > "$CODEX_HOME/pid"
        trap 'printf term > "$CODEX_HOME/term"' TERM
        while IFS= read -r line; do :; done
        : > "$CODEX_HOME/eof"
        while :; do :; done
        """) { executable in
            let home = executable.deletingLastPathComponent()
            let started = Date()
            guard case .unavailable = CodexReadClient.read(.quota, executable: executable, home: home, timeout: 0.15) else {
                return XCTFail("Timeout attendu")
            }
            let elapsed = Date().timeIntervalSince(started)
            let pid = try XCTUnwrap(Int32(String(contentsOf: home.appendingPathComponent("pid"))))
            // Filet du test en cas de sabotage du KILL, limité au processus né
            // pendant cette fixture ; jamais un PID étranger ou recyclé.
            let remaining = ProcessIdentity.current(of: pid)
            defer {
                if let remaining, remaining.startedAt >= started.timeIntervalSince1970 {
                    remaining.send(SIGKILL)
                }
            }
            XCTAssertLessThan(elapsed, 2.5, "La fermeture doit rester bornée même si le serveur refuse TERM")
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("eof").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("term").path))
            XCTAssertNil(remaining, "Le processus qui ignore TERM doit être arrêté par KILL")
        }
    }

    func testReadOnlyCataloguesCarryExplicitHomeAndNeverRequestAnAccount() throws {
        for (query, method) in [(CodexReadClient.Query.hooks(cwd: "/fixture/project"), "hooks/list"),
                                (.models(), "model/list"), (.skills(cwd: "/fixture/project"), "skills/list")] {
            try withServer("""
            [ "$CODEX_HOME" = '/fixture/home with spaces' ] || exit 10
            [ "$ATOLL_RETROSPECTIVE" = '1' ] || exit 11
            IFS= read -r line
            printf '%s\\n' '{"id":1,"result":{}}'
            IFS= read -r line
            case "$line" in *'"method":"initialized"'*) ;; *) exit 12;; esac
            IFS= read -r line
            case "$line" in *'"method":"\(method)"'*) ;; *) exit 13;; esac
            printf '%s\\n' '{"id":2,"result":{"data":[]}}'
            """) { executable in
                guard case .available(let data) = CodexReadClient.read(query, executable: executable,
                    home: URL(fileURLWithPath: "/fixture/home with spaces"), timeout: 2) else {
                    return XCTFail("Catalogue \(method) indisponible")
                }
                XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
        }
    }
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
