import CryptoKit
import Foundation

/// Migration locale du périmètre essentiel. Les racines sont injectées : aucun
/// store de skills, CLI, authentification ou préférence n'est ouvert implicitement.
public struct EssentialMigrationStore {
    public struct Report: Sendable {
        public let warnings: [String]
        public let completedSteps: [String]
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private struct Journal: Codable {
        var version = 1
        let codexHome: String?
        var steps: [String: String] = [:]
    }
    private struct TreeEntry: Codable, Equatable {
        let kind: String
        let value: String
    }
    private struct BackupReceipt: Codable {
        let version: Int
        let sourcePath: String
        let sha256: String
        let backupName: String
    }

    public let home: URL
    public let codexHome: URL?
    /// Couture de crash/concurrence des tests ; ne reçoit aucun contenu privé.
    private let checkpoint: (String) throws -> Void
    private let fm = FileManager.default

    public init(home: URL, codexHome: URL?, checkpoint: @escaping (String) throws -> Void = { _ in }) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.codexHome = codexHome?.standardizedFileURL.resolvingSymlinksInPath()
        self.checkpoint = checkpoint
    }

    public var directory: URL { home.appendingPathComponent(".atoll/migrations/essential-v1") }
    private var journalURL: URL {
        let scope = codexHome.map { String(Self.hash(Data($0.path.utf8)).prefix(16)) } ?? "common"
        return directory.appendingPathComponent("state-" + scope + ".json")
    }
    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    /// La façade enregistre les seules anciennes préférences productrices avant
    /// de les désarmer. Le premier original reste intact lors des reprises.
    public func preservePreferences(_ data: Data) throws {
        try prepareDirectory()
        let target = directory.appendingPathComponent("legacy-preferences.json")
        if let previous = try read(target) {
            _ = try object(previous, at: target)
            return
        }
        _ = try object(data, at: target)
        try data.write(to: target, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        guard try read(target) == data else { throw Failure("Sauvegarde des préférences non vérifiée.") }
    }

    public func run() throws -> Report {
        try prepareDirectory()
        var journal: Journal
        if let bytes = try read(journalURL) {
            guard let saved = try? JSONDecoder().decode(Journal.self, from: bytes),
                  saved.version == 1, saved.codexHome == codexHome?.path else {
                throw Failure("Journal de migration illisible : originaux conservés, reprise suspendue.")
            }
            journal = saved
        } else { journal = Journal(codexHome: codexHome?.path) }

        // Le journal prouve les étapes ; on relit néanmoins leur état à chaque
        // lancement, notamment après le retour à une ancienne version d'Atoll.
        var warnings: [String] = []
        func record(_ name: String, _ fingerprint: String = "checked") throws {
            try checkpoint("after-" + name)
            guard journal.steps[name] != fingerprint else { return }
            journal.steps[name] = fingerprint
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        }

        // Les règles de protection sont rendues indépendamment des autres
        // réglages : un JSON sonore corrompu ne doit pas les laisser suspendues.
        try restoreParking(home.appendingPathComponent(".atoll/rockstar-parked-deny.json"), sound: false)
        try record("deny-restored")

        // Le helper autonome ne doit plus sonner quand les hooks d'origine
        // reprennent leur place. Ces fichiers gardent leurs autres champs.
        try disable(home.appendingPathComponent(".atoll/sound-settings.json"), label: "sound-settings")
        try record("sound-disabled")
        try disable(home.appendingPathComponent(".atoll/proactive-recall.json"), label: "recall-config")
        try record("recall-disabled")

        try restoreParking(home.appendingPathComponent(".atoll/parked-sound-hooks.json"), sound: true)
        try record("sounds-restored")

        if let bytes = try read(settingsURL) {
            let updated = try HookSettingsEditor.migratePassive(bytes)
            try replace(settingsURL, expected: bytes, updated: updated, label: "claude-passive")
        }
        try record("claude-passive")
        if let codexHome {
            let hooks = codexHome.appendingPathComponent("hooks.json")
            if let bytes = try read(hooks) {
                let updated = try CodexHookSettingsEditor.migratePassive(bytes)
                try replace(hooks, expected: bytes, updated: updated, label: "codex-passive")
            }
            try record("codex-passive")
        }

        var recallRoots = [("claude", home.appendingPathComponent(".claude"))]
        if let codexHome { recallRoots.append(("codex", codexHome)) }
        for (provider, root) in recallRoots {
            if let warning = try retireRecall(root: root, provider: provider) { warnings.append(warning) }
            try record("recall-" + provider + "-checked")
        }
        try EssentialNotesRecovery.recover(learningRoot: home.appendingPathComponent(".atoll/learning"))
        try record("notes-recovered")
        return Report(warnings: warnings, completedSteps: journal.steps.keys.sorted())
    }

    private func disable(_ url: URL, label: String) throws {
        guard let bytes = try read(url) else { return } // absent = déjà inactif
        var value = try object(bytes, at: url)
        guard value["enabled"] as? Bool != false else { return }
        value["enabled"] = false
        try replace(url, expected: bytes, updated: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), label: label)
    }

    private func restoreParking(_ url: URL, sound: Bool) throws {
        guard !isSymlink(url) else { throw Failure("Le parking est un lien : conservé pour revue, \(url.path).") }
        guard let bytes = try read(url) else { return }
        let settings = try read(settingsURL)
        let updated: Data
        if sound {
            guard let parked = SoundHookEditor.decodeParked(bytes) else {
                throw Failure("Parking sonore illisible : \(url.path). Aucun original supprimé.")
            }
            updated = try SoundHookEditor.restore(into: settings, parked: parked.hooks)
        } else {
            guard let parked = RockstarPermissionsEditor.decodeParked(bytes) else {
                throw Failure("Règles deny parquées illisibles : \(url.path). Aucun original supprimé.")
            }
            updated = try RockstarPermissionsEditor.restore(into: settings, parked: parked.deny)
        }
        // La preuve du parking reste archivée même après restitution. Un crash
        // avant son retrait rejoue une union idempotente au lancement suivant.
        try backup(bytes, source: url, label: sound ? "parked-sounds" : "parked-deny")
        try replace(settingsURL, expected: settings, updated: updated, label: sound ? "restore-sounds" : "restore-deny")
        try checkpoint(sound ? "before-remove-sounds-parking" : "before-remove-deny-parking")
        guard try read(url) == bytes else { throw Failure("Le parking a changé pendant sa restitution : \(url.path).") }
        try fm.removeItem(at: url.resolvingSymlinksInPath())
    }

    private func retireRecall(root: URL, provider: String) throws -> String? {
        let folder = root.appendingPathComponent("skills/atoll-recall")
        let skill = folder.appendingPathComponent("SKILL.md")
        if isSymlink(folder) || isSymlink(skill) {
            return "atoll-recall \(provider) est un lien : conservé pour revue manuelle."
        }
        guard let markdown = try read(skill) else { return nil }
        let hash = Self.hash(markdown)
        let known: Bool
        if provider == "claude" { known = markdown == Data(RecallSkill.markdown.utf8) }
        else {
            let receipt = folder.appendingPathComponent(".atoll-recall.json")
            let data = isSymlink(receipt) ? nil : try read(receipt)
            let value = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            known = (value?["hashes"] as? [String])?.contains(hash) == true
        }
        guard known else { return "atoll-recall \(provider) personnalisé ou non reconnu : conservé pour revue manuelle." }

        let snapshot = try tree(folder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(snapshot)
        let archive = directory.appendingPathComponent("recall-\(provider)-" + Self.hash(encoded).prefix(24))
        if !fm.fileExists(atPath: archive.path) { try fm.copyItem(at: folder, to: archive) }
        try checkpoint("before-verify-recall-" + provider)
        guard try tree(archive) == snapshot, try tree(folder) == snapshot else {
            throw Failure("Archive recall non vérifiée : \(folder.path). Le skill reste actif.")
        }
        try checkpoint("before-retire-recall-" + provider)
        guard try tree(folder) == snapshot, try read(skill) == markdown else {
            throw Failure("Le skill recall a changé pendant l'archivage : \(folder.path).")
        }
        // Seul le fichier d'infrastructure reconnu quitte le catalogue actif.
        // Ressources, reçu et archive complète restent en place.
        try fm.removeItem(at: skill)
        return nil
    }

    private func replace(_ url: URL, expected: Data?, updated: Data, label: String) throws {
        if let expected, equivalentJSON(expected, updated) { return }
        let target = url.resolvingSymlinksInPath()
        let mode = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber
        if let expected { try backup(expected, source: target, label: label) }
        try checkpoint("before-write-" + label)
        guard target == url.resolvingSymlinksInPath(), try read(url) == expected else {
            throw Failure("Modification concurrente détectée : \(url.path). Réessaie la migration.")
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: mode?.intValue ?? 0o600], ofItemAtPath: target.path)
        guard try read(url) == updated else { throw Failure("Écriture non vérifiée : \(url.path).") }
    }

    private func backup(_ bytes: Data, source: URL, label: String) throws {
        let scope = Self.hash(Data(source.path.utf8)).prefix(12)
        let url = directory.appendingPathComponent("\(label)-\(scope)-\(Self.hash(bytes)).backup")
        if let previous = try read(url) {
            guard previous == bytes else { throw Failure("Sauvegarde divergente : \(url.path).") }
        } else {
            try bytes.write(to: url, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard try read(url) == bytes else { throw Failure("Sauvegarde non vérifiée : \(url.path).") }
        let receiptURL = url.appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let receipt = try encoder.encode(BackupReceipt(version: 1, sourcePath: source.path,
            sha256: Self.hash(bytes), backupName: url.lastPathComponent))
        if let previous = try read(receiptURL) {
            guard previous == receipt else { throw Failure("Reçu de sauvegarde divergent : \(receiptURL.path).") }
        } else {
            try receipt.write(to: receiptURL, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
        }
        guard try read(receiptURL) == receipt else { throw Failure("Reçu de sauvegarde non vérifié : \(receiptURL.path).") }
    }

    private func prepareDirectory() throws {
        guard !isSymlink(directory), !isSymlink(directory.deletingLastPathComponent()) else {
            throw Failure("Le dossier de migration est un lien : aucune écriture autorisée.")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func read(_ url: URL) throws -> Data? {
        let target = url.resolvingSymlinksInPath()
        do {
            let attributes = try fm.attributesOfItem(atPath: target.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024 else {
                throw Failure("Fichier inattendu ou trop volumineux : \(url.path).")
            }
            let handle = try FileHandle(forReadingFrom: target)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            guard bytes.count <= 4 * 1024 * 1024 else { throw Failure("Fichier devenu trop volumineux : \(url.path).") }
            return bytes
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) && !isSymlink(url) { return nil }
    }

    private func tree(_ root: URL) throws -> [String: TreeEntry] {
        var entries: [String: TreeEntry] = [:]
        var total = 0
        func visit(_ url: URL, _ path: String) throws {
            guard entries.count < 10_000 else { throw Failure("Archive recall trop volumineuse : \(root.path).") }
            let attributes = try fm.attributesOfItem(atPath: url.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink:
                entries[path] = TreeEntry(kind: "link", value: try fm.destinationOfSymbolicLink(atPath: url.path))
            case .typeDirectory:
                entries[path] = TreeEntry(kind: "directory", value: "")
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, path + "/" + child.lastPathComponent)
                }
            case .typeRegular:
                guard let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024 else {
                    throw Failure("Ressource recall trop volumineuse : \(url.path).")
                }
                let data = try Data(contentsOf: url)
                total += data.count
                guard total <= 64 * 1024 * 1024 else { throw Failure("Archive recall trop volumineuse : \(root.path).") }
                entries[path] = TreeEntry(kind: "file", value: Self.hash(data))
            default: throw Failure("Ressource recall non archivable : \(url.path).")
            }
        }
        try visit(root, ".")
        return entries
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
    private func object(_ bytes: Data, at url: URL) throws -> [String: Any] {
        guard let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            throw Failure("JSON invalide : \(url.path). Original conservé.")
        }
        return value
    }
    private func equivalentJSON(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let left = try? JSONSerialization.jsonObject(with: lhs),
              let right = try? JSONSerialization.jsonObject(with: rhs),
              let a = try? JSONSerialization.data(withJSONObject: left, options: [.sortedKeys]),
              let b = try? JSONSerialization.data(withJSONObject: right, options: [.sortedKeys]) else { return lhs == rhs }
        // NSNumber(1) et Bool(true) sont égaux pour NSDictionary, pas pour JSON.
        return a == b
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
