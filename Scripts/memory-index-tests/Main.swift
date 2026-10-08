import SQLite3

private enum ProbeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case let .failed(message): return message } }
}

// Couture réservée au harness : le worker compilé garde son contrôle de flux,
// les FileHandle réels restent utilisés sauf pour l'exception ciblée demandée.
private final class MemoryTestHandle {
    static var fault = ""
    static var failReadAfter = 0
    static var readCount = 0
    private let handle: FileHandle
    init?(path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = handle
    }
    func seek(toOffset offset: UInt64) throws {
        if Self.fault == "seek" { throw ProbeFailure.failed("injected seek") }
        try handle.seek(toOffset: offset)
    }
    func read(upToCount count: Int) throws -> Data? {
        defer { Self.readCount += 1 }
        if Self.fault == "read", Self.readCount >= Self.failReadAfter {
            throw ProbeFailure.failed("injected read")
        }
        return try handle.read(upToCount: count)
    }
    func close() throws { try handle.close() }
}

@main private struct MemoryProbe {
    static let fm = FileManager.default
    static var passed: [String] = []
    static var reader: MemoryIndex!
    static var worker = MemoryIndexWorker()
    static var root: URL!

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw ProbeFailure.failed(message) }
    }
    static func write(_ text: String, to url: URL, atomic: Bool = false) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: atomic ? .atomic : [])
    }
    static func hit(_ token: String, prefix: String? = nil) throws -> Int {
        try reader.search(rawQuery: token, limit: 100, projectPrefix: prefix).count
    }
    static func sql(_ statement: String) throws -> Int64 {
        var db: OpaquePointer?
        try check(sqlite3_open(BridgePaths.memoryDatabaseURL.path, &db) == SQLITE_OK, "sqlite open")
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(db, statement, -1, &stmt, nil) == SQLITE_OK, "sqlite prepare")
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        try check(result == SQLITE_ROW || result == SQLITE_DONE, "sqlite step")
        return result == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }
    static func line(_ token: String) -> String {
        "{\"type\":\"user\",\"uuid\":\"\(token)\",\"message\":{\"role\":\"user\",\"content\":\"\(token)\"}}\n"
    }
    static func scan() async { await worker.scanAll() }

    static func markdown() async throws {
        for kind in ["note", "memory"] {
            let url = kind == "note"
                ? BridgePaths.learningNotesDirectory.appendingPathComponent("fixture.md")
                : BridgePaths.claudeProjectsURL.appendingPathComponent("fixture/memory/fixture.md")
            let previous = "\(kind)oldtoken"
            try write(previous, to: url)
            await scan()
            try check(hit(previous) == 1, "Markdown initial absent")
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let equal = "\(kind)newtoken"
            try write(equal, to: url)
            try fm.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: url.path)
            let same = try fm.attributesOfItem(atPath: url.path)
            try check((same[.systemFileNumber] as? UInt64) == (attrs[.systemFileNumber] as? UInt64)
                      && (same[.size] as? Int64) == (attrs[.size] as? Int64), "fixture same metadata")
            await scan()
            try check(hit(equal) == 1 && hit(previous) == 0, "Markdown equal-size replacement stale")
            passed.append("\(kind): equal-size same-inode same-mtime")
            var old = equal
            for (token, text, atomic) in [("\(kind)growthtoken", "\(kind)growthtoken plus more contents", false),
                                         ("\(kind)short", "\(kind)short", false),
                                         ("\(kind)atomictoken", "\(kind)atomictoken replaced", true)] {
                try write(text, to: url, atomic: atomic)
                await scan()
                try check(hit(token) == 1 && hit(old) == 0, "Markdown resized replacement stale")
                old = token
                passed.append("\(kind): \(token)")
            }
            let count = try sql("SELECT COUNT(*) FROM messages")
            _ = try sql("CREATE TRIGGER unchanged_guard BEFORE DELETE ON messages BEGIN SELECT RAISE(ABORT, 'unexpected rewrite'); END")
            await worker.closeIndex()
            await scan()
            try check(sql("SELECT COUNT(*) FROM messages") == count && hit(old) == 1, "unchanged document changed")
            _ = try sql("DROP TRIGGER unchanged_guard")
            passed.append("\(kind): unchanged after reopen")
            // UTF-8 invalide : lecture refusée, jamais interprétée comme du vide.
            try Data([0xff, 0xfe]).write(to: url)
            await scan()
            try check(hit(old) == 1, "Markdown failed read erased content")
            passed.append("\(kind): read failure retained")
            for (text, atomic) in [("", false), (" \n\t", false), ("", true), (" \n\t", true)] {
                try write("\(kind)erasetoken", to: url)
                await scan()
                try write(text, to: url, atomic: atomic)
                await worker.closeIndex()
                await scan()
                try check(hit("\(kind)erasetoken") == 0, "Markdown empty document stale")
                passed.append("\(kind): empty=\(text.isEmpty) atomic=\(atomic)")
            }
            try write("\(kind)rollbacktoken", to: url)
            await scan()
            try write("\(kind)recoveredtoken", to: url)
            _ = try sql("CREATE TRIGGER write_fault BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'injected write'); END")
            await scan()
            try check(hit("\(kind)rollbacktoken") == 1 && hit("\(kind)recoveredtoken") == 0, "document transaction lost original")
            _ = try sql("DROP TRIGGER write_fault")
            await scan()
            try check(hit("\(kind)rollbacktoken") == 0 && hit("\(kind)recoveredtoken") == 1, "document transaction not retried")
            passed.append("\(kind): transaction rollback and retry")
        }
    }

    static func cwd() async throws {
        let cap = 256 * 1024
        for scenario in ["newline", "incomplete", "atcap", "beyondcap", "earlier"] {
            let directory = BridgePaths.claudeProjectsURL.appendingPathComponent("cwd-\(scenario)")
            let memory = directory.appendingPathComponent("memory/fixture.md")
            let token = "cwd\(scenario)token"
            let record = "{\"cwd\":\"/project/\(scenario)\"}\n"
            let head: String
            switch scenario {
            case "newline": head = "{\"type\":\"mode\"}\n" + record
            case "incomplete": head = String(record.dropLast())
            case "atcap": head = String(repeating: " ", count: cap - record.utf8.count - 1) + "\n" + record
            case "beyondcap": head = String(repeating: " ", count: cap - 5) + "\n" + record
            default: head = record + "{\"type\":"
            }
            try write(head, to: directory.appendingPathComponent("session.jsonl"))
            try write(token, to: memory)
            await scan()
            let expected = ["incomplete", "beyondcap"].contains(scenario) ? 0 : 1
            try check(hit(token) == 1, "cwd corpus absent")
            try check(hit(token, prefix: "/project/\(scenario)") == expected, "cwd complete-line boundary wrong: \(scenario)")
            passed.append("cwd: \(scenario)")
        }
    }

    static func retries() async throws {
        for trigger in ["scan", "nudge"] {
            for fault in ["open", "seek", "read"] {
                let token = "\(trigger)\(fault)retrytoken"
                let url = BridgePaths.claudeProjectsURL.appendingPathComponent("retries/\(token).jsonl")
                let original = "\(trigger)\(fault)originaltoken"
                try write(line(original), to: url)
                await worker.indexFiles([url.path])
                let before = try sql("SELECT offset FROM files WHERE path = '\(url.path)'")
                try write(line(original) + line(token), to: url)
                let attrs = try fm.attributesOfItem(atPath: url.path)
                if fault == "open" { try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path) }
                else { MemoryTestHandle.fault = fault; MemoryTestHandle.readCount = 0 }
                if trigger == "scan" { await scan() } else { await worker.indexFiles([url.path]) }
                try check(hit(original) == 1 && hit(token) == 0, "fault fixture did not fail")
                try check(sql("SELECT offset FROM files WHERE path = '\(url.path)'") == before, "read fault advanced offset")
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                MemoryTestHandle.fault = ""
                let repaired = try fm.attributesOfItem(atPath: url.path)
                try check((attrs[.systemFileNumber] as? UInt64) == (repaired[.systemFileNumber] as? UInt64)
                          && (attrs[.size] as? Int64) == (repaired[.size] as? Int64)
                          && (attrs[.modificationDate] as? Date) == (repaired[.modificationDate] as? Date), "retry fixture metadata changed")
                if trigger == "scan" { await scan() } else { await worker.indexFiles([url.path]) }
                try check(hit(token) == 1, "\(fault) failure never retried by \(trigger)")
                let after = try sql("SELECT mtime FROM files WHERE path = '\(url.path)'")
                await worker.indexFiles([url.path])
                let repeatedCount = try hit(token)
                let repeatedTime = try sql("SELECT mtime FROM files WHERE path = '\(url.path)'")
                try check(repeatedCount == 1 && repeatedTime == after, "successful retry reingested: \(token) count=\(repeatedCount) before=\(after) after=\(repeatedTime)")
                passed.append("\(trigger): \(fault) failure retries unchanged metadata")
            }
        }
        for fault in ["open", "seek", "read"] {
            let url = BridgePaths.claudeProjectsURL.appendingPathComponent("retries/rotated-\(fault).jsonl")
            try write(line("oldrotated\(fault)token"), to: url)
            await worker.indexFiles([url.path])
            let offset = try sql("SELECT offset FROM files WHERE path = '\(url.path)'")
            try write(line("newrotated\(fault)token"), to: url, atomic: true)
            if fault == "open" { try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path) }
            else { MemoryTestHandle.fault = fault; MemoryTestHandle.readCount = 0 }
            await worker.indexFiles([url.path])
            try check(hit("oldrotated\(fault)token") == 1, "rotated read failure purged original")
            try check(sql("SELECT offset FROM files WHERE path = '\(url.path)'") == offset, "rotated read failure reset offset")
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            MemoryTestHandle.fault = ""
            await worker.indexFiles([url.path])
            try check(hit("oldrotated\(fault)token") == 0 && hit("newrotated\(fault)token") == 1, "rotated retry failed")
            passed.append("JSONL: rotation plus \(fault) failure preserves old version")
        }
        let url = BridgePaths.claudeProjectsURL.appendingPathComponent("retries/historic.jsonl")
        try write(line("historictoken"), to: url)
        await scan()
        try fm.removeItem(at: url)
        await scan()
        try check(hit("historictoken") == 1, "deleted transcript history erased")
        try check(sql("SELECT missing FROM files WHERE path = '\(url.path)'") == 1, "deleted transcript not marked")
        passed.append("history: missing transcript retained")

        let batches = BridgePaths.claudeProjectsURL.appendingPathComponent("retries/batches.jsonl")
        let first = (0..<500).map { line("firstbatchtoken\($0)") }.joined()
        let second = (0..<501).map { line("secondbatchtoken\($0)") }.joined()
        try write(first + second, to: batches)
        _ = try sql("CREATE TRIGGER batch_fault BEFORE INSERT ON messages WHEN NEW.uuid = 'secondbatchtoken0' BEGIN SELECT RAISE(ABORT, 'injected batch'); END")
        await worker.indexFiles([batches.path])
        try check(hit("firstbatchtoken0") == 1 && hit("secondbatchtoken0") == 0, "batch fault not exercised")
        _ = try sql("DROP TRIGGER batch_fault")
        await worker.indexFiles([batches.path])
        try check(hit("secondbatchtoken0") == 1 && hit("secondbatchtoken500") == 1, "failed batch skipped remaining lines")
        try check(sql("SELECT COUNT(*) FROM messages m JOIN files f ON f.id = m.file_id WHERE f.path = '\(batches.path)'") == 1001, "batch recovery duplicate or missing")
        passed.append("JSONL: failed later batch preserves exact resume offset")

        let lateRead = BridgePaths.claudeProjectsURL.appendingPathComponent("retries/late-read.jsonl")
        let huge = (0..<600).map { number in
            line("latereadtoken\(number)").replacingOccurrences(of: "\"content\":\"", with: "\"content\":\"" + String(repeating: "padding ", count: 1024))
        }.joined()
        try write(huge, to: lateRead)
        MemoryTestHandle.fault = "read"
        MemoryTestHandle.readCount = 0
        MemoryTestHandle.failReadAfter = 1
        await worker.indexFiles([lateRead.path])
        let committed = try sql("SELECT offset FROM files WHERE path = '\(lateRead.path)'")
        try check(committed > 0 && committed < huge.utf8.count, "late read failure not exercised")
        MemoryTestHandle.fault = ""
        MemoryTestHandle.failReadAfter = 0
        await worker.indexFiles([lateRead.path])
        try check(sql("SELECT COUNT(*) FROM messages m JOIN files f ON f.id = m.file_id WHERE f.path = '\(lateRead.path)'") == 600, "late read retry lost or duplicated messages")
        try check(hit("latereadtoken599") == 1, "late read retry tail absent")
        passed.append("JSONL: late read resumes from last committed batch")

        let partial = BridgePaths.claudeProjectsURL.appendingPathComponent("retries/partial.jsonl")
        let text = line("partialtoken")
        try write(String(text.dropLast()), to: partial)
        await scan()
        try check(hit("partialtoken") == 0, "partial line indexed prematurely")
        try write(text, to: partial)
        await worker.indexFiles([partial.path])
        try check(hit("partialtoken") == 1, "partial line not resumed")
        passed.append("JSONL: partial tail resumed")
    }

    static func main() async {
        do {
            root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
            try check(BridgePaths.homeDirectory.resolvingSymlinksInPath() == root, "Foundation home not isolated")
            try check(BridgePaths.codexSessionsURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"), "Codex home not isolated")
            await scan()
            reader = try MemoryIndex(url: BridgePaths.memoryDatabaseURL, mode: .readOnly)
            try await markdown()
            try await cwd()
            try await retries()
            reader.close()
            await worker.closeIndex()
            let data = try JSONSerialization.data(withJSONObject: ["passed": passed, "count": passed.count], options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
