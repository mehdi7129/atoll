import Foundation
import AtollCore

@main struct Probe {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("atoll-archive-counterprobe-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var results: [[String: Any]] = []
        for blocked in [false, true] {
            let base = root.appendingPathComponent(blocked ? "blocked" : "control")
            let learning = base.appendingPathComponent("learning")
            let skills = base.appendingPathComponent("skills")
            let proposal = learning.appendingPathComponent("proposed/probe")
            try fm.createDirectory(at: proposal, withIntermediateDirectories: true)
            let meta = #"{"v":1,"slug":"probe","title":"Fixture","description":"Fixture","rationale":"","source_session":"synthetic","project":"/fixture","created_at":"2026-07-20T18:00:00Z","status":"proposed","flags":[]}"#
            try Data(meta.utf8).write(to: proposal.appendingPathComponent("meta.json"))
            try Data("# original proposal".utf8).write(to: proposal.appendingPathComponent("SKILL.md"))
            let store = LearnedSkillStore(learningRoot: learning, skillsRoot: skills)
            guard let offered = store.discoverProposals().first else { fatalError("Missing fixture proposal") }
            try store.approve(offered)
            let installed = skills.appendingPathComponent("atoll-probe")
            let unique = "USER_RESOURCE_ONLY_IN_INSTALLED_SKILL"
            try Data(unique.utf8).write(to: installed.appendingPathComponent("private-reference.md"))
            let archive = learning.appendingPathComponent("archive/uninstalled")
            if blocked { try Data("Parent is a regular file, so archive creation fails".utf8).write(to: archive) }
            var error: String? = nil
            do { try store.archiveInstalled(slug: "probe") } catch let caught { error = caught.localizedDescription }
            let descendants = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])
            var preservedCopies = 0
            while let url = descendants?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if (try? String(contentsOf: url, encoding: .utf8)) == unique { preservedCopies += 1 }
            }
            results.append([
                "fixture": blocked ? "archive_parent_regular_file" : "control",
                "call_threw": error != nil,
                "installed_directory_exists": fm.fileExists(atPath: installed.path),
                "manifest_entry_count": store.installedSkills().count,
                "unique_resource_copies": preservedCopies
            ])
            precondition(error == nil)
            precondition(!fm.fileExists(atPath: installed.path))
            precondition(store.installedSkills().isEmpty)
            precondition(preservedCopies == (blocked ? 0 : 1))
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
