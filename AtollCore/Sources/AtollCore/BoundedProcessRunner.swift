import Foundation
import Darwin

/// Un seul délai pour le processus et ses pipes. Un descendant gardant un pipe
/// ouvert ne peut pas prolonger indéfiniment la lecture après la fin du parent.
public enum BoundedProcessRunner {
    public struct Result: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let status: Int32?
        public let timedOut: Bool
        public let cancelled: Bool
        public let stdoutOverflowed: Bool
        public var succeeded: Bool { status == 0 && !timedOut && !cancelled && !stdoutOverflowed }
    }

    public static func remaining(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let value = ContinuousClock.now.duration(to: deadline).components
        return max(0, Double(value.seconds) + Double(value.attoseconds) / 1e18)
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    public static func run(_ process: Process, timeout: TimeInterval,
                           stdoutCap: Int = 4 * 1024 * 1024, stderrCap: Int = 2000,
                           stderrTail: Bool = true, terminationGrace: TimeInterval = 1) async throws -> Result {
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw CancellationError() }
                let identity = try ProcessIdentity.launch(process)
                return drain(process: process, stdout: stdout, stderr: stderr, identity: identity,
                             deadline: deadline, stdoutCap: stdoutCap, stderrCap: stderrCap,
                             stderrTail: stderrTail, terminationGrace: terminationGrace,
                             cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    /// Pour les services qui doivent journaliser la dépense juste avant le spawn,
    /// sans await entre leur préparation et ProcessIdentity.launch.
    public static func collect(process: Process, stdout: Pipe, stderr: Pipe,
                               identity: ProcessIdentity?, deadline: ContinuousClock.Instant,
                               stdoutCap: Int, stderrCap: Int, stderrTail: Bool = true,
                               terminationGrace: TimeInterval = 1) async -> Result {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                drain(process: process, stdout: stdout, stderr: stderr, identity: identity,
                      deadline: deadline, stdoutCap: stdoutCap, stderrCap: stderrCap,
                      stderrTail: stderrTail, terminationGrace: terminationGrace,
                      cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func drain(process: Process, stdout: Pipe, stderr: Pipe,
                              identity: ProcessIdentity?, deadline: ContinuousClock.Instant,
                              stdoutCap: Int, stderrCap: Int, stderrTail: Bool,
                              terminationGrace: TimeInterval, cancellation: Cancellation) -> Result {
        let handles = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        let descriptors = handles.map(\.fileDescriptor)
        // Process a transmis les extrémités d'écriture à l'enfant ; nos copies
        // ne doivent pas empêcher EOF. Seule cette tâche ferme les lecteurs.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        defer { handles.forEach { try? $0.close() } }
        for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var collected = [Data(), Data()]
        var open = [true, true]
        var overflowed = false
        var timedOut = false
        var stoppedAt: ContinuousClock.Instant?
        var exitedAt: ContinuousClock.Instant?
        var sentKill = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let now = ContinuousClock.now
            let running = process.isRunning
            if !running, exitedAt == nil { exitedAt = now }
            if stoppedAt == nil, cancellation.isCancelled || now >= deadline {
                timedOut = !cancellation.isCancelled
                stoppedAt = now
                if running, let identity { identity.send(SIGTERM) }
            }
            if let stoppedAt, now >= stoppedAt.advanced(by: .seconds(max(0, terminationGrace))), !sentKill {
                // send relit l'identité avant CHAQUE signal, même après TERM.
                if running, let identity { identity.send(SIGKILL) }
                sentKill = true
            }
            for index in 0..<2 where open[index] {
                // Quota de lecture par tour : un écrivain continu ne doit pas
                // affamer le contrôle du délai ni l'autre pipe.
                for _ in 0..<16 {
                    let count = Darwin.read(descriptors[index], &buffer, buffer.count)
                    if count > 0 {
                        let cap = max(0, index == 0 ? stdoutCap : stderrCap)
                        if index == 1, stderrTail {
                            collected[index].append(contentsOf: buffer.prefix(count))
                            if collected[index].count > cap { collected[index] = Data(collected[index].suffix(cap)) }
                        } else {
                            if index == 0, count > cap - collected[index].count { overflowed = true }
                            collected[index].append(contentsOf: buffer.prefix(min(count, max(0, cap - collected[index].count))))
                        }
                    } else if count == 0 {
                        open[index] = false
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        if errno != EAGAIN && errno != EWOULDBLOCK { open[index] = false }
                        break
                    }
                }
            }
            if !running && !open.contains(true) { break }
            // Après sortie du parent, ne pas attendre l'EOF d'un descendant.
            if let exitedAt, now >= exitedAt.advanced(by: .milliseconds(200)) {
                timedOut = open.contains(true)
                break
            }
            if let stoppedAt, now >= stoppedAt.advanced(by: .seconds(max(0, terminationGrace) + 0.2)) { break }
            var polls = descriptors.enumerated().map {
                pollfd(fd: open[$0.offset] ? $0.element : -1, events: Int16(POLLIN | POLLHUP), revents: 0)
            }
            _ = poll(&polls, nfds_t(polls.count), 20)
        }
        return Result(stdout: collected[0], stderr: collected[1],
                      status: process.isRunning ? nil : process.terminationStatus,
                      timedOut: timedOut, cancelled: cancellation.isCancelled,
                      stdoutOverflowed: overflowed)
    }
}
