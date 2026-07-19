import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "model-quota")

/// Jauges de quota PAR MODÈLE (« Fable : 27 % ») — opt-in explicite.
///
/// Source : l'endpoint non documenté `GET /api/oauth/usage` de claude.ai,
/// interrogé en LECTURE SEULE avec le jeton local de Claude Code (Keychain
/// « Claude Code-credentials »). Règles absolues (voir docs/research
/// quota) : jamais de refresh du jeton (désynchroniserait le CLI — on relit
/// simplement le Keychain au prochain tick), cadence lente (120 s), échec
/// silencieux, données cachées au-delà de 10 min sans succès.
@MainActor
@Observable
final class ModelQuotaPoller {
    static let shared = ModelQuotaPoller()
    static let enabledKey = "perModelQuotaEnabled"

    private(set) var scopedLimits: [OAuthUsage.ScopedLimit] = []
    private(set) var lastSuccessAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Fraîcheur : au-delà de 10 min sans succès, on n'affiche plus rien.
    var displayedLimits: [OAuthUsage.ScopedLimit] {
        guard let lastSuccessAt, Date().timeIntervalSince(lastSuccessAt) < 600 else { return [] }
        return scopedLimits
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// (Re)démarre ou arrête selon le réglage — appelé au lancement et au toggle.
    func syncWithSettings() {
        task?.cancel()
        task = nil
        guard isEnabled else {
            scopedLimits = []
            lastSuccessAt = nil
            return
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchOnce()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private func fetchOnce() async {
        guard let token = await Self.readAccessToken() else {
            log.info("jeton Claude Code introuvable dans le Keychain")
            return
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            guard http.statusCode == 200 else {
                // 401 : jeton expiré/roté — le CLI le renouvellera lui-même, on
                // relira le Keychain au prochain tick. JAMAIS de refresh ici.
                log.info("usage endpoint HTTP \(http.statusCode, privacy: .public)")
                return
            }
            guard let usage = OAuthUsage(data: data) else { return }
            scopedLimits = usage.scopedLimits
            lastSuccessAt = Date()
        } catch {
            // Réseau coupé, endpoint disparu… : silencieux, on réessaiera.
            log.debug("usage endpoint : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Jeton OAuth du CLI : item « Claude Code-credentials » du Keychain, lu via
    /// `/usr/bin/security` (identité STABLE — un accès SecItemCopyMatching
    /// depuis l'app redemanderait l'autorisation à CHAQUE build Debug redéployé,
    /// le trousseau voyant chaque binaire adhoc comme une app différente).
    private static func readAccessToken() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let oauth = root["claudeAiOauth"] as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: oauth["accessToken"] as? String)
            }
        }
    }
}
