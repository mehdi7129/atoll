import XCTest
import Darwin
@testable import AtollCore

final class ProcessIdentityTests: XCTestCase {
    func testCaptureRetriesTransientFailureWithoutAdoptingRecycledPID() {
        var reads = 0
        var pauses = 0
        let expected = ProcessIdentity(pid: 42, startedAt: 100)!
        let captured = ProcessIdentity.capture(pid: 42, startedBetween: 99...101, isRunning: { true }, read: { _ in
            reads += 1
            return reads == 3 ? expected : nil
        }, pause: { pauses += 1 })
        XCTAssertEqual(captured, expected)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(pauses, 2)
        XCTAssertNil(ProcessIdentity.capture(pid: 42, startedBetween: 99...101, isRunning: { true },
            read: { _ in ProcessIdentity(pid: 42, startedAt: 102) }, pause: {}))
        XCTAssertNil(ProcessIdentity.capture(pid: 42, startedBetween: 99...101, isRunning: { false },
            read: { _ in XCTFail("Enfant déjà sorti : aucune nouvelle sonde"); return expected }, pause: {}))
        reads = 0
        XCTAssertNil(ProcessIdentity.capture(pid: 42, startedBetween: 99...101, isRunning: { true },
            read: { _ in reads += 1; return nil }, pause: {}))
        XCTAssertEqual(reads, 3)
    }

    func testSignalRejectsSamePIDWithWrongStartTime() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let captured = try ProcessIdentity.launch(process)
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let identity = try XCTUnwrap(ProcessIdentity.current(of: process.processIdentifier))
        XCTAssertEqual(captured, identity)
        let foreign = try XCTUnwrap(ProcessIdentity(pid: identity.pid, startedAt: identity.startedAt - 1))
        XCTAssertFalse(foreign.send(SIGTERM))
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(identity.send(SIGTERM))
        process.waitUntilExit()
        XCTAssertFalse(identity.send(SIGTERM))
    }
}
