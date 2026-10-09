#!/usr/bin/env python3
"""Compile l'indexeur réel dans un home synthétique, sans modifier le produit."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import sys

repo = Path(sys.argv[1]).resolve()
build = Path(subprocess.check_output([
    "swift", "build", "--build-system", "native", "--package-path", str(repo / "AtollCore"),
    "--show-bin-path"], text=True).strip())
with tempfile.TemporaryDirectory(prefix="atoll-memory-audit-") as directory:
    root = Path(directory)
    source = root / "Probe.swift"
    source.write_text((repo / "App/MemoryIndexer.swift").read_text() + r'''

// Seulement les chemins de stockage sont remplacés; l'indexeur est inchangé.
private enum BridgePaths {
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_AUDIT_ROOT"]!)
    static var memoryDatabaseURL: URL { root.appendingPathComponent("memory.db") }
    static var claudeProjectsURL: URL { root.appendingPathComponent("projects") }
    static var codexSessionsURL: URL { root.appendingPathComponent("codex-sessions") }
    static var learningNotesDirectory: URL { root.appendingPathComponent("notes") }
}

@main struct MemoryAuditProbe {
    static func rewriteInPlace(_ text: String, at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: 0)
        try file.write(contentsOf: Data(text.utf8))
    }
    static func results() throws -> [String: Int] {
        let index = try MemoryIndex(url: BridgePaths.memoryDatabaseURL, mode: .readOnly)
        defer { index.close() }
        var result = [String: Int]()
        for word in ["ancienalpha", "nouveaubeta", "croissancegamma"] {
            result[word] = try index.search(rawQuery: word, limit: 20, projectPrefix: nil).count
        }
        return result
    }
    static func main() async throws {
        let fm = FileManager.default
        let notes = BridgePaths.learningNotesDirectory
        let project = BridgePaths.claudeProjectsURL.appendingPathComponent("fixture")
        let memory = project.appendingPathComponent("memory")
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        try fm.createDirectory(at: memory, withIntermediateDirectories: true)
        // Un transcript valide court: son cwd ne figure que sur la dernière ligne.
        let transcript = project.appendingPathComponent("fixture.jsonl")
        let content = "{\"type\":\"mode\"}\n{\"type\":\"user\",\"cwd\":\"/fixture/project\",\"message\":{\"content\":\"bonjour\"}}\n"
        try content.write(to: transcript, atomically: true, encoding: .utf8)
        let note = notes.appendingPathComponent("note.md")
        let projectMemory = memory.appendingPathComponent("MEMORY.md")
        for file in [note, projectMemory] { try rewriteInPlace("ancienalpha", at: file) }
        let worker = MemoryIndexWorker()
        await worker.scanAll()
        var stages: [[String: Any]] = [["stage": "initial", "hits": try results()]]
        for file in [note, projectMemory] { try rewriteInPlace("nouveaubeta", at: file) }
        await worker.scanAll()
        stages.append(["stage": "same_inode_same_size", "hits": try results()])
        for file in [note, projectMemory] { try rewriteInPlace("croissancegamma avec du contenu en plus", at: file) }
        await worker.scanAll()
        stages.append(["stage": "same_inode_growing", "hits": try results()])
        let index = try MemoryIndex(url: BridgePaths.memoryDatabaseURL, mode: .readOnly)
        let memories = try index.search(rawQuery: "ancienalpha", limit: 20, projectPrefix: nil, roles: [.memory])
        let scoped = try index.search(rawQuery: "ancienalpha", limit: 20, projectPrefix: "/fixture/project", roles: [.memory])
        let output: [String: Any] = ["stages": stages,
            "project_memory_count": memories.count,
            "project_memory_cwd": memories.first?.projectPath as Any? ?? NSNull(),
            "project_scoped_memory_hits": scoped.count]
        let json = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        index.close()
        await worker.closeIndex()
    }
}
''')
    binary = root / "probe"
    command = ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(build / "Modules"),
               "-lsqlite3", str(source)]
    command += [str(path) for path in sorted((build / "AtollCore.build").glob("*.o"))]
    subprocess.run(command + ["-o", str(binary)], check=True)
    environment = dict(os.environ, ATOLL_AUDIT_ROOT=str(root / "fixture"), CFFIXED_USER_HOME=str(root / "home"))
    result = subprocess.run([str(binary)], env=environment, capture_output=True, text=True, timeout=30)
    print(result.stdout, end="")
    if result.returncode:
        raise RuntimeError(result.stderr)
