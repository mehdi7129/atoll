import Foundation
import AtollCore

/// Snapshot pris avant le premier await. La sélection d'affichage n'intervient pas.
struct AnalysisExecution {
    enum Kind: String, Codable { case retrospective, curation, pluginSearch }
    let provider: AgentProvider
    let reason: String
    let model: String
    let home: URL
    let executableOverride: String
    let quota: LearningGate.QuotaFacts
    let threshold: Double
    let maximum: Int
    let allowUnknown: Bool

    @MainActor
    static func capture(kind: Kind, forcedProvider: AgentProvider? = nil) throws -> Self {
        let settings = LearningSettings.shared
        let store = SessionStore.shared
        let claude = LearningGate.QuotaFacts(usedFraction: store.realQuota?.fiveHour.usedFraction,
            receivedAt: store.rawQuotaReceivedAt, resetsAt: store.realQuota?.fiveHour.resetsAt,
            bucket: "claude", window: "fiveHour")
        let choice = ProviderFailover.choose(claude: claude, codex: CodexService.shared.quota,
                                             config: settings.failoverConfig)
        guard let provider = forcedProvider ?? choice.provider else {
            throw Failure("Aucun abonnement disponible (\(choice.reason.rawValue)).")
        }
        let model: String
        if provider == .codex { model = settings.codexModel }
        else {
            switch kind {
            case .retrospective: model = settings.model
            case .curation: model = settings.curationModel
            case .pluginSearch: model = settings.searchModel
            }
        }
        if provider == .codex && model.isEmpty {
            throw Failure("Choisis le modèle des analyses Codex dans Réglages → Codex.")
        }
        return Self(provider: provider, reason: forcedProvider == nil ? choice.reason.rawValue : "debug",
                    model: model, home: provider == .codex ? try CodexPaths.validatedHome() : CodexPaths.cliHomeURL,
                    executableOverride: UserDefaults.standard.string(forKey: CodexExecutable.overrideKey) ?? "",
                    quota: provider == .codex ? ProviderFailover.quotaFacts(of: CodexService.shared.quota) : claude,
                    threshold: settings.quotaThreshold, maximum: settings.maxPerWindow,
                    allowUnknown: settings.allowUnknownQuota)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// Les trois consommateurs partagent un verrou et un plafond par abonnement.
/// Réserver ne dépense pas ; seul un spawn réussi marque le créneau comme lancé.
@MainActor
final class AnalysisBudget {
    static let shared = AnalysisBudget()
    private(set) var active: UUID?
    private(set) var activeProvider: AgentProvider?
    private var records: [Record] = []
    private var loaded = false
    private var loadError: String?
    private var legacySpends: [Date] = []
    private var url: URL { BridgePaths.learningDirectory.appendingPathComponent("analysis-jobs-v2.json") }

    struct Record: Codable {
        let id: UUID
        let kind: AnalysisExecution.Kind
        let origin: AgentProvider?
        let destination: AgentProvider?
        let provider: AgentProvider
        let model: String
        let quota: LearningGate.QuotaFacts
        let providerReason: String
        let preparedAt: Date
        var launchedAt: Date?
        var outcome: String
    }

    private struct State: Codable {
        let version: Int
        let records: [Record]
        let legacySpends: [Date]
    }

    func begin(_ context: AnalysisExecution, kind: AnalysisExecution.Kind,
               origin: AgentProvider? = nil, destination: AgentProvider? = nil,
               force: Bool = false) throws -> UUID {
        guard active == nil else { throw AnalysisExecution.Failure("Une analyse Atoll est déjà en cours.") }
        try load()
        if !force, let refusal = refusal(for: context) { throw AnalysisExecution.Failure(refusal) }
        let id = UUID()
        records.append(Record(id: id, kind: kind, origin: origin, destination: destination,
                              provider: context.provider, model: context.model, quota: context.quota,
                              providerReason: context.reason, preparedAt: Date(), outcome: "preparing"))
        do { try save() }
        catch { records.removeAll { $0.id == id }; throw error }
        active = id
        activeProvider = context.provider
        return id
    }

    func refusal(for context: AnalysisExecution, now: Date = Date()) -> String? {
        switch refusalReason(for: context, now: now) {
        case .windowCapReached: return "Plafond interne atteint pour \(context.provider.label) (5 h glissantes)."
        case .quotaAboveThreshold: return "Quota \(context.provider.label) au-dessus du seuil d'analyse."
        case .some: return "Quota \(context.provider.label) inconnu : tentative interne non autorisée."
        case nil: return nil
        }
    }

    func refusalReason(for context: AnalysisExecution, now: Date = Date()) -> LearningGate.Reason? {
        let recent = records.filter {
            $0.provider == context.provider && $0.launchedAt.map { now.timeIntervalSince($0) < LearningGate.runWindowSeconds } == true
        }.count + legacySpends.filter { now.timeIntervalSince($0) < LearningGate.runWindowSeconds }.count
        if recent >= context.maximum { return .windowCapReached }
        // Une mesure haute ne redevient pas disponible parce qu'elle vieillit.
        // Tant que la même fenêtre est en cours elle reste un minorant. Le
        // repli de 5 h sans reset ne concerne que l'ancien contrat Claude.
        if let used = context.quota.usedFraction, used.isFinite, used >= context.threshold,
           let received = context.quota.receivedAt, received <= now,
           context.quota.resetsAt.map({ $0 > now })
                ?? (context.provider == .claude && now.timeIntervalSince(received) < LearningGate.runWindowSeconds) {
            return .quotaAboveThreshold
        }
        if let used = context.quota.usable(at: now, freshness: context.provider == .codex ? 300 : 600) {
            if used >= context.threshold { return .quotaAboveThreshold }
        } else {
            if !context.allowUnknown { return .quotaMissing }
            if recent >= 1 { return .windowCapReached }
        }
        return nil
    }

    func mayLaunch(_ id: UUID, context: AnalysisExecution, force: Bool = false) -> Bool {
        guard active == id else { return false }
        if force { return true }
        // Un snapshot frais à la préparation qui expire ne devient pas une
        // autorisation de tentative inconnue pendant la résolution du binaire.
        let preparedAt = records.first { $0.id == id }?.preparedAt ?? Date()
        if context.quota.usable(at: preparedAt, freshness: context.provider == .codex ? 300 : 600) != nil,
           context.quota.usable(at: Date(), freshness: context.provider == .codex ? 300 : 600) == nil { return false }
        return refusal(for: context) == nil
    }

    func launched(_ id: UUID) {
        guard active == id, let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].launchedAt = Date()
        records[index].outcome = "running"
        // La réservation est déjà persistée : après crash, elle compte par prudence.
        try? save()
    }

    func finish(_ id: UUID, outcome: String) {
        guard active == id else { return }
        if let index = records.firstIndex(where: { $0.id == id }) { records[index].outcome = outcome }
        try? save()
        active = nil
        activeProvider = nil
    }

    private func load() throws {
        if loaded {
            if let loadError { throw AnalysisExecution.Failure(loadError) }
            return
        }
        loaded = true
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 2_097_153) ?? Data()
                guard data.count <= 2_097_152 else { throw CocoaError(.fileReadCorruptFile) }
                let state = try JSONDecoder().decode(State.self, from: data)
                guard state.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                records = state.records
                legacySpends = state.legacySpends
                for i in records.indices where records[i].outcome == "preparing" || records[i].outcome == "running" {
                    records[i].launchedAt = records[i].launchedAt ?? records[i].preparedAt
                    records[i].outcome = "interrupted"
                }
            } else if FileManager.default.fileExists(atPath: BridgePaths.learningStateURL.path) {
                // Les anciens timestamps n'identifient pas toujours le moteur.
                // Pendant leur fenêtre restante ils bornent les deux comptes ;
                // on ne les requalifie pas arbitrairement comme dépenses Claude.
                struct Legacy: Decodable { let runTimestamps: [Date]? }
                guard let data = BoundedProcessOutput.file(at: BridgePaths.learningStateURL, cap: 2_097_152) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                legacySpends = try JSONDecoder().decode(Legacy.self, from: data).runTimestamps ?? []
                legacySpends = legacySpends.filter { Date().timeIntervalSince($0) < LearningGate.runWindowSeconds }
            }
        } catch {
            loadError = "Journal des analyses illisible : aucune nouvelle dépense."
            throw AnalysisExecution.Failure(loadError!)
        }
    }

    private func save() throws {
        // Garder tous les lancements de la fenêtre, même avec beaucoup de refus.
        let cutoff = Date().addingTimeInterval(-LearningGate.runWindowSeconds)
        let recentSpends = records.filter { $0.launchedAt.map { $0 >= cutoff } == true }
        let other = records.filter { $0.launchedAt.map { $0 >= cutoff } != true }
        records = (Array(other.suffix(100)) + recentSpends).sorted { $0.preparedAt < $1.preparedAt }
        legacySpends = legacySpends.filter { $0 >= cutoff }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(State(version: 1, records: records, legacySpends: legacySpends))
            .write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
