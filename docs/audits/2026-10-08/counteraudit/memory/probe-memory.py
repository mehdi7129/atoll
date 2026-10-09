#!/usr/bin/env python3
"""Indexeur source intact, BridgePaths isolé ; aucun CLI produit ni préférence."""
from pathlib import Path
import argparse, json, os, sqlite3, subprocess
p = argparse.ArgumentParser()
p.add_argument('--repo', type=Path, required=True)
p.add_argument('--build-dir', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.repo, a.build_dir, a.output = a.repo.resolve(), a.build_dir.resolve(), a.output.resolve()
a.output.mkdir(parents=True, exist_ok=False)
source = a.output / 'Probe.swift'
source.write_text((a.repo / 'App/MemoryIndexer.swift').read_text() + r'''
private enum BridgePaths {
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_AUDIT_ROOT"]!)
    static var memoryDatabaseURL: URL { root.appendingPathComponent("memory.db") }
    static var claudeProjectsURL: URL { root.appendingPathComponent("projects") }
    static var codexSessionsURL: URL { root.appendingPathComponent("codex-sessions") }
    static var learningNotesDirectory: URL { root.appendingPathComponent("notes") }
}
@main struct MemoryCounterProbe {
    static func hits(_ word: String) throws -> Int {
        let index = try MemoryIndex(url: BridgePaths.memoryDatabaseURL, mode: .readOnly)
        defer { index.close() }
        return try index.search(rawQuery: word, limit: 100, projectPrefix: nil).count
    }
    static func rewrite(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }
    static func main() async throws {
        let fm = FileManager.default
        let project = BridgePaths.claudeProjectsURL.appendingPathComponent("fixture")
        let memoryDirectory = project.appendingPathComponent("memory")
        try fm.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        let memory = memoryDirectory.appendingPathComponent("MEMORY.md")
        try "staletextmarker longue description".write(to: memory, atomically: true, encoding: .utf8)
        let transcript = project.appendingPathComponent("unreadable.jsonl")
        try #"{"type":"user","uuid":"fixture","cwd":"/fixture/project","message":{"content":"permissionrecoveredtoken"}}"#.appending("\n").write(to: transcript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: transcript.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path) }
        let unreadable = FileHandle(forReadingAtPath: transcript.path) == nil
        let before = try fm.attributesOfItem(atPath: transcript.path)
        let worker = MemoryIndexWorker()
        await worker.scanAll()
        let beforeAccess = try hits("permissionrecoveredtoken")
        let initialMemory = try hits("staletextmarker")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path)
        let after = try fm.attributesOfItem(atPath: transcript.path)
        await worker.scanAll()
        let afterAccess = try hits("permissionrecoveredtoken")
        await worker.indexFiles([transcript.path])
        let afterNudge = try hits("permissionrecoveredtoken")
        // Contrôle : une variation mtime suffit à sortir de la cache erronée.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: transcript.path)
        await worker.scanAll()
        let afterMtimeChange = try hits("permissionrecoveredtoken")
        // Contrôle : réduction non vide dans le même inode fonctionne.
        try rewrite("reducedmarker", to: memory)
        await worker.scanAll()
        let reduced = try hits("reducedmarker")
        let oldAfterReduced = try hits("staletextmarker")
        // Édition vide : l'ancien contenu ne devrait plus être cherché.
        try rewrite("", to: memory)
        await worker.scanAll()
        let emptySameInode = try hits("reducedmarker")
        // Même cas avec inode neuf : ne relève pas de la seule détection des offsets.
        try "".write(to: memory, atomically: true, encoding: .utf8)
        await worker.scanAll()
        let emptyNewInode = try hits("reducedmarker")
        try "   \n\n".write(to: memory, atomically: true, encoding: .utf8)
        await worker.scanAll()
        let whitespace = try hits("reducedmarker")
        await worker.closeIndex()
        await worker.scanAll()
        let afterWorkerReset = try hits("permissionrecoveredtoken")
        let whitespaceAfterReset = try hits("reducedmarker")
        // Vraie disparition : le transcript est marqué missing, ses messages restent.
        try fm.removeItem(at: transcript)
        await worker.scanAll()
        let hitsAfterRemoval = try hits("permissionrecoveredtoken")
        await worker.closeIndex()
        let result: [String: Any] = [
            "permission": ["access_really_denied": unreadable,
                "same_inode": (before[.systemFileNumber] as? UInt64) == (after[.systemFileNumber] as? UInt64),
                "same_mtime": (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date),
                "same_size": (before[.size] as? Int64) == (after[.size] as? Int64),
                "hits_before_restoration": beforeAccess, "hits_after_restoration_scan": afterAccess,
                "hits_after_nudge": afterNudge, "hits_after_mtime_change": afterMtimeChange,
                "hits_after_worker_reset": afterWorkerReset, "hits_after_real_removal": hitsAfterRemoval],
            "empty_memory": ["initial_hits": initialMemory, "reduced_nonempty_hits": reduced,
                "old_hits_after_reduction": oldAfterReduced,
                "stale_hits_after_empty_same_inode": emptySameInode,
                "stale_hits_after_empty_new_inode": emptyNewInode,
                "stale_hits_after_whitespace": whitespace,
                "stale_hits_after_worker_reset": whitespaceAfterReset]]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
''')
objects = sorted((a.build_dir / 'AtollCore.build').glob('*.o'))
assert objects, 'Objets Core existants requis'
command = ['swiftc', '-swift-version', '5', '-parse-as-library', '-I', str(a.build_dir / 'Modules'), '-lsqlite3', str(source), *map(str, objects), '-o', str(a.output / 'probe')]
(a.output / 'compile-command.json').write_text(json.dumps(command, indent=2))
compiled = subprocess.run(command, capture_output=True, text=True)
(a.output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
compiled.check_returncode()
result = subprocess.run([str(a.output / 'probe')], env=dict(os.environ, ATOLL_AUDIT_ROOT=str(a.output / 'fixture')), capture_output=True, text=True, timeout=30)
(a.output / 'stderr.txt').write_text(result.stderr)
result.check_returncode()
observed = json.loads(result.stdout)
with sqlite3.connect(f"file:{a.output / 'fixture/memory.db'}?mode=ro", uri=True) as db:
    rows = db.execute('SELECT missing FROM files WHERE path = ?', (str(a.output / 'fixture/projects/fixture/unreadable.jsonl'),)).fetchall()
observed['permission']['real_removal_marked_missing'] = rows == [(1,)]
(a.output / 'result.json').write_text(json.dumps(observed, indent=2) + '\n')
print(json.dumps(observed, indent=2))
