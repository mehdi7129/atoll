import Foundation

/// Résolution du chemin ABSOLU de `claude`, pour les deux lanceurs qui dépensent
/// du quota : le bilan de fin de session et le rangement des notes.
///
/// POURQUOI CE TYPE EXISTE. Ces deux modules lançaient
/// `zsh -l -c "… exec claude …"` en comptant sur le PATH du shell — et leur
/// commentaire l'AFFIRMAIT, mot pour mot : « `claude` est résolu par le PATH du
/// shell ». C'est FAUX depuis une app GUI : `zsh -l -c` est un shell de login
/// NON INTERACTIF, il ne lit donc jamais `~/.zshrc` — or c'est là que
/// l'installeur natif de Claude Code fait ajouter `~/.local/bin`.
/// MESURÉ le 2026-08-24 : `env -i zsh -l -c 'command -v claude'` → introuvable,
/// et « Ranger maintenant » rendait « l'analyse a échoué (exit 127) —
/// zsh:1: command not found: claude ».
///
/// Le shell de login est CONSERVÉ chez les appelants : il source le profil (dont
/// dépend l'auth par souscription) et sans lui le process est muet depuis une
/// app GUI. Seul le nom nu `claude` cède la place à un chemin absolu déjà
/// vérifié exécutable.
///
/// `FleetPoller`, `FleetLauncher` et `PluginInventory` portent chacun leur propre
/// copie de cette résolution. Elles FONCTIONNENT et ne sont pas touchées ici :
/// les fusionner est un remaniement, pas un correctif.
@MainActor
enum ClaudeExecutable {
    /// Retenu une fois trouvé : l'installeur natif ne déplace que le lien
    /// symbolique, jamais son emplacement.
    private static var cached: String?
    /// Le repli par shell de login coûte un sourcing de profil : UNE seule fois.
    private static var triedLoginResolve = false

    nonisolated private static let loginResolveTimeout: TimeInterval = 5

    /// Message rendu à l'utilisateur quand la résolution échoue. Il NOMME la
    /// cause et le geste : « exit 127 » n'apprenait rien à personne.
    static let notFoundMessage =
        "claude est introuvable — ajoute son dossier au PATH dans ~/.zprofile "
        + "(~/.zshrc n'est pas lu par les shells que lance une app)"

    /// Chemin absolu exécutable, ou `nil` si `claude` reste introuvable.
    static func resolve() async -> String? {
        if let cached { return cached }
        // Chemin usuel de l'installeur natif : vérif CHEAP (pas de shell),
        // retentée à chaque appel — claude peut apparaître après coup.
        let common = ("~/.local/bin/claude" as NSString).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: common) {
            cached = common
            return common
        }
        // Repli par login shell : COÛTEUX (source le profil) → exactement une
        // fois. Ne pas répéter un échec à chaque fin de session.
        guard !triedLoginResolve else { return nil }
        triedLoginResolve = true
        let resolved = await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "command -v claude"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            armWatchdog(process)
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus == 0 && !path.isEmpty
                    && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
        }.value
        cached = resolved
        return resolved
    }

    /// Tue un process qui dépasse `loginResolveTimeout` (SIGTERM puis SIGKILL) :
    /// un profil qui pend ne doit pas geler le lanceur.
    nonisolated private static func armWatchdog(_ process: Process) {
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + loginResolveTimeout) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}
