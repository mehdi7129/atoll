import XCTest
import Darwin
@testable import AtollCore

final class ProcessIdentityTests: XCTestCase {
    func testSignalRejectsSamePIDWithWrongStartTime() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let identity = try XCTUnwrap(ProcessIdentity.current(of: process.processIdentifier))
        let foreign = try XCTUnwrap(ProcessIdentity(pid: identity.pid, startedAt: identity.startedAt - 1))
        XCTAssertFalse(foreign.send(SIGTERM))
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(identity.send(SIGTERM))
        process.waitUntilExit()
        XCTAssertFalse(identity.send(SIGTERM))
    }
}
