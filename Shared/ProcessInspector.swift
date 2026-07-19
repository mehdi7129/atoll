import Foundation
import Darwin

/// Inspection de processus via libproc (même utilisateur, aucun privilège requis).
/// Partagé entre l'app et le helper `atoll-bridge` (via le bridging header libproc.h).
enum ProcessInspector {

    static func bsdInfo(for pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func parent(of pid: pid_t) -> pid_t? {
        bsdInfo(for: pid).map { pid_t($0.pbi_ppid) }
    }

    /// Instant de démarrage du processus — combiné au pid, identité robuste
    /// face à la réutilisation de PID.
    static func startTime(of pid: pid_t) -> Double? {
        bsdInfo(for: pid).map { Double($0.pbi_start_tvsec) + Double($0.pbi_start_tvusec) / 1_000_000 }
    }

    /// TTY de contrôle (« ttys012 »), nil pour les processus sans terminal (mode SDK/IDE).
    static func tty(of pid: pid_t) -> String? {
        guard let info = bsdInfo(for: pid) else { return nil }
        let dev = info.e_tdev
        guard dev != 0, dev != UInt32.max else { return nil }
        guard let cname = devname(dev_t(dev), mode_t(S_IFCHR)) else { return nil }
        return String(cString: cname)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        // EPERM = existe mais interdit (autre user) ; ESRCH = n'existe plus.
        return errno != ESRCH
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Le processus est-il le CLI claude ?
    /// PIÈGE vérifié sur cette machine : avec l'installeur natif, proc_name ET
    /// pbi_comm renvoient « 2.1.214 » (basename du binaire versionné dans
    /// ~/.local/share/claude/versions/) — jamais « claude ». Le chemin est le
    /// seul discriminant fiable. (npm/node : non couvert en Phase 2.)
    static func isClaudeProcess(_ pid: pid_t) -> Bool {
        if name(of: pid) == "claude" { return true }
        guard let path = executablePath(of: pid) else { return false }
        if (path as NSString).lastPathComponent == "claude" { return true }
        return path.contains("/claude/versions/")
    }

    /// Remonte la chaîne des parents jusqu'au processus claude (le hook est
    /// un descendant direct du CLI). nil si la chaîne n'en contient pas.
    static func findClaudeAncestor(from pid: pid_t, maxHops: Int = 12) -> pid_t? {
        var current = pid
        for _ in 0..<maxHops {
            if isClaudeProcess(current) { return current }
            guard let parent = parent(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// Tous les processus claude de la machine (réconciliation / découverte hookless).
    static func allClaudePids() -> [pid_t] {
        var byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        byteCount = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids,
            Int32(capacity * MemoryLayout<pid_t>.size)
        )
        guard byteCount > 0 else { return [] }
        let count = Int(byteCount) / MemoryLayout<pid_t>.size
        return pids.prefix(count).filter { $0 > 0 && isClaudeProcess($0) }
    }

    /// Environnement d'un processus du même utilisateur via KERN_PROCARGS2.
    /// Format : [argc int32][exec_path\0][pad\0…][argv…\0][env…\0].
    static func environment(of pid: pid_t) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [:] }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [:] }

        let bytes = buffer.prefix(size)
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            for i in 0..<min(4, bytes.count) { dst[i] = UInt8(bitPattern: buffer[i]) }
        }

        // Segmenter sur les octets nuls, en sautant argc (4 octets) puis exec_path,
        // le padding, et les `argc` arguments.
        var tokens: [String] = []
        var current: [UInt8] = []
        for index in 4..<Int(size) {
            let byte = UInt8(bitPattern: buffer[index])
            if byte == 0 {
                if !current.isEmpty || !tokens.isEmpty {
                    tokens.append(String(decoding: current, as: UTF8.self))
                }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        // tokens = [exec_path, "", "", …, argv0…argvN-1, env0, env1, …]
        // Sauter exec_path + les vides de padding, puis argc arguments.
        var idx = 0
        while idx < tokens.count, tokens[idx].isEmpty { idx += 1 } // exec_path est en tokens[0] non vide en fait
        // exec_path
        if idx < tokens.count { idx += 1 }
        while idx < tokens.count, tokens[idx].isEmpty { idx += 1 } // padding nul
        idx += Int(argc) // sauter les arguments
        var result: [String: String] = [:]
        while idx < tokens.count {
            let token = tokens[idx]
            if let eq = token.firstIndex(of: "=") {
                result[String(token[..<eq])] = String(token[token.index(after: eq)...])
            }
            idx += 1
        }
        return result
    }

    static func currentWorkingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
        }
    }
}
