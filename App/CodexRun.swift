import Foundation
import AtollCore
import os

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "codex-run")

/// Préparation d'une dépense d'Atoll sur l'abonnement Codex.
///
/// Les deux jobs (bilan de fin de session, rangement des notes) partagent
/// exactement le même besoin : un schéma sur disque, un fichier de sortie, et
/// une commande de shell de login. Ce type les fabrique une fois — sans quoi
/// deux copies auraient divergé, comme les quatre résolutions de `claude` que
/// la v0.16.6 a dû rattraper.
enum CodexRun {

    /// Ce qu'il faut pour lancer, et pour ranger après.
    struct Launch {
        let shellCommand: String
        /// Fichier où Codex écrit son dernier message. `nil` sur le chemin
        /// Claude, qui imprime sur stdout — c'est CE champ qui dit à l'appelant
        /// où lire, plutôt qu'un second test sur le fournisseur.
        let outputFile: URL?
        /// Dossier temporaire à effacer (schéma + sortie). `nil` = rien à faire.
        let workspace: URL?

        /// Le prompt et le rapport contiennent le condensé d'une session de
        /// travail : ils ne traînent pas dans `/tmp` après le run.
        func cleanUp() {
            guard let workspace else { return }
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    /// `nil` si `codex` est introuvable ou si les fichiers ne peuvent pas être
    /// écrits — fail-safe : mieux vaut ne rien lancer qu'un run sans schéma,
    /// dont la sortie serait de la prose et le rapport perdu.
    @MainActor
    static func prepare(schema: String, prompt: String,
                        workingDirectory: String?, label: String) async -> Launch? {
        guard let codex = await CodexExecutable.resolve() else {
            log.error("codex introuvable — \(CodexExecutable.notFoundMessage, privacy: .public)")
            return nil
        }
        // Le schéma d'Atoll est écrit pour Anthropic ; OpenAI le refuse en l'état
        // (mesuré : HTTP 400 `invalid_json_schema`). Traduction obligatoire.
        guard let strictSchema = CodexExecPlan.openAISchema(from: schema) else {
            log.error("schéma non convertible pour Codex — run abandonné")
            return nil
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-codex-\(label)-\(UUID().uuidString)", isDirectory: true)
        let schemaFile = workspace.appendingPathComponent("schema.json")
        let outputFile = workspace.appendingPathComponent("report.json")
        do {
            // 0700 : le condensé d'une session de travail n'est pas public, et
            // `/tmp` l'est. Même exigence que le backup de hooks en 0600.
            try FileManager.default.createDirectory(
                at: workspace, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try strictSchema.write(to: schemaFile, atomically: true, encoding: .utf8)
        } catch {
            log.error("préparation du run Codex impossible : \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: workspace)
            return nil
        }

        let arguments = CodexExecPlan.arguments(
            schemaPath: schemaFile.path, outputPath: outputFile.path,
            workingDirectory: workingDirectory) + [prompt]

        // Shell de LOGIN, comme pour Claude : il source le profil, dont dépend
        // l'authentification par abonnement. Mais le nom nu `codex` n'y est PAS
        // résolu (shell non interactif, ~/.zshrc jamais lu) — chemin absolu.
        //
        // `unset OPENAI_API_KEY` est le pendant exact de l'unset côté Claude :
        // une clé API dans l'environnement ferait payer à l'appel au lieu de
        // consommer l'abonnement, et c'est l'abonnement que l'utilisateur a
        // demandé à utiliser.
        let shellCommand = "unset OPENAI_API_KEY; exec "
            + FleetLaunch.shellQuote(codex) + " "
            + arguments.map(FleetLaunch.shellQuote).joined(separator: " ")
        return Launch(shellCommand: shellCommand, outputFile: outputFile, workspace: workspace)
    }
}
