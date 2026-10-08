import XCTest
import Darwin
@testable import AtollCore

final class BoundedProcessRunnerTests: XCTestCase {
    private func python(_ code: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", code]
        process.standardInput = FileHandle.nullDevice
        return process
    }

    func testNominalSuccessAndFailureKeepBothStreams() async throws {
        for status in [0, 7] {
            let result = try await BoundedProcessRunner.run(python("import os; os.write(1,b'out'); os.write(2,b'err'); exit(\(status))"), timeout: 3)
            XCTAssertEqual(result.status, Int32(status))
            XCTAssertEqual(result.succeeded, status == 0)
            XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out")
            XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err")
        }
    }

    func testParentExitCannotLeaveDrainWaitingOnSilentDescendant() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await BoundedProcessRunner.run(python("import os,time; p=os.fork(); time.sleep(1.5) if p==0 else None; os._exit(0)"), timeout: 3)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1), "A09 inherited pipe exceeded post-exit bound")
        XCTAssertTrue(result.timedOut, "A09 unfinished drain accepted")
        XCTAssertFalse(result.succeeded)
    }

    func testParallelLargeStreamsAreDrainedWithStrictCaps() async throws {
        let code = "import os,threading; t=threading.Thread(target=lambda:os.write(2,b'e'*2000000)); t.start(); os.write(1,b'o'*2000000); t.join()"
        let result = try await BoundedProcessRunner.run(python(code), timeout: 3, stdoutCap: 1024, stderrCap: 63)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.stdoutOverflowed)
        XCTAssertEqual(result.stdout, Data(repeating: 111, count: 1024))
        XCTAssertEqual(result.stderr, Data(repeating: 101, count: 63))
    }

    func testTermIgnoredEscalatesAndReturnsWithinDeadline() async throws {
        let process = python("import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(20)")
        let start = ContinuousClock.now
        let result = try await BoundedProcessRunner.run(process, timeout: 0.3, terminationGrace: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(process.isRunning, "A09 unbounded process after escalation")
        XCTAssertLessThan(start.duration(to: .now), .seconds(1.5))
    }

    func testCancellationReachesDetachedCollector() async throws {
        let process = python("import time; time.sleep(20)")
        let task = Task { try await BoundedProcessRunner.run(process, timeout: 20, terminationGrace: 0.1) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.cancelled, "A09 detached collector ignored cancellation")
        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(result.succeeded)
    }

    func testEachSignalRechecksIdentityIncludingEscalation() throws {
        let identity = try XCTUnwrap(ProcessIdentity(pid: 123, startedAt: 10))
        var observed: ProcessIdentity? = identity
        var signals: [Int32] = []
        let deliver: (Int32, Int32) -> Int32 = { _, value in signals.append(value); return 0 }
        XCTAssertTrue(identity.send(SIGTERM, read: { _ in observed }, deliver: deliver))
        observed = ProcessIdentity(pid: 123, startedAt: 11)
        XCTAssertFalse(identity.send(SIGKILL, read: { _ in observed }, deliver: deliver), "A11 recycled PID signalled")
        observed = nil
        XCTAssertFalse(identity.send(SIGKILL, read: { _ in observed }, deliver: deliver), "A11 unreadable identity signalled")
        XCTAssertEqual(signals, [SIGTERM])
    }
}
