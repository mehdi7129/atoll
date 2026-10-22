import Foundation

/// Récupération strictement locale d'une ancienne bascule de notes interrompue.
/// Adaptée du chemin transactionnel qualifié de NotesCurationService : aucun
/// calendrier, appel modèle, acquittement du résultat ou nettoyage du staging.
public enum EssentialNotesRecovery {
    public enum Failure: LocalizedError {
        case interruptedSwapUnproven
        public var errorDescription: String? {
            "Ancienne bascule de notes ambiguë : fichiers, staging et checkpoint conservés pour reprise."
        }
    }
    public static func recover(learningRoot: URL) throws {
        let checkpointStore = CurationCheckpointStore(directory: learningRoot.appendingPathComponent("curation-pending"))
        guard let checkpoint = try checkpointStore.load() else { return }
        let fm = FileManager.default
        let notesDirectory = learningRoot.appendingPathComponent("notes")
        func files(in directory: URL, strict: Bool, swapID: UUID? = nil) throws -> [String: Data] {
            let kind = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard kind.isDirectory == true, kind.isSymbolicLink == false else {
                throw Failure.interruptedSwapUnproven
            }
            var result: [String: Data] = [:]
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                let isMarker = name == ".swap-started" && swapID != nil
                guard isMarker || (!name.hasPrefix(".") && name.lowercased().hasSuffix(".md")) else {
                    if strict { throw Failure.interruptedSwapUnproven }
                    continue
                }
                let kind = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard kind.isRegularFile == true, kind.isSymbolicLink == false,
                      let bytes = BoundedProcessOutput.file(at: file, cap: 2 * 1024 * 1024) else {
                    throw Failure.interruptedSwapUnproven
                }
                if isMarker {
                    guard bytes == Data(swapID!.uuidString.utf8) else { throw Failure.interruptedSwapUnproven }
                } else {
                    result[name] = bytes
                }
            }
            return result
        }
        func corpus(_ files: [String: Data]) throws -> [(name: String, content: String)] {
            try files.sorted { $0.key < $1.key }.map {
                guard let content = String(data: $0.value, encoding: .utf8) else {
                    throw Failure.interruptedSwapUnproven
                }
                return (name: $0.key, content: content)
            }
        }
        let stagingDirectories = try fm.contentsOfDirectory(at: learningRoot,
                                                             includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".notes-staging-") }
        let staged = try stagingDirectories.map {
            ($0, try files(in: $0, strict: true, swapID: checkpoint.id),
             fm.fileExists(atPath: $0.appendingPathComponent(".swap-started").path))
        }
            .filter { !$0.1.isEmpty }
        guard !staged.isEmpty else {
            // Même vide, un staging ne justifie pas d'écarter un checkpoint
            // dont ni les sources ni la cible ne correspondent au disque.
            if !stagingDirectories.isEmpty,
               checkpoint.match(notes: try corpus(files(in: notesDirectory, strict: false))) == .changed {
                throw Failure.interruptedSwapUnproven
            }
            return
        }
        guard staged.count == 1, let output = checkpoint.output else {
            throw Failure.interruptedSwapUnproven
        }
        let (staging, pending, swapStarted) = staged[0]
        let archives = try fm.contentsOfDirectory(at: learningRoot.appendingPathComponent("archive"),
                                                 includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("notes-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var source: [String: Data]?
        for archive in archives.prefix(32) {
            guard let candidate = try? files(in: archive, strict: true),
                  Set(candidate.keys) == Set(checkpoint.sourceNames),
                  let previous = try? corpus(candidate),
                  CurationCorpusFingerprint(notes: previous) == checkpoint.sourceFingerprint else { continue }
            source = candidate
            break
        }
        guard let source,
              case .success(let plan) = NotesCurationPlanner.plan(existing: try corpus(source), output: output,
                now: checkpoint.createdAt, archives: NoteProvenance.readArchives(at: learningRoot.appendingPathComponent("archive"))),
              CurationCorpusFingerprint(notes: plan.newNotes.map { ($0.fileName, $0.content) }) == checkpoint.targetFingerprint else {
            throw Failure.interruptedSwapUnproven
        }
        let target = Dictionary(uniqueKeysWithValues: plan.newNotes.map { ($0.fileName, Data($0.content.utf8)) })
        let present = try files(in: notesDirectory, strict: false)
        // Aucun fichier ajouté ou modifié n'est attribué au swap par son nom
        // seul. Même discipline pour le staging, qui est la copie de secours.
        guard pending.allSatisfy({ target[$0.key] == $0.value }),
              present.allSatisfy({ source[$0.key] == $0.value || target[$0.key] == $0.value }) else {
            throw Failure.interruptedSwapUnproven
        }
        let intact = CurationCorpusFingerprint(notes: try corpus(present)) == checkpoint.sourceFingerprint
        guard intact || (swapStarted && target.allSatisfy({ pending[$0.key] == $0.value || present[$0.key] == $0.value })) else {
            throw Failure.interruptedSwapUnproven
        }
        if !intact {
            // Remettre d'abord TOUTES les sorties dans le staging : un second
            // crash au milieu de la restauration garde les mêmes preuves.
            for (name, bytes) in target where pending[name] == nil {
                let path = notesDirectory.appendingPathComponent(name)
                guard try Data(contentsOf: path) == bytes else { throw Failure.interruptedSwapUnproven }
                try fm.copyItem(at: path, to: staging.appendingPathComponent(name))
            }
            guard try files(in: staging, strict: true, swapID: checkpoint.id) == target else { throw Failure.interruptedSwapUnproven }
            for (name, bytes) in source {
                let path = notesDirectory.appendingPathComponent(name)
                if fm.fileExists(atPath: path.path) {
                    let current = try Data(contentsOf: path)
                    if current == bytes { continue }
                    guard current == target[name] else { throw Failure.interruptedSwapUnproven }
                    try fm.removeItem(at: path)
                }
                // Sans .atomic : création exclusive, jamais écraser une note
                // réapparue après notre lecture.
                try bytes.write(to: path, options: .withoutOverwriting)
            }
            for (name, bytes) in target where source[name] == nil {
                let path = notesDirectory.appendingPathComponent(name)
                guard fm.fileExists(atPath: path.path) else { continue }
                guard try Data(contentsOf: path) == bytes else { throw Failure.interruptedSwapUnproven }
                try fm.removeItem(at: path)
            }
        }
        guard CurationCorpusFingerprint(notes: try corpus(files(in: notesDirectory, strict: false))) == checkpoint.sourceFingerprint,
              try files(in: staging, strict: true, swapID: checkpoint.id) == (intact ? pending : target) else {
            throw Failure.interruptedSwapUnproven
        }
        // Le staging et le résultat payé restent disponibles, y compris après
        // restauration : le nouveau périmètre ne reprend aucun rangement.
        // Une seconde passe reconnaît simplement les sources déjà intactes.
    }

}
