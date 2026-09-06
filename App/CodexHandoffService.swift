import AppKit
import Foundation
import AtollCore
import os

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "codex-handoff")

/// « CONTINUER DANS CODEX » : prépare la reprise d'une session Claude sur
/// l'abonnement Codex, et ouvre un terminal dessus.
///
/// POURQUOI UN `.command` ET PAS UN APPLESCRIPT. Terminal.app exécute un
/// fichier exécutable qu'on lui ouvre, ce qui suffit ici et ne demande AUCUNE
/// permission d'automatisation — là où le jump-back a besoin de TCC pour
/// Terminal/iTerm2 (voir `TerminalJumpService`). Un geste de moins à accorder,
/// et un chemin de moins à voir échouer silencieusement.
///
/// POURQUOI PAS DANS LE TERMINAL DE LA SESSION. Les sessions de Mehdi tournent
/// dans le terminal intégré de Cursor : rien ne permet d'y injecter une
/// commande. Le handoff ouvre donc un terminal À CÔTÉ, dans le même dossier.
@MainActor
enum CodexHandoffService {

    enum Outcome: Sendable {
        case opened(URL)
        case failed(String)
    }

    /// Racine des passations. Sous `~/.atoll`, comme tout ce qu'Atoll écrit.
    static var directory: URL {
        BridgePaths.homeDirectory.appendingPathComponent(".atoll/handoff", isDirectory: true)
    }

    /// Écrit les deux fichiers puis ouvre le script avec Terminal.app.
    ///
    /// `digest` est calculé par l'appelant : c'est lui qui sait lire le
    /// transcript, et ce type ne doit pas dépendre du format JSONL.
    static func start(session: AgentSession, digest: String) -> Outcome {
        let files = SessionHandoff.make(
            projectName: session.projectName,
            workingDirectory: session.cwd,
            gitBranch: session.gitBranch,
            digest: digest,
            endedAt: Date()
        )

        // Un dossier par session, remplacé à chaque fois : deux reprises de la
        // même session ne doivent pas empiler des contextes contradictoires.
        let safeID = session.id.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let workspace = directory.appendingPathComponent(safeID, isDirectory: true)
        let contextFile = workspace.appendingPathComponent("contexte.md")
        let scriptFile = workspace.appendingPathComponent("reprendre.command")

        do {
            // 0700 : le condensé, c'est le contenu d'une session de travail.
            try FileManager.default.createDirectory(
                at: workspace, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try files.contextMarkdown.write(to: contextFile, atomically: true, encoding: .utf8)
            try files.launcherScript.write(to: scriptFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: scriptFile.path)
        } catch {
            log.error("passation Codex impossible : \(error.localizedDescription, privacy: .public)")
            return .failed("impossible d'écrire la passation (\(error.localizedDescription))")
        }

        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal") else {
            return .failed("Terminal.app est introuvable")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([scriptFile], withApplicationAt: terminal,
                                configuration: configuration) { _, error in
            if let error {
                log.error("ouverture du terminal : \(error.localizedDescription, privacy: .public)")
            }
        }
        log.info("passation Codex préparée pour \(session.id, privacy: .public)")
        return .opened(workspace)
    }
}
