import Foundation
import AtollCore

/// Résolution du chemin ABSOLU de `codex` — jumelle de `ClaudeExecutable`, et
/// pour la même raison, qui a coûté la v0.16.6 : une app GUI qui lance une CLI
/// par son nom nu échoue en exit 127, parce que `zsh -l -c` est un shell de
/// login NON INTERACTIF et ne lit donc jamais `~/.zshrc` — or c'est là que les
/// installeurs mettent `~/.local/bin` dans le PATH. MESURÉ le 2026-08-24 pour
/// `claude` ; `codex` s'installe au MÊME endroit
/// (`~/.local/bin/codex` → `~/.codex/packages/standalone/current/bin/codex`),
/// donc exactement le même piège l'attendait.
///
/// ⚠️ NE PAS DIAGNOSTIQUER CE GENRE DE PANNE DEPUIS UN TERMINAL : le shell y
/// hérite déjà d'un PATH enrichi et ne reproduit rien. L'instrument est
/// `env -i zsh -l -c 'command -v codex'`.
///
/// UNE SEULE résolution pour toute l'app (le lecteur de quota comme les deux
/// dépenses) : `byCoverage` en v0.16.1 et le `cwd` de `SkillCatalog` en v0.16.5
/// ont tous deux payé le fait qu'un savoir vive dans le code sans être branché
/// sur tous ses appels.
@MainActor
enum CodexExecutable {
    /// Réglage explicite de l'utilisateur (Réglages → Codex), prioritaire.
    static let overrideKey = "codexExecutablePath"

    private static var cached: String?
    private static var triedLoginResolve = false

    static func invalidateCache() {
        cached = nil
        triedLoginResolve = false
    }

    nonisolated private static let loginResolveTimeout: TimeInterval = 5

    static let notFoundMessage =
        "codex est introuvable — ajoute son dossier au PATH dans ~/.zprofile "
        + "(~/.zshrc n'est pas lu par les shells que lance une app), ou indique "
        + "son chemin dans Réglages → Codex"

    /// Chemin absolu exécutable, ou `nil`.
    static func resolve(overridePath: String? = nil) async -> String? {
        // Le réglage manuel court-circuite le cache : le changer doit AGIR, pas
        // attendre un redémarrage de l'app.
        let custom = overridePath ?? UserDefaults.standard.string(forKey: overrideKey) ?? ""
        if !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        if let cached { return cached }

        // Emplacements usuels : vérification CHEAP (aucun shell), retentée à
        // chaque appel — codex peut être installé après le lancement d'Atoll.
        let common = [
            ("~/.local/bin/codex" as NSString).expandingTildeInPath,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let found = common.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            cached = found
            return found
        }

        // Repli par shell de login : COÛTEUX (source le profil) → une seule fois.
        guard !triedLoginResolve else { return nil }
        triedLoginResolve = true
        let resolved = await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "command -v codex"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            armWatchdog(process)
            let data = BoundedProcessOutput.drain(pipe.fileHandleForReading, cap: 16_384)
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus == 0 && !path.isEmpty
                    && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
        }.value
        cached = resolved
        return resolved
    }

    /// Variante SYNCHRONE, pour le lecteur de quota qui tourne déjà hors UI et
    /// ne doit pas attendre un shell de login à chaque passage. Ne consulte que
    /// les emplacements usuels et le réglage manuel.
    static func resolveCheap() -> URL? {
        let custom = UserDefaults.standard.string(forKey: overrideKey) ?? ""
        let candidates = custom.isEmpty
            ? [("~/.local/bin/codex" as NSString).expandingTildeInPath,
               "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            : [(custom as NSString).expandingTildeInPath]
        let all = candidates + (custom.isEmpty ? (cached.map { [$0] } ?? []) : [])
        return all.first { path in
            var directory: ObjCBool = false
            return path.hasPrefix("/")
                && FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }.map { URL(fileURLWithPath: $0) }
    }

    nonisolated private static func armWatchdog(_ process: Process) {
        guard let identity = ProcessInspector.identity(of: process.processIdentifier) else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + loginResolveTimeout) {
            guard process.isRunning else { return }
            ProcessInspector.signal(SIGTERM, to: identity)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                ProcessInspector.signal(SIGKILL, to: identity)
            }
        }
    }
}
