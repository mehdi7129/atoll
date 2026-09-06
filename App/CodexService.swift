import Foundation
import Observation
import AtollCore

@MainActor
@Observable
final class CodexService {
    static let shared = CodexService()
    static let quotaEnabledKey = "codexQuotaEnabled"
    static let executableKey = "codexExecutablePath"

    private(set) var sessions: [AgentSession] = []
    private(set) var quota: CodexQuota?
    private(set) var status = "lecture désactivée dans Réglages → Codex"
    private(set) var isLoading = false
    @ObservationIgnored private var observed = CodexSessions()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.observed.prune()
                self.sessions = self.observed.sessions()
            }
        }
        syncQuotaSettings()
    }

    func apply(_ event: CodexHookEvent) {
        observed.apply(event)
        sessions = observed.sessions()
    }

    func seedPreviewQuota() {
        guard CodexPreview.enabled else { return }
        quota = CodexQuota(result: ["rateLimits": ["limitId": "codex", "primary": [
            "usedPercent": 18, "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(7200).timeIntervalSince1970
        ], "secondary": ["usedPercent": 43, "windowDurationMins": 10080,
                          "resetsAt": Date().addingTimeInterval(172800).timeIntervalSince1970]]])
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pollTask?.cancel()
        generation = UUID()
    }

    func syncQuotaSettings() {
        pollTask?.cancel()
        generation = UUID()
        let current = generation
        quota = nil // no cross-account/executable cache
        isLoading = false
        guard UserDefaults.standard.bool(forKey: Self.quotaEnabledKey) else {
            status = "lecture désactivée dans Réglages → Codex"
            return
        }
        status = "lecture du quota…"
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetch(generation: current)
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private func fetch(generation current: UUID) async {
        guard let executable = resolveExecutable() else {
            status = "codex introuvable — indique son chemin dans les réglages"
            return
        }
        isLoading = true
        let worker = Task.detached(priority: .utility) {
            CodexAccountClient.read(executable: executable, cancelled: { Task<Never, Never>.isCancelled })
        }
        let outcome = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, generation == current else { return }
        isLoading = false
        switch outcome {
        case .available(let value):
            quota = value
            status = "à jour · lecture toutes les 2 min"
        case .unavailable(let message):
            quota = nil // errors and account changes never appear as fresh 0%
            status = message
        }
    }

    private func resolveExecutable() -> URL? {
        let fm = FileManager.default
        let custom = UserDefaults.standard.string(forKey: Self.executableKey) ?? ""
        let candidates: [String]
        if !custom.isEmpty {
            candidates = [(custom as NSString).expandingTildeInPath]
        } else {
            candidates = [fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
                + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                    .filter { $0.hasPrefix("/") }.map { "\($0)/codex" }
        }
        return candidates.first { path in
            var directory: ObjCBool = false
            return path.hasPrefix("/") && fm.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue && fm.isExecutableFile(atPath: path)
        }.map { URL(fileURLWithPath: $0) }
    }
}
