import Foundation
import CryptoKit

/// Sortie déjà validée, conservée avant toute écriture dans la mémoire.
/// Le checkpoint ne contient aucun chemin de destination pilotable : l'appelant
/// fournit les racines courantes et leur empreinte doit correspondre au reçu.
public struct RetrospectiveDelivery: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let analysisID: UUID
    public let sessionID: String
    public let origin: AgentProvider
    public let destination: AgentProvider
    public let destinationScope: String
    public let transcriptBytes: Int
    public let materialFingerprint: String
    public let decidedAt: Date
    public let createdAt: Date
    public var notes: [Note]
    public var skills: [Skill]

    public struct Note: Codable, Sendable {
        public let value: RetrospectiveReport.Note
        public let filename: String
        public let contents: Data
        public var completed: Bool
        /// Persisté avant l'installation ; nil pour les anciens checkpoints.
        public var started: Bool? = false
    }
    public struct Skill: Codable, Sendable {
        public let value: RetrospectiveReport.SkillProposal
        public let dirname: String
        public let markdown: Data
        public let metadata: Data
        public var completed: Bool
        public var started: Bool? = false
    }
    public var isComplete: Bool { notes.allSatisfy(\.completed) && skills.allSatisfy(\.completed) }
    public var notesWritten: Int { notes.filter(\.completed).count }
    public var skillsProposed: Int { skills.filter(\.completed).count }

    public static func scope(for proposals: URL) -> String {
        fingerprint(proposals.resolvingSymlinksInPath().standardizedFileURL.path)
    }
    public static func fingerprint(_ material: String) -> String {
        SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public init(report: RetrospectiveReport, analysisID: UUID, sessionID: String,
                origin: AgentProvider, destination: AgentProvider, proposals: URL,
                notesDirectory: URL, project: String?, transcriptBytes: Int,
                materialFingerprint: String, decidedAt: Date, now: Date = Date()) {
        version = 1
        id = UUID()
        self.analysisID = analysisID
        self.sessionID = sessionID
        self.origin = origin
        self.destination = destination
        destinationScope = Self.scope(for: proposals)
        self.transcriptBytes = transcriptBytes
        self.materialFingerprint = materialFingerprint
        self.decidedAt = decidedAt
        createdAt = now
        let deliveryID = id.uuidString
        var existing = Set((try? FileManager.default.contentsOfDirectory(atPath: notesDirectory.path)) ?? [])
        notes = report.notes.map { note in
            let rendered = LearningNoteFile.render(note: note, sessionID: sessionID, project: project, date: now)
            let filename = LearningNoteFile.deduplicatedFilename(rendered.filename, existing: existing)
            existing.insert(filename)
            let contents = "---\ndelivery_id: \(deliveryID)\ndelivery_artifact: \(filename)\n"
                + rendered.contents.dropFirst(4)
            return Note(value: note, filename: filename, contents: Data(contents.utf8), completed: false)
        }
        skills = report.skills.map { skill in
            let dirname = "\(skill.slug)-\(UUID().uuidString)"
            let rendered = LearningSkillProposalFile.renderMeta(skill, sessionID: sessionID,
                project: project, date: now, flags: report.flags[skill.slug] ?? [], destination: destination)
            var metadata = (try? JSONSerialization.jsonObject(with: rendered)) as? [String: Any] ?? [:]
            metadata["delivery_id"] = deliveryID
            metadata["delivery_artifact"] = dirname
            return Skill(value: skill, dirname: dirname,
                         markdown: Data(LearningSkillProposalFile.renderSkillMD(skill).utf8),
                         metadata: (try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])) ?? Data(),
                         completed: false)
        }
    }

    public struct Store {
        public let directory: URL
        private let fm = FileManager.default
        public init(learningRoot: URL) { directory = learningRoot.appendingPathComponent("deliveries-v1") }

        /// La capacité borne la rétention des sorties non récupérées. Rien n'est
        /// supprimé pour faire de la place et aucun nouveau modèle n'est appelé.
        public func preflight() throws {
            try ensureDirectory(directory)
            guard try pending().count < 16 else { throw Failure("Trop de résultats attendent leur enregistrement.") }
        }

        public func pending() throws -> [RetrospectiveDelivery] {
            guard fm.fileExists(atPath: directory.path) else { return [] }
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            guard files.count <= 16 else { throw Failure("Trop de résultats en attente.") }
            return try files.map { url in
                guard !isSymlink(url), let data = BoundedProcessOutput.file(at: url, cap: 262_144),
                      let value = try? JSONDecoder().decode(RetrospectiveDelivery.self, from: data),
                      url.lastPathComponent == value.id.uuidString + ".json" else {
                    throw Failure("Résultat sauvegardé illisible : aucune nouvelle analyse.")
                }
                try validate(value)
                return value
            }.sorted { $0.createdAt < $1.createdAt }
        }

        public func save(_ value: RetrospectiveDelivery) throws {
            try validate(value)
            try ensureDirectory(directory)
            let data = try JSONEncoder().encode(value)
            guard data.count <= 262_144 else { throw Failure("Résultat trop volumineux pour être sauvegardé.") }
            let url = directory.appendingPathComponent(value.id.uuidString + ".json")
            guard !isSymlink(url) else { throw Failure("Destination de sauvegarde inattendue.") }
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        /// Progression persistée après chaque artefact complet. Une reprise ne
        /// recrée pas une note rangée, ni une proposition déjà approuvée/rejetée.
        public func apply(_ value: inout RetrospectiveDelivery, notesDirectory: URL, proposals: URL,
                          onNote: (URL, RetrospectiveReport.Note) -> Void) throws {
            try validate(value)
            guard value.destinationScope == RetrospectiveDelivery.scope(for: proposals) else {
                throw Failure("La destination a changé : le résultat reste sauvegardé.")
            }
            var failures = false
            for index in value.notes.indices where !value.notes[index].completed {
                let note = value.notes[index]
                do {
                    let url = notesDirectory.appendingPathComponent(note.filename)
                    let present = exactFile(note.contents, at: url)
                    let archived = !present && noteAlreadyArchived(note, deliveryID: value.id, notesDirectory: notesDirectory)
                    if !present && !archived {
                        guard note.started == false else { throw ambiguousDelivery() }
                        try ensureDirectory(notesDirectory)
                        value.notes[index].started = true
                        do { try save(value) }
                        catch { value.notes[index].started = note.started; throw error }
                        do { try createOrVerify(note.contents, at: url) }
                        catch {
                            // Aucun fichier n'a été installé par cet appel.
                            value.notes[index].started = false
                            try? save(value)
                            throw error
                        }
                    }
                    value.notes[index].completed = true
                    try save(value)
                    if !archived { onNote(url, note.value) }
                } catch { failures = true }
            }
            for index in value.skills.indices where !value.skills[index].completed {
                let skill = value.skills[index]
                do {
                    let dir = proposals.appendingPathComponent(skill.dirname)
                    let markdownURL = dir.appendingPathComponent("SKILL.md")
                    let metadataURL = dir.appendingPathComponent("meta.json")
                    let delivered = skillAlreadyDelivered(skill, deliveryID: value.id, proposals: proposals)
                    if !delivered {
                        let partial = exactFile(skill.markdown, at: markdownURL)
                            && !fm.fileExists(atPath: metadataURL.path) && !isSymlink(metadataURL)
                        guard skill.started == false || partial else { throw ambiguousDelivery() }
                        try ensureDirectory(proposals)
                        try ensureDirectory(dir)
                        value.skills[index].started = true
                        do { try save(value) }
                        catch { value.skills[index].started = skill.started; throw error }
                        var markdownInstalled = false
                        do {
                            try createOrVerify(skill.markdown, at: markdownURL)
                            markdownInstalled = true
                            try createOrVerify(skill.metadata, at: metadataURL)
                        } catch {
                            if !markdownInstalled {
                                value.skills[index].started = false
                                try? save(value)
                            }
                            throw error
                        }
                    }
                    value.skills[index].completed = true
                    try save(value)
                } catch { failures = true }
            }
            if failures { throw Failure("Enregistrement incomplet : résultat sauvegardé, reprise sans nouvelle analyse.") }
        }

        private func ambiguousDelivery() -> Failure {
            Failure("Écriture commencée, mais preuve introuvable : le résultat reste en attente pour éviter une recréation.")
        }

        private func exactFile(_ data: Data, at url: URL) -> Bool {
            !isSymlink(url) && BoundedProcessOutput.file(at: url, cap: 131_072) == data
        }

        private func noteAlreadyArchived(_ note: Note, deliveryID: UUID, notesDirectory: URL) -> Bool {
            let provenance = "---\ndelivery_id: \(deliveryID.uuidString)\ndelivery_artifact: \(note.filename)\n"
            guard note.contents.starts(with: Data(provenance.utf8)) else { return false }
            let archive = notesDirectory.deletingLastPathComponent().appendingPathComponent("archive")
            // La curation conserve les octets, y compris la provenance unique.
            // Une archive purgée ou hors borne ne constitue jamais une preuve.
            return childDirectories(archive, prefix: "notes-", limit: 32).contains {
                exactFile(note.contents, at: $0.appendingPathComponent(note.filename))
            }
        }

        private func skillAlreadyDelivered(_ skill: Skill, deliveryID: UUID, proposals: URL) -> Bool {
            var remainingBytes = 4 * 1_024 * 1_024
            func matches(_ dir: URL) -> Bool {
                let meta = dir.appendingPathComponent("meta.json")
                guard remainingBytes > 0, !isSymlink(dir), !isSymlink(meta),
                      let data = BoundedProcessOutput.file(at: meta, cap: min(131_072, remainingBytes)) else { return false }
                remainingBytes -= data.count
                guard
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
                // Les transitions de revue conservent ces champs. Le markdown
                // peut avoir été corrigé par l'utilisateur depuis la livraison.
                return object["delivery_id"] as? String == deliveryID.uuidString
                    && object["delivery_artifact"] as? String == skill.dirname
                    && ["proposed", "approved", "rejected"].contains(object["status"] as? String ?? "")
            }
            let current = proposals.appendingPathComponent(skill.dirname)
            if matches(current) { return true }
            // Compatibilité des checkpoints antérieurs à la provenance.
            if exactFile(skill.markdown, at: current.appendingPathComponent("SKILL.md"))
                && exactFile(skill.metadata, at: current.appendingPathComponent("meta.json")) { return true }
            let archive = proposals.deletingLastPathComponent().appendingPathComponent("archive")
            for category in ["approved", "rejected"] {
                for dir in childDirectories(archive.appendingPathComponent(category), limit: 512) where matches(dir) {
                    return true
                }
            }
            return false
        }

        private func childDirectories(_ root: URL, prefix: String = "", limit: Int) -> [URL] {
            guard !isSymlink(root) else { return [] }
            return ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .prefix(limit)
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                    .map { $0.isDirectory == true && $0.isSymbolicLink != true } == true }
        }

        /// Appelé uniquement APRÈS persistance du reçu dans retrospectives.json.
        public func acknowledge(_ value: RetrospectiveDelivery) throws {
            guard value.isComplete else { throw Failure("Résultat encore incomplet.") }
            try fm.removeItem(at: directory.appendingPathComponent(value.id.uuidString + ".json"))
        }

        private func createOrVerify(_ data: Data, at url: URL) throws {
            guard !isSymlink(url) else { throw Failure("Artefact remplacé par un lien.") }
            if fm.fileExists(atPath: url.path) {
                guard BoundedProcessOutput.file(at: url, cap: 131_072) == data else {
                    throw Failure("Un fichier différent occupe la destination ; il est préservé.")
                }
                return
            }
            // Le hard link installe atomiquement un fichier complet et échoue
            // si quelqu'un a créé la destination entre la vérification et nous.
            let staged = url.deletingLastPathComponent().appendingPathComponent(".atoll-delivery-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staged) }
            try data.write(to: staged, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            try fm.linkItem(at: staged, to: url)
        }

        private func ensureDirectory(_ url: URL) throws {
            guard !isSymlink(url) else { throw Failure("Répertoire de livraison remplacé par un lien.") }
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        private func isSymlink(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        }
        private func validate(_ value: RetrospectiveDelivery) throws {
            func component(_ name: String) -> Bool {
                !name.isEmpty && name.count <= 180 && name.range(of: "\\A[a-zA-Z0-9-]+(?:\\.md)?\\z", options: .regularExpression) != nil
            }
            guard value.version == 1, value.notes.count <= 8, value.skills.count <= 2,
                  value.notes.allSatisfy({ component($0.filename) && $0.filename.hasSuffix(".md") && $0.contents.count <= 131_072 }),
                  value.skills.allSatisfy({ component($0.dirname) && $0.markdown.count <= 131_072 && $0.metadata.count <= 131_072 }) else {
                throw Failure("Résultat sauvegardé invalide.")
            }
        }
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }
}
