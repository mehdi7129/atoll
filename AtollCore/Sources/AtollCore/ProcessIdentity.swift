import Foundation
import Darwin

/// Un PID peut être recyclé ; seul le couple lu dans libproc identifie un run.
public struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public let pid: Int32
    public let startedAt: Double

    public init?(pid: Int32, startedAt: Double) {
        guard pid > 1, startedAt.isFinite, startedAt > 0 else { return nil }
        self.pid = pid
        self.startedAt = startedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let pid = try values.decode(Int32.self, forKey: .pid)
        let start = try values.decode(Double.self, forKey: .startedAt)
        guard let identity = Self(pid: pid, startedAt: start) else {
            throw DecodingError.dataCorruptedError(forKey: .pid, in: values, debugDescription: "Identité de processus invalide")
        }
        self = identity
    }

    /// Une lecture impossible n'autorise jamais un signal vers ce PID.
    public func matches(pid: Int32, startedAt: Double?) -> Bool {
        self.pid == pid && startedAt == self.startedAt
    }

    public static func current(of pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Self(pid: pid, startedAt: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// Réservé aux enfants qu'Atoll vient de lancer. La fenêtre de naissance
    /// est figée AVANT les retries : un PID recyclé ensuite n'est pas adopté.
    public static func launch(_ process: Process) throws -> Self? {
        let before = Date().timeIntervalSince1970
        try process.run()
        let after = Date().timeIntervalSince1970
        return capture(pid: process.processIdentifier, startedBetween: before...max(before, after),
                       isRunning: { process.isRunning })
    }

    public static func capture(pid: Int32, startedBetween: ClosedRange<Double>,
                               isRunning: () -> Bool, read: (Int32) -> Self? = Self.current,
                               pause: () -> Void = { Thread.sleep(forTimeInterval: 0.002) }) -> Self? {
        for attempt in 0..<3 {
            guard isRunning() else { return nil }
            if let identity = read(pid) {
                guard identity.pid == pid, startedBetween.contains(identity.startedAt), isRunning() else { return nil }
                return identity
            }
            if attempt < 2 { pause() }
        }
        return nil
    }

    @discardableResult
    public func send(_ signal: Int32) -> Bool {
        guard Self.current(of: pid) == self else { return false }
        return kill(pid, signal) == 0
    }
}
