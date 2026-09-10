#!/usr/bin/env python3
"""Compile les runners réels avec des collaborateurs contrôlés, sans app ni compte."""
from pathlib import Path
import os
import sys
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
if sum(argument.startswith("--sabotage-") for argument in sys.argv) > 1:
    raise SystemExit("Tester un sabotage à la fois.")
subprocess.run(["swift", "build", "--package-path", str(repo / "AtollCore")], check=True)
build = Path(subprocess.check_output(
    ["swift", "build", "--package-path", str(repo / "AtollCore"), "--show-bin-path"],
    text=True).strip())
with tempfile.TemporaryDirectory(prefix="atoll-runtime-") as directory:
    root = Path(directory)
    binary = root / "runtime-tests"
    command = ["swiftc", "-swift-version", "5", "-D", "DEBUG", "-parse-as-library",
               "-I", str(build / "Modules"), "-lsqlite3",
               str(repo / "App/RetrospectiveRunner.swift"),
               str(repo / "App/NotesCurationService.swift"),
               str(repo / "App/CodexInteractionCenter.swift"),
               str(repo / "App/AnalysisExecution.swift"),
               str(repo / "App/PluginInventory.swift"),
               str(repo / "Scripts/runtime-tests/Stubs.swift"),
               str(repo / "Scripts/runtime-tests/Main.swift")]
    if "--sabotage-cancellation" in sys.argv:
        for relative in ["App/RetrospectiveRunner.swift", "App/NotesCurationService.swift"]:
            original = repo / relative
            sabotaged = root / original.name
            sabotaged.write_text(original.read_text().replace("runGeneration == generation", "true"))
            command[command.index(str(original))] = str(sabotaged)
    if "--sabotage-quota-projection" in sys.argv:
        original = repo / "App/AnalysisExecution.swift"
        sabotaged = root / original.name
        content = original.read_text()
        needle = "quota: provider == .codex ? ProviderFailover.quotaFacts(of: CodexService.shared.quota) : claude,"
        if needle not in content:
            raise SystemExit("Couture de projection introuvable : adapter le sabotage.")
        sabotaged.write_text(content.replace(needle,
            "quota: provider == .codex ? (CodexService.shared.quota?.isFresh(at: Date()) == true ? ProviderFailover.quotaFacts(of: CodexService.shared.quota) : .init(usedFraction: nil, receivedAt: nil, resetsAt: nil)) : claude,"))
        command[command.index(str(original))] = str(sabotaged)
    expected_failure = None
    mutations = {
        "--sabotage-launch-retro": (
            "App/RetrospectiveRunner.swift", "try AnalysisBudget.shared.prepareToLaunch(lease)", "",
            "intention de spawn non persistée : retro-claude-nominal"),
        "--sabotage-launch-curation": (
            "App/NotesCurationService.swift", "try AnalysisBudget.shared.prepareToLaunch(lease)", "",
            "intention de spawn non persistée : curation-claude-nominal"),
        "--sabotage-launch-search": (
            "App/PluginInventory.swift", "try AnalysisBudget.shared.prepareToLaunch(lease)", "_ = lease",
            "intention de spawn non persistée : search-claude-nominal"),
        "--sabotage-curation-retry": (
            "App/NotesCurationService.swift", "if runLaunched || touched || !retry {", "if runLaunched || touched {",
            "curation sans travail relancée toutes les 30 minutes : empty"),
        "--sabotage-curation-journal": (
            "App/NotesCurationService.swift", "finish(outcome: error.localizedDescription, touched: false)", "phase = .idle",
            "curation.json"),
        "--sabotage-budget-recovery": (
            "App/AnalysisExecution.swift",
            'if records[i].outcome != "preparing" {', 'if true {',
            "reprise du budget incorrecte : retrospective/preparing"),
        "--sabotage-budget-admission": (
            "App/AnalysisExecution.swift",
            'do { try load() }\n        catch { return .analysisJournalUnreadable }', '',
            "reprise du budget incorrecte : retrospective/launching"),
        "--sabotage-capture-journal": (
            "App/RetrospectiveRunner.swift",
            '''journal(AttemptRecord(sessionID: job.snapshot.id, decidedAt: Date(),
                decision: "skip(configuration)", outcome: nil,
                transcriptBytes: job.snapshot.transcriptPath.flatMap {
                    (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.intValue
                }, quotaFraction: nil, quotaAgeSeconds: nil, failureReason: error.localizedDescription))''', '',
            "capture refusée sans trace persistée : modelMissing"),
    }
    for flag, (relative, needle, replacement, diagnostic) in mutations.items():
        if flag not in sys.argv:
            continue
        original = repo / relative
        content = original.read_text()
        if content.count(needle) != 1:
            raise SystemExit("Couture de sabotage introuvable ou ambiguë : " + flag)
        sabotaged = root / original.name
        sabotaged.write_text(content.replace(needle, replacement))
        command[command.index(str(original))] = str(sabotaged)
        expected_failure = diagnostic
    command += [str(path) for path in sorted((build / "AtollCore.build").glob("*.o"))]
    subprocess.run(command + ["-o", str(binary)], check=True)
    environment = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(root), ZDOTDIR=str(root))
    result = subprocess.run([str(binary)], env=environment, timeout=60, capture_output=True, text=True)
    print(result.stdout, end="")
    if "--sabotage-cancellation" in sys.argv:
        if result.returncode == 0 or "note après annulation" not in result.stderr:
            raise SystemExit("Sabotage non détecté par le scénario attendu : " + result.stderr)
        print("PASS sabotage : écriture après annulation détectée sur copie temporaire des runners.")
    elif "--sabotage-quota-projection" in sys.argv:
        if result.returncode == 0 or "capture a perdu le minorant Codex haut" not in result.stderr:
            raise SystemExit("Sabotage de projection non détecté par le scénario attendu : " + result.stderr)
        print("PASS sabotage : perte du minorant Codex détectée à la capture réelle, copie temporaire seulement.")
    elif expected_failure:
        if result.returncode == 0 or expected_failure not in result.stderr:
            raise SystemExit("Sabotage non détecté par le scénario attendu : " + result.stderr)
        print("PASS sabotage : " + expected_failure)
    elif result.returncode:
        raise SystemExit(result.stderr)
