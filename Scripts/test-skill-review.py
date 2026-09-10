#!/usr/bin/env python3
"""Exécute le vrai centre de revue avec un catalogue asynchrone contrôlé."""
import argparse
import os
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sabotage-stale-catalog", action="store_true")
parser.add_argument("--sabotage-stale-error", action="store_true")
parser.add_argument("--sabotage-loading", action="store_true")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
subprocess.run(["swift", "build", "--package-path", str(repo / "AtollCore")], check=True)
build = Path(subprocess.check_output(["swift", "build", "--package-path", str(repo / "AtollCore"), "--show-bin-path"], text=True).strip())
with tempfile.TemporaryDirectory(prefix="atoll-review-runtime-") as directory:
    root = Path(directory)
    home = root / "home"
    home.mkdir()
    codex = home / ".codex"
    codex.mkdir()
    source = root / "main.swift"
    source.write_text(r'''
import Foundation
import AtollCore
enum CodexPreview { @MainActor static var enabled = false }
enum CodexExecutable { static let overrideKey = "codexExecutablePath" }
enum AnalysisExecution {
    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
extension Notification.Name { static let atollShowSkillReview = Notification.Name("fixture-review") }
@MainActor enum CatalogProbe {
    static var pending: [CheckedContinuation<[CatalogEntry], Error>] = []
    static func load() async throws -> [CatalogEntry] { try await withCheckedThrowingContinuation { pending.append($0) } }
    static func finish(_ entries: [CatalogEntry]) { pending.removeFirst().resume(returning: entries) }
    static func fail() { pending.removeFirst().resume(throwing: AnalysisExecution.Failure("Erreur de l'ancien catalogue")) }
}
struct SkillDestination: Equatable {
    let provider: AgentProvider
    let home: URL
    let executableOverride: String
    var store: LearnedSkillStore { LearnedSkillStore(skillsRoot: home.appendingPathComponent("skills"), destination: provider) }
    @MainActor func catalog(project: URL?) async throws -> [CatalogEntry] { try await CatalogProbe.load() }
}
@main struct Main {
    @MainActor static func main() async throws {
        guard BridgePaths.homeDirectory.path == CommandLine.arguments[1] else { fatalError("Home non isolé") }
        let center = SkillReviewCenter()
        CodexPreview.enabled = true
        center.seedPreviewProposals()
        CodexPreview.enabled = false
        let proposal = center.proposals[1]
        let entry = CatalogEntry(id: "native-conversion", name: proposal.slug,
            description: proposal.description, kind: .userSkill, origin: "catalogue natif",
            isAvailable: true, path: URL(fileURLWithPath: "/fixture/native/SKILL.md"))
        func waitForCatalog() async throws {
            let end = Date().addingTimeInterval(3)
            while CatalogProbe.pending.isEmpty {
                guard Date() < end else { fatalError("Catalogue non demandé") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        var task = Task { await center.preloadCatalog(for: proposal) }
        try await waitForCatalog()
        precondition(center.catalogLoading == proposal.id)
        CatalogProbe.finish([entry])
        await task.value
        precondition(center.similarCapability(for: proposal)?.contains("native-conversion") == true, "antériorité non préchargée")
        precondition(center.catalogLoading == nil)
        print("PASS antériorité native visible avant le premier clic")

        task = Task { await center.preloadCatalog(for: proposal) }
        try await waitForCatalog()
        task.cancel()
        CatalogProbe.finish([])
        await task.value
        precondition(center.similarCapability(for: proposal) != nil, "catalogue annulé a écrasé la sélection")
        print("PASS réponse annulée ignorée")

        task = Task { await center.preloadCatalog(for: proposal) }
        try await waitForCatalog()
        let original = CodexPaths.homeURL
        let other = original.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        setenv("CODEX_HOME", other.path, 1)
        CatalogProbe.finish([])
        await task.value
        precondition(center.similarCapability(for: proposal) != nil, "ancien home a écrasé le catalogue")
        setenv("CODEX_HOME", original.path, 1)
        print("PASS réponse d'un ancien home ignorée")

        task = Task { await center.preloadCatalog(for: proposal) }
        try await waitForCatalog()
        setenv("CODEX_HOME", other.path, 1)
        CatalogProbe.fail()
        await task.value
        precondition(center.lastError == nil, "erreur périmée a écrasé le diagnostic")
        setenv("CODEX_HOME", original.path, 1)
        print("PASS erreur d'un ancien home ignorée")

        task = Task { await center.preloadCatalog(for: proposal) }
        try await waitForCatalog()
        CatalogProbe.finish([])
        await task.value
        precondition(center.similarCapability(for: proposal) == nil, "ancienne antériorité gardée après catalogue vide valide")
        print("PASS nouvelle lecture valide remplace l'ancienne")

        task = Task { await center.preloadCatalog(for: proposal) }
        try await waitForCatalog()
        task.cancel()
        let next = Task { await center.preloadCatalog(for: proposal) }
        while CatalogProbe.pending.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        CatalogProbe.finish([])
        await task.value
        precondition(center.catalogLoading == proposal.id, "ancienne tâche a effacé le chargement courant")
        CatalogProbe.finish([])
        await next.value
        precondition(center.catalogLoading == nil)
        print("PASS fin d'une ancienne lecture ne masque pas la suivante")
    }
}
''')
    center = repo / "App/SkillReviewCenter.swift"
    if args.sabotage_stale_catalog:
        altered = root / center.name
        text = center.read_text()
        needle = "guard !Task.isCancelled, proposals.contains(proposal), target == (try self.target(for: proposal.destination)) else { return }"
        assert text.count(needle) == 1
        altered.write_text(text.replace(needle, "guard proposals.contains(proposal), target == (try self.target(for: proposal.destination)) else { return }"))
        center = altered
    if args.sabotage_stale_error:
        altered = root / center.name
        text = center.read_text()
        needle = "guard !Task.isCancelled, proposals.contains(proposal), target == (try? self.target(for: proposal.destination)) else { return }"
        assert text.count(needle) == 1
        altered.write_text(text.replace(needle, "guard !Task.isCancelled, proposals.contains(proposal) else { return }"))
        center = altered
    if args.sabotage_loading:
        altered = root / center.name
        text = center.read_text()
        needle = "if catalogTicket == ticket { catalogLoading = nil }"
        assert text.count(needle) == 1
        altered.write_text(text.replace(needle, "if catalogLoading == proposal.id { catalogLoading = nil }"))
        center = altered
    binary = root / "review-test"
    command = ["swiftc", "-D", "DEBUG", "-parse-as-library", "-I", str(build / "Modules"), "-lsqlite3", str(source), str(center)]
    command += [str(path) for path in sorted((build / "AtollCore.build").glob("*.o"))]
    subprocess.run(command + ["-o", str(binary)], check=True)
    result = subprocess.run([str(binary), str(home)], env=dict(os.environ, CFFIXED_USER_HOME=str(home), CODEX_HOME=str(codex)), capture_output=True, text=True, timeout=20)
    print(result.stdout, end="")
    if args.sabotage_stale_catalog:
        assert result.returncode != 0 and "catalogue annulé a écrasé la sélection" in result.stderr, result.stderr
        print("PASS sabotage : réponse périmée détectée dans le centre réel")
    elif args.sabotage_stale_error:
        assert result.returncode != 0 and "erreur périmée a écrasé le diagnostic" in result.stderr, result.stderr
        print("PASS sabotage : erreur périmée détectée dans le centre réel")
    elif args.sabotage_loading:
        assert result.returncode != 0 and "ancienne tâche a effacé le chargement courant" in result.stderr, result.stderr
        print("PASS sabotage : chargement concurrent masqué détecté")
    elif result.returncode:
        raise SystemExit(result.stderr)
