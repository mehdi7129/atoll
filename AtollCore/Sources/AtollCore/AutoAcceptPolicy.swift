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

        // 2. Chaque segment (séparé par && || | ; retour-ligne) doit être sûr.
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

    private static func splitOnOperators(_ segment: String) -> [String] {
        segment.replacingOccurrences(of: "&&", with: "\u{1}")
            .replacingOccurrences(of: "||", with: "\u{1}")
            .replacingOccurrences(of: "|", with: "\u{1}")
            .replacingOccurrences(of: ";", with: "\u{1}")
            .components(separatedBy: "\u{1}")
    }

    private static func isSafeSegment(_ segment: String) -> Bool {
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
        guard safeCommands.contains(name) else { return false }

        let args = Array(tokens.dropFirst())

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
