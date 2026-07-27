import Foundation

/// Politique du mode auto-accept : quelles permissions Atoll peut approuver
/// automatiquement quand l'utilisateur a activé le réglage.
///
/// Garanties de sécurité (voir la revue adversariale) :
/// 1. Les règles `permissions.deny` et les hooks bloquants de l'utilisateur
///    s'exécutent AVANT le hook PermissionRequest — l'auto-accept ne peut donc
///    jamais les outrepasser (une demande refusée en amont n'arrive pas ici).
/// 2. Plans (ExitPlanMode) et questions (AskUserQuestion) : jamais auto-acceptés.
/// 3. Outils MCP (`mcp__…`) : jamais auto-acceptés (effets arbitraires, et
///    certains sont `requiresUserInteraction` — le CLI ignorerait notre allow).
/// 4. Bash : **allowlist**, pas blocklist. On n'auto-accepte QUE des commandes
///    dont chaque segment est un outil de dev reconnu et non destructeur. Toute
///    forme opaque (interpréteur `-c`, `$(...)`, `${IFS}`, `eval`, `base64|sh`,
///    substitution de process…) retombe en manuel — une blocklist de `rm` est
///    trivialement contournable (`/bin/rm`, `bash -c "rm -rf"`, `\rm`…).
///
/// Ces garanties décrivent le niveau AUTO uniquement. Le niveau Rockstar ne
/// passe pas par cette politique : il approuve tout ce qui atteint l'îlot et
/// suspend en plus les règles deny de l'utilisateur (RockstarPermissionsEditor).
public enum AutoAcceptPolicy {

    /// La demande peut-elle être approuvée automatiquement ?
    public static func isSafeToAutoAccept(toolName: String?, toolInputData: Data?) -> Bool {
        guard let toolName, !toolName.isEmpty else { return false }
        if toolName.hasPrefix("mcp__") { return false }
        switch toolName {
        case "ExitPlanMode", "AskUserQuestion":
            return false
        case "Bash":
            guard let toolInputData,
                  let input = (try? JSONSerialization.jsonObject(with: toolInputData)) as? [String: Any],
                  let command = input["command"] as? String, !command.isEmpty
            else { return false }
            return isSafeBashCommand(command)
        default:
            // Edit / Write / Read / Glob / Grep / NotebookEdit / TodoWrite / WebFetch…
            return true
        }
    }

    // MARK: - Bash

    /// Basenames d'outils considérés sûrs (dev quotidien : lecture, build, VCS,
    /// gestionnaires de paquets). Volontairement SANS shells, élévation de
    /// privilèges, gestion disque/process/système, ni suppression.
    static let safeCommands: Set<String> = [
        "ls", "ll", "la", "cat", "bat", "head", "tail", "wc", "nl", "grep", "egrep",
        "fgrep", "rg", "ag", "fd", "find", "echo", "printf", "pwd", "cd", "mkdir", "touch",
        "tree", "file", "stat", "which", "type", "whoami", "id", "hostname", "uname",
        "date", "printenv", "basename", "dirname", "realpath", "readlink", "sort",
        "uniq", "cut", "tr", "column", "jq", "yq", "diff", "cmp", "comm", "cp", "mv",
        "ln", "open", "test", "true", "false", "sleep", "seq", "sed", "awk", "tar",
        "zip", "unzip", "gzip", "gunzip",
        "git", "gh", "glab",
        "npm", "npx", "pnpm", "yarn", "bun", "bunx", "node", "deno", "tsx", "ts-node", "tsc",
        "python", "python3", "pip", "pip3", "poetry", "uv", "pipenv", "ruby", "gem", "bundle", "rake",
        "cargo", "rustc", "rustup", "go", "gofmt", "godoc",
        "swift", "swiftc", "xcodebuild", "xcrun", "xcodegen", "pod", "fastlane", "brew",
        "make", "cmake", "ninja", "gradle", "gradlew", "mvn", "ant",
        "eslint", "prettier", "biome", "jest", "vitest", "mocha", "pytest", "tox",
        "mypy", "ruff", "black", "isort", "flake8", "pylint", "clang-format", "rustfmt",
        "clang", "gcc", "g++", "cc",
        "curl", "wget", "http", "aria2c",
    ]

    /// Interpréteurs présents dans `safeCommands` parce qu'exécuter un FICHIER
    /// de projet est banal (`python3 build.py`), mais qui savent aussi exécuter
    /// du code passé en argument. Ce code-là est arbitraire : `node -e
    /// "require('fs').rmSync(…)"` efface un dossier sans qu'aucun mot de la
    /// commande ne paraisse dangereux (revue : la garde `-c` ne couvrait que
    /// les noms de shells, pas ces interpréteurs).
    /// `ts-node`/`tsx` acceptent `-e` et sont dans `safeCommands` (revue des
    /// corrections). `perl`/`php` n'y sont PAS — ils restent listés ici pour que
    /// la garde suive si on les y ajoutait un jour ; c'est sans effet aujourd'hui.
    static let inlineCodeInterpreters: Set<String> = [
        "python", "python3", "node", "deno", "bun", "ruby", "perl", "php",
        "ts-node", "tsx",
    ]

    /// Drapeaux d'exécution en ligne de ces interpréteurs.
    static let inlineCodeFlags: Set<String> = [
        "-c", "-e", "-E", "--eval", "-p", "--print", "--call", "-r",
    ]

    /// Lettres courtes d'exécution en ligne, pour les formes COLLÉES et les
    /// grappes (`-c'code'`, `-uc'code'`).
    private static let inlineCodeLetters: Set<Character> = ["c", "e", "E", "p", "r"]

    /// Lanceurs d'environnement : `uv run python -c …` cache l'interpréteur
    /// derrière `run`. La vraie commande est ce qui suit.
    static let environmentRunners: Set<String> = ["uv", "poetry", "pipenv", "rye", "hatch"]

    /// Ces arguments contiennent-ils un drapeau d'exécution en ligne ?
    ///
    /// DEUX pièges, tous deux trouvés par la revue des corrections :
    /// - la forme COLLÉE (`python3 -c'print(1)'`, `python3 -uc'…'`) produit un
    ///   token unique qui n'égale aucun drapeau connu — le garde-fou se
    ///   contournait donc en retirant une espace. Vérifié : ces formes
    ///   s'exécutent réellement ;
    /// - chercher dans TOUS les arguments renvoyait en manuel des commandes
    ///   ordinaires (`python3 -m pip install -e .`, où le `-e` appartient à
    ///   pip). On s'arrête donc au PREMIER argument qui n'est pas une option :
    ///   c'est le script, le module ou la sous-commande, et tout ce qui suit ne
    ///   concerne plus l'interpréteur.
    static func hasInlineCodeFlag(_ args: [String]) -> Bool {
        for arg in args {
            guard arg.hasPrefix("-"), arg.count > 1 else { return false } // fin des options
            if inlineCodeFlags.contains(arg) { return true }
            if arg.hasPrefix("--") {
                let head = String(arg.split(separator: "=", maxSplits: 1).first ?? "")
                if inlineCodeFlags.contains(head) { return true }
                continue
            }
            // Grappe courte : `-uc'code'`, `-c'code'`. On s'arrête à la première
            // lettre d'exécution rencontrée.
            for character in arg.dropFirst() {
                if inlineCodeLetters.contains(character) { return true }
                if !character.isLetter { break }   // début de la charge utile collée
            }
        }
        return false
    }

    /// Commandes dont le PROGRAMME est un argument nu, sans drapeau à repérer :
    /// `awk 'BEGIN{system("rm -rf ~/projet")}'`. Aucune analyse fiable n'est
    /// possible sans écrire un interpréteur awk — donc jamais en automatique.
    static let programAsArgumentCommands: Set<String> = ["awk", "gawk", "mawk", "nawk"]

    /// Sous-commandes git destructrices → toujours manuel.
    static let safeGitSubcommands: Set<String> = [
        "status", "diff", "log", "show", "add", "commit", "branch", "fetch", "pull",
        "stash", "tag", "remote", "config", "rev-parse", "describe", "blame",
        "ls-files", "ls-remote", "symbolic-ref", "switch", "restore", "checkout",
        "merge", "rebase", "cherry-pick", "init", "clone", "mv", "revert", "reflog",
        "worktree", "apply", "format-patch", "shortlog", "whatchanged", "grep",
        "cat-file", "bisect", "notes", "submodule", "for-each-ref", "rev-list",
        "name-rev", "show-ref", "archive", "count-objects", "fsck", "push",
    ]

    public static func isSafeBashCommand(_ raw: String) -> Bool {
        // Continuations backslash-newline → espaces (le scan reste mono-ligne sûr).
        let command = raw.replacingOccurrences(of: "\\\n", with: " ")

        // 1. Rejet structurel : tout ce qui rend la commande opaque à l'analyse.
        if containsOpaqueConstruct(command) { return false }

        // 2. Chaque segment (séparé par && || | ; & retour-ligne) doit être sûr.
        let segments = command
            .components(separatedBy: CharacterSet(charactersIn: "\n"))
            .flatMap { splitOnOperators($0) }
        let meaningful = segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !meaningful.isEmpty else { return false }
        return meaningful.allSatisfy { isSafeSegment($0) }
    }

    // MARK: - Interne

    /// Constructions qui rendent la commande impossible à analyser sûrement.
    private static func containsOpaqueConstruct(_ command: String) -> Bool {
        if command.contains("$(") || command.contains("`") { return true }   // substitution de commande
        if command.contains("${") { return true }                            // expansion (${IFS}…)
        if command.contains("<(") || command.contains(">(") { return true }  // substitution de process
        // Redirection vers un périphérique / chemin système.
        if command.range(of: #">\s*/(dev|etc|System|usr|bin|sbin)\b"#,
                         options: [.regularExpression]) != nil { return true }
        // Mots-clés dangereux (élévation, décodage-puis-exécution, interpréteurs).
        let opaqueWords = #"\b(sudo|doas|su|eval|exec|source|xargs|base64|base32|xxd|uudecode|openssl|nc|ncat|osascript|env)\b"#
        if command.range(of: opaqueWords, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        // Interpréteur avec -c (commande interne masquée).
        if command.range(of: #"\b(sh|bash|zsh|dash|ksh|fish|csh|tcsh|nohup|nice|time|timeout|watch|script)\b[^\n]*\s-c\b"#,
                         options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }

    /// Découpage délégué à `ShellSplitter` — une seule implémentation, testée,
    /// partagée avec la détection des hooks sonores (les deux avaient la leur,
    /// et aucune ne voyait les guillemets).
    static func splitOnOperators(_ segment: String) -> [String] {
        ShellSplitter.segments(segment, splitOnNewlines: false)
    }

    private static func isSafeSegment(_ segment: String, depth: Int = 0) -> Bool {
        var tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Préfixes d'affectation d'environnement : VAR=value cmd…
        while let first = tokens.first, first.range(of: #"^\w+=[^\s]*$"#, options: [.regularExpression]) != nil {
            tokens.removeFirst()
        }
        guard var name = tokens.first else { return false }
        // Retire un backslash de tête (contournement d'alias : \rm) et le chemin.
        if name.hasPrefix("\\") { name.removeFirst() }
        name = (name as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("-") else { return false }

        if name == "git" {
            return isSafeGit(Array(tokens.dropFirst()))
        }
        // `awk` & co : le programme EST l'argument, aucun drapeau ne le trahit.
        if programAsArgumentCommands.contains(name) { return false }

        guard safeCommands.contains(name) else { return false }

        let args = Array(tokens.dropFirst())

        // Lanceur d'environnement : la vraie commande est APRÈS `run`.
        // `uv run python -c '…'` présentait `uv` en tête, et le garde-fou des
        // interpréteurs ne voyait donc rien (revue des corrections).
        if environmentRunners.contains(name), args.first == "run", depth < 2 {
            return isSafeSegment(args.dropFirst().joined(separator: " "), depth: depth + 1)
        }

        // Interpréteur + code en ligne = exécution arbitraire déguisée. On juge
        // ici, sur le segment, plutôt que par une regex sur la commande entière :
        // `grep -e node` ne doit pas être pris pour du `node -e`.
        if inlineCodeInterpreters.contains(name), hasInlineCodeFlag(args) { return false }
        // `deno eval "…"` passe par une sous-commande, pas par un drapeau.
        if name == "deno", args.first == "eval" { return false }

        // Lanceurs npx/bunx/dlx/exec : la commande réelle est le PAQUET, pas le
        // lanceur. `npx rimraf dist` est destructeur même si `npx` est sûr.
        if let package = launchedPackage(command: name, args: args) {
            return safePackage(package)
        }

        // Garde-fou d'arguments pour les outils sûrs mais capables de détruire.
        if name == "find", args.contains(where: { $0 == "-delete" || $0 == "-exec" || $0 == "-execdir" || $0 == "-ok" }) {
            return false
        }
        return true
    }

    /// Paquets réputés destructeurs, exécutés via un lanceur → jamais auto-acceptés.
    static let destructivePackages: Set<String> = [
        "rimraf", "rimraf2", "del", "del-cli", "trash", "trash-cli", "empty-trash-cli",
        "rm-cli", "shx", "rmrf", "fkill", "fkill-cli",
    ]

    /// Extrait le paquet exécuté par un lanceur (npx/bunx/pnpm dlx/yarn dlx/npm exec).
    /// nil si `command` n'est pas un lanceur.
    private static func launchedPackage(command: String, args: [String]) -> String? {
        var rest = args[...]
        switch command {
        case "npx", "bunx":
            break // le paquet est le 1er argument non-option
        case "npm", "pnpm", "yarn", "bun":
            // Sous-commande dlx / exec / x, puis le paquet.
            guard let sub = rest.first, ["dlx", "exec", "x"].contains(sub) else { return nil }
            rest = rest.dropFirst()
        default:
            return nil
        }
        // Sauter les options du lanceur (-y, --yes, -p pkg, --package pkg…).
        while let first = rest.first, first.hasPrefix("-") {
            let flag = first
            rest = rest.dropFirst()
            if flag == "-p" || flag == "--package" || flag == "-c" || flag == "--call" {
                if !rest.isEmpty { rest = rest.dropFirst() }
            }
        }
        guard let package = rest.first else { return nil }
        return Self.normalizePackage(package)
    }

    /// `[@scope/]name[@version]` → `name`. Ex. `@org/rimraf@1.2` → `rimraf`.
    static func normalizePackage(_ spec: String) -> String {
        var pkg = spec
        // Retirer une version en fin (@ qui n'est pas le @ de scope en tête).
        if let at = pkg.dropFirst().firstIndex(of: "@") {
            pkg = String(pkg[..<at])
        }
        // Retirer le scope (tout ce qui précède le dernier /).
        if let slash = pkg.lastIndex(of: "/") {
            pkg = String(pkg[pkg.index(after: slash)...])
        }
        return pkg
    }

    private static func safePackage(_ package: String) -> Bool {
        !destructivePackages.contains(package)
    }

    /// git : saute les options globales (-C path, -c k=v, --git-dir=…) puis vérifie
    /// la sous-commande et rejette les variantes destructrices.
    private static func isSafeGit(_ rawArgs: [String]) -> Bool {
        var args = rawArgs[...]
        while let first = args.first, first.hasPrefix("-") {
            let flag = first
            args = args.dropFirst()
            // Options à valeur séparée.
            if flag == "-C" || flag == "-c" || flag == "--git-dir" || flag == "--work-tree" || flag == "--namespace" {
                if !args.isEmpty { args = args.dropFirst() }
            }
        }
        guard let subcommand = args.first, safeGitSubcommands.contains(subcommand) else { return false }
        let rest = Array(args.dropFirst())

        switch subcommand {
        case "push":
            // Force-push sous toutes ses formes.
            if rest.contains(where: { $0 == "--force" || $0 == "-f" || $0 == "--force-with-lease" || $0.hasPrefix("+") }) {
                return false
            }
        case "reset":
            if rest.contains("--hard") { return false }
        case "clean":
            return false // supprime des fichiers non suivis
        default:
            break
        }
        return true
    }
}
