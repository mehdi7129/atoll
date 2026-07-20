import Foundation
import AtollCore

/// Verbe `recall` du helper : interroge l'index mémoire construit par l'app
/// (`~/.atoll/memory.db`, SQLite FTS5) et affiche les résultats. La sortie
/// texte est pensée pour être LUE PAR CLAUDE dans une session — le skill
/// « atoll-recall » lui enseigne quand appeler ce verbe et comment lire.
///
/// FAIL-OPEN ABSOLU (règle n° 1 du projet) : `run` retourne TOUJOURS 0.
/// Requête vide, index absent, base illisible ou recherche en échec produisent
/// un message court et informatif — jamais un code d'erreur, jamais un crash :
/// ce binaire tourne dans le chemin critique d'une session Claude Code.
enum RecallCLI {

    /// Options extraites des arguments. Tout argument ne commençant pas par
    /// `-` est un mot de la requête (joints par espace) — les guillemets shell
    /// sont donc facultatifs : `recall socket unix` vaut `recall "socket unix"`.
    private struct Options {
        var query = ""
        /// Nombre de résultats, borné 1…50 (défaut 8 : assez pour recouper,
        /// assez court pour ne pas noyer le contexte du modèle).
        var limit = 8
        /// Préfixe absolu de `project_path` pour restreindre à un projet.
        var projectPrefix: String?
        var json = false
    }

    /// Point d'entrée du verbe. `arguments` = tout ce qui suit `recall`.
    static func run(arguments: [String]) -> Int32 {
        let options = parse(arguments: arguments)
        guard !options.query.isEmpty else {
            print("usage : atoll-bridge recall \"mots clés\" [--limit N] [--project <chemin>] [--json]")
            print("        recherche plein-texte dans la mémoire des sessions Claude Code indexée par Atoll")
            return 0
        }

        let databaseURL = BridgePaths.memoryDatabaseURL
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            print("Aucun index mémoire (~/.atoll/memory.db absent). Ouvrez l'app Atoll pour construire l'index.")
            return 0
        }

        // readOnly d'abord (le bridge n'écrit jamais dans l'index) ; repli
        // readWrite si le fichier existe mais refuse un lecteur pur — cas réel :
        // base WAL jamais rouverte, fichier -shm manquant. Aucune création
        // possible ici : l'existence du fichier vient d'être vérifiée.
        let index: MemoryIndex
        if let readOnly = try? MemoryIndex(url: databaseURL, mode: .readOnly) {
            index = readOnly
        } else if let readWrite = try? MemoryIndex(url: databaseURL, mode: .readWrite) {
            index = readWrite
        } else {
            print("Index mémoire illisible (\(abbreviated(databaseURL.path))). Ouvrez l'app Atoll pour le reconstruire.")
            return 0
        }
        defer { index.close() }

        let hits: [MemoryIndex.Hit]
        do {
            hits = try index.search(rawQuery: options.query,
                                    limit: options.limit,
                                    projectPrefix: options.projectPrefix)
        } catch {
            print("Recherche impossible dans l'index mémoire — continuez sans.")
            return 0
        }

        if options.json {
            printJSON(hits: hits)
        } else {
            printText(hits: hits, query: options.query)
        }
        return 0
    }

    // MARK: - Arguments

    /// Parsing positionnel défensif : drapeau connu → consommé (avec sa valeur),
    /// drapeau inconnu → ignoré sans polluer la requête, valeur de `--limit`
    /// non numérique → défaut conservé. Rien ne peut faire échouer le parsing.
    private static func parse(arguments: [String]) -> Options {
        var options = Options()
        var words: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--limit":
                index += 1
                if index < arguments.count, let value = Int(arguments[index]) {
                    options.limit = min(max(value, 1), 50)
                }
            case "--project":
                index += 1
                if index < arguments.count {
                    options.projectPrefix = absolutePath(arguments[index])
                }
            case "--json":
                options.json = true
            default:
                if !argument.hasPrefix("-") {
                    words.append(argument)
                }
            }
            index += 1
        }
        options.query = words.joined(separator: " ")
        return options
    }

    /// Développe `~` puis rend le chemin absolu et standardisé (`.`/`..`
    /// résolus, relatif → depuis le cwd) : le filtre de l'index compare des
    /// PRÉFIXES de chemins absolus, un chemin relatif ne matcherait jamais.
    private static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardized.path
    }

    // MARK: - Sortie texte

    /// Format compact et scannable par le modèle :
    /// ```
    /// MÉMOIRE ATOLL — 2 résultat(s) pour « socket unix »
    /// 1. [2026-07-18 14:32] ~/Desktop/Dynamic_Island — « Titre de session »
    ///    (assistant) …extrait avec «termes» marqués…
    ///    session <uuid> · reprendre : claude --resume <uuid>
    /// ```
    private static func printText(hits: [MemoryIndex.Hit], query: String) {
        guard !hits.isEmpty else {
            print("Aucun résultat pour « \(query) ». Essayez d'autres mots-clés ou un préfixe (mot*).")
            return
        }
        print("MÉMOIRE ATOLL — \(hits.count) résultat(s) pour « \(query) »")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm" // heure LOCALE : celle que vit l'utilisateur
        for (offset, hit) in hits.enumerated() {
            let date = hit.timestamp.map { formatter.string(from: $0) } ?? "date inconnue"
            var header = "\(offset + 1). [\(date)] \(projectLabel(of: hit))"
            if let title = hit.title, !title.isEmpty {
                header += " — « \(title) »"
            }
            print(header)
            print("   (\(hit.role)) \(flattened(hit.snippet))")
            // Les notes d'apprentissage sont des pseudo-sessions : rien à reprendre.
            if hit.sessionID.hasPrefix("atoll-note-") {
                print("   note Atoll · ~/.atoll/learning/notes/")
            } else {
                print("   session \(hit.sessionID) · reprendre : claude --resume \(hit.sessionID)")
            }
        }
    }

    /// Chemin du projet abrégé avec `~` ; projet inconnu (session jamais vue
    /// avec un cwd) → le `project_dir` brut de `~/.claude/projects/`.
    private static func projectLabel(of hit: MemoryIndex.Hit) -> String {
        guard let path = hit.projectPath, !path.isEmpty else { return hit.projectDir }
        return abbreviated(path)
    }

    /// Remplace le préfixe home par `~` (jamais au milieu d'un composant :
    /// `/Users/mehdiguiard2/…` reste intact).
    private static func abbreviated(_ path: String) -> String {
        let home = BridgePaths.homeDirectory.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Aplatit un extrait sur une seule ligne : le format à trois lignes par
    /// résultat ne survit pas à un snippet multi-lignes.
    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    // MARK: - Sortie JSON

    /// Tableau d'objets `{sessionId, project, projectDir, title, date, role,
    /// snippet, resume}` — `.sortedKeys` (même pattern que `status()`) pour une
    /// sortie stable et diffable ; les absences sont des `null` explicites.
    private static func printJSON(hits: [MemoryIndex.Hit]) {
        let iso = ISO8601DateFormatter()
        let payload: [[String: Any]] = hits.map { hit in
            [
                "sessionId": hit.sessionID,
                "project": jsonValue(hit.projectPath),
                "projectDir": hit.projectDir,
                "title": jsonValue(hit.title),
                "date": jsonValue(hit.timestamp.map { iso.string(from: $0) }),
                "role": hit.role,
                "snippet": hit.snippet,
                "resume": jsonValue(hit.sessionID.hasPrefix("atoll-note-")
                    ? nil : "claude --resume \(hit.sessionID)"),
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    /// nil → NSNull : JSONSerialization ne sait pas encoder un Optional Swift.
    private static func jsonValue(_ string: String?) -> Any {
        if let string { return string }
        return NSNull()
    }
}
