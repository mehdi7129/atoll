import Foundation

/// Résultat de rangement déjà payé. Les notes d'entrée ne sont pas recopiées :
/// leur empreinte empêche d'appliquer la sortie à un corpus modifié entre-temps.
public struct CurationCheckpoint: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let leaseID: UUID
    public let sourceNames: [String]
    public let sourceFingerprint: CurationCorpusFingerprint
    public let targetFingerprint: CurationCorpusFingerprint
    private let version: Int
    private let payload: Data

    public enum Match: Equatable { case source, target, changed }

    /// Repasser par le parseur métier, même pour un fichier écrit par Atoll.
    /// Le contenu persistant n'est jamais une autorisation d'écriture.
    public var output: NotesCurationOutput? {
        NotesCurationOutput.parse(codexOutput: payload)
    }

    public init(previous: [(name: String, content: String)], output: NotesCurationOutput,
                plan: NotesCurationPlanner.Plan, createdAt: Date, leaseID: UUID) throws {
        id = UUID()
        version = 1
        self.createdAt = createdAt
        self.leaseID = leaseID
        sourceNames = previous.map(\.name).sorted()
        sourceFingerprint = CurationCorpusFingerprint(notes: previous)
        targetFingerprint = CurationCorpusFingerprint(notes: plan.newNotes.map { ($0.fileName, $0.content) })
        payload = try JSONSerialization.data(withJSONObject: [
            "notes": output.notes.map { ["title": $0.title, "content": $0.content, "sources": $0.sources] as [String: Any] },
            "contradictions": output.contradictions.map { ["summary": $0.summary, "files": $0.files] as [String: Any] }
        ], options: [.sortedKeys])
        try validate()
    }

    public func match(notes: [(name: String, content: String)]) -> Match {
        let fingerprint = CurationCorpusFingerprint(notes: notes)
        // Si les deux corpus sont identiques, aucun remplacement n'est requis.
        if fingerprint == targetFingerprint { return .target }
        return fingerprint == sourceFingerprint ? .source : .changed
    }

    fileprivate func validate() throws {
        guard version == 1, payload.count <= CurationCheckpointStore.byteLimit,
              let output, !output.notes.isEmpty,
              !sourceNames.isEmpty, Set(sourceNames).count == sourceNames.count,
              sourceNames.allSatisfy({ !$0.hasPrefix(".") && !$0.contains("/")
                  && !$0.contains("\0") && $0.lowercased().hasSuffix(".md") }),
              [sourceFingerprint, targetFingerprint].allSatisfy({
                  $0.version == 1 && $0.sha256.range(of: "\\A[0-9a-f]{64}\\z", options: .regularExpression) != nil
              }) else { throw CurationCheckpointStore.Failure.invalid }
    }
}

/// Un seul rangement en attente, dans son dossier privé. Un fichier illisible
/// n'est pas assimilé à une absence : cela déclencherait une nouvelle dépense.
public struct CurationCheckpointStore: Sendable {
    public enum Failure: Error { case invalid, tooLarge, differentCheckpoint }
    static let byteLimit = 2 * 1024 * 1024
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("result.json") }

    public init(directory: URL) { self.directory = directory }

    public func load() throws -> CurationCheckpoint? {
        let data: Data
        do {
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            guard let size, size.intValue <= Self.byteLimit else { throw Failure.tooLarge }
            guard let bounded = BoundedProcessOutput.file(at: file, cap: Self.byteLimit) else { throw Failure.invalid }
            data = bounded
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
        let checkpoint = try JSONDecoder().decode(CurationCheckpoint.self, from: data)
        try checkpoint.validate()
        return checkpoint
    }

    public func save(_ checkpoint: CurationCheckpoint) throws {
        try checkpoint.validate()
        let data = try JSONEncoder().encode(checkpoint)
        guard data.count <= Self.byteLimit else { throw Failure.tooLarge }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func remove(ifID id: UUID) throws {
        guard let current = try load() else { return }
        guard current.id == id else { throw Failure.differentCheckpoint }
        try FileManager.default.removeItem(at: file)
    }
}
