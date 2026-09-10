import Foundation

/// Provenance transitive des notes. Les noms historiques ambigus ne servent
/// jamais à inventer une session ; les nouvelles références portent un hash.
public enum NoteProvenance {
    public struct Reference: Codable, Equatable, Sendable {
        public let file: String
        public let sha256: String
    }

    public static func references(for sources: [String], existing: [(name: String, content: String)]) -> String {
        let byName = Dictionary(existing.map { ($0.name, $0.content) }, uniquingKeysWith: { first, _ in first })
        let refs = sources.sorted().compactMap { name -> Reference? in
            guard let content = byName[name] else { return nil }
            return Reference(file: name, sha256: InstalledSkillsManifest.sha256(content))
        }
        return json(refs)
    }

    public static func sessions(for sources: [String], existing: [(name: String, content: String)],
                                archives: [(name: String, content: String)] = []) -> [String] {
        let active = Dictionary(existing.map { ($0.name, $0.content) }, uniquingKeysWith: { first, _ in first })
        let historical = Dictionary(grouping: archives + existing, by: \.name)
        func resolve(_ text: String, visited: Set<String>, depth: Int) -> Set<String> {
            let hash = InstalledSkillsManifest.sha256(text)
            guard depth < 12, !visited.contains(hash) else { return [] }
            let fields = LearningInventory.splitFrontMatter(text).fields
            var found = Set((fields["source_session"].map { [$0] } ?? [])
                + decode([String].self, fields["source_sessions"], fallback: []))
            let refs = decode([Reference].self, fields["source_notes"], fallback: [])
            let names = fields["source_notes"] == nil ? legacySources(in: text) : refs.map(\.file)
            for name in names.prefix(40) {
                let expected = refs.first { $0.file == name }?.sha256
                let candidates = Set((historical[name] ?? []).map(\.content).filter {
                    expected == nil || InstalledSkillsManifest.sha256($0) == expected
                })
                // Deux anciennes notes homonymes ne prouvent aucune filiation.
                guard candidates.count == 1, let source = candidates.first else { continue }
                found.formUnion(resolve(source, visited: visited.union([hash]), depth: depth + 1))
            }
            return found.filter { !$0.isEmpty }
        }
        return sources.reduce(into: Set<String>()) { result, name in
            if let content = active[name] { result.formUnion(resolve(content, visited: [], depth: 0)) }
        }.sorted()
    }

    public static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Archives écrites par Atoll uniquement ; lecture bornée, aucune mutation.
    public static func readArchives(at root: URL) -> [(name: String, content: String)] {
        let fm = FileManager.default
        let directories = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        var result: [(String, String)] = []
        var bytes = 0
        let archives = directories.filter {
            $0.lastPathComponent.hasPrefix("notes-") &&
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
        }
        for directory in archives.sorted(by: { $0.path > $1.path }).prefix(32) {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
            for file in files where file.pathExtension == "md" {
                guard result.count < 2_000, bytes < 16_777_216 else { return result }
                guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                      let data = BoundedProcessOutput.file(at: file, cap: 524_288),
                      let text = String(data: data, encoding: .utf8) else { continue }
                bytes += data.count
                result.append((file.lastPathComponent, text))
            }
        }
        return result
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String?, fallback: T) -> T {
        text.flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) } ?? fallback
    }

    private static func legacySources(in text: String) -> [String] {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [] }
        var collecting = false
        var result: [String] = []
        for line in lines[1..<end] {
            if line == "sources:" { collecting = true; continue }
            if !line.hasPrefix(" ") { collecting = false }
            guard collecting, line.hasPrefix("  - ") else { continue }
            let value = String(line.dropFirst(4))
            result.append(decode(String.self, value, fallback: value))
        }
        return result
    }
}
