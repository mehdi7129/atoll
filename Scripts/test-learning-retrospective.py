#!/usr/bin/env python3
"""Livraison, reprise et matière inchangée : vrais runners, CLI fictifs."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sabotage", choices=["checkpoint", "counts", "material", "dedup", "reader", "usage", "digest-metrics", "journal-revision", "off", "migration", "recovery-after-stop"])
parser.add_argument("--build-dir", type=Path, help="Réutiliser un produit Core Debug existant.")
args = parser.parse_args()
mutations = {
    "journal-revision": ("journalRevision &+= 1", "journalRevision &+= 0", "journal non notifié", 1),
    "usage": ("AnalysisBudget.shared.recordUsage(lease, stdout: output)", "()", "usage du runner absent du journal", 1),
    "digest-metrics": ("AnalysisBudget.shared.updateMetrics(lease, digestFragmentsShortened: digest.fragmentsShortened,\n            digestEntriesDropped: digest.entriesDropped, digestSourceReadStopped: digest.sourceReadStopped)",
                       "()", "mesures du lecteur absentes du journal", 1),
    "reader": ("sourceReadStopped: readBytes >= byteCap || lines.count >= lineCap", "sourceReadStopped: false", "bornes du lecteur non signalées", 1),
    "checkpoint": ("try deliveryStore.save(delivery)", "()", "sortie payée non sauvegardée", 1),
    "counts": ("pendingAttempt?.skillsProposed = delivery.skillsProposed", "pendingAttempt?.skillsProposed = report.skills.count", "compteurs de succès inventés après échec", 2),
    "material": ("if !job.forced, loadState().materials.contains(where:", "if false, loadState().materials.contains(where:", "matière identique réanalysée", 1),
    "dedup": ("let filtered = novelReport(report, project: job.snapshot.cwd, destination: destination)", "let filtered = report", "doublons de sortie non filtrés", 1),
    "recovery-after-stop": ("self.recoverPendingDeliveries()", "()", "ON pendant arrêt", 1),
    "off": ("LearningSettings.shared.isEnabled && generationAllowed()", "generationAllowed()", "OFF ou migration", 1),
    "migration": ("LearningSettings.shared.isEnabled && generationAllowed()", "LearningSettings.shared.isEnabled", "OFF ou migration", 1),
}
if args.build_dir:
    build = args.build_dir.resolve()
else:
    base = ["--package-path", str(repo / "AtollCore"), "--build-system", "native"]
    subprocess.run(["swift", "build", *base, "--jobs", "4"], check=True)
    build = Path(subprocess.check_output(["swift", "build", *base, "--show-bin-path"], text=True).strip())

with tempfile.TemporaryDirectory(prefix="atoll-retrospective-regression-") as name:
    root = Path(name)
    source = repo / "App/RetrospectiveRunner.swift"
    expected = None
    if args.sabotage:
        needle, replacement, expected, count = mutations[args.sabotage]
        text = source.read_text()
        if text.count(needle) != count:
            raise SystemExit("Couture de sabotage absente ou ambiguë : " + args.sabotage)
        source = root / "RetrospectiveRunner.swift"
        source.write_text(text.replace(needle, replacement))
    binary = root / "retrospective-tests"
    command = ["swiftc", "-swift-version", "5", "-D", "DEBUG", "-parse-as-library",
               "-I", str(build / "Modules"), "-lsqlite3", str(source),
               str(repo / "App/AnalysisExecution.swift"),
               str(repo / "Scripts/runtime-tests/Stubs.swift"), str(repo / "Scripts/learning-tests/RetrospectiveMain.swift"),
               *[str(p) for p in sorted((build / "AtollCore.build").glob("*.o"))], "-o", str(binary)]
    subprocess.run(command, check=True)
    scenarios = ["off-before", "migration-before", "off-wait", "off-digest", "migration-digest", "off-catalog", "migration-catalog", "off-cli",
                 "off-running", "on-while-stopping", "session-resumed", "legacy-mixed", "legacy-notes", "nominal", "note-context",
                 "blocked", "checkpoint", "unchanged", "changed", "corrupt-state", "digest-reader"]
    total = 0
    for provider in ["claude", "codex"]:
        for scenario in scenarios:
            fixture = root / (provider + "-" + scenario)
            fixture.mkdir()
            env = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(fixture), ZDOTDIR=str(fixture),
                       CFFIXED_USER_HOME=str(fixture), CODEX_HOME=str(fixture / ".codex"))
            steps = [scenario] + (["recover"] if scenario == "blocked" else [])
            for step in steps:
                result = subprocess.run([str(binary), step, provider], env=env, capture_output=True, text=True, timeout=20)
                if result.returncode:
                    if expected and expected in result.stderr:
                        print("PASS sabotage : " + expected)
                        raise SystemExit(0)
                    raise SystemExit(result.stdout + result.stderr)
                print(result.stdout, end="")
                total += 1
            # Chaque scénario est indépendant ; conserver seulement sa sortie
            # évite de cumuler les gros transcripts de course digest sur disque.
            shutil.rmtree(fixture)
    if expected:
        raise SystemExit("Sabotage non détecté : " + expected)
    print(f"PASS {total} scénarios skills-only, aucun CLI génératif réel")
