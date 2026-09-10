#!/usr/bin/env python3
"""Vérifie les correctifs Core de la review, puis les sabote en copie temporaire.

Aucun fichier de travail ni donnée utilisateur n'est modifié. Une compilation
ratée ne compte jamais comme une régression détectée.
"""
import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--only", action="append")
args = parser.parse_args()
mutations = {
    "finder-metadata": ("LearnedSkillStore.swift", 'return $0 == ".DS_Store" &&', 'return $0 == ".never-allowed" &&',
                        "SkillDestinationTests/testFinderMetadataDoesNotBlockApprovalButIsNeverInstalled"),
    "quota-freshness": ("ProviderFailover.swift", "freshnessSeconds: TimeInterval = 600,", "freshnessSeconds: TimeInterval = 900,",
                        "ProviderFailoverTests/testDefaultFailoverRejectsClaudeMeasurementsOlderThanTheAnalysisGate"),
    "row-budget": ("SessionGrouping.swift", " - (providerSelectorShown ? 1 : 0)", "",
                   "IslandRowPlanTests/testProviderSelectorReservesSpaceAndAnnouncesOverflow"),
    "anonymous-resume": ("CodexIntegration.swift", "certainlyClosed ? .closed : .unknown", "certainlyClosed ? .closed : .closed",
                         "CodexReliabilityTests/testSessionEndKeepsAnonymousActivityUnknownWithoutResurrectingState"),
    "closure-expiry": ("CodexIntegration.swift", "now.timeIntervalSince($0.value.at) < Self.closedSessionRetention", "now.timeIntervalSince($0.value.at) < .infinity",
                       "CodexReliabilityTests/testAnonymousClosureExpiresWithoutResurrectingASessionByItself"),
    "hook-customizations": ("CodexIntegration.swift", "if timeout == 3 && oldTelemetryShape {", "if true {",
                            "CodexSetupTests/testMigrationPreservesRemovedEventsCustomTimeoutAndFormatting"),
    "hook-short-customization": ("CodexIntegration.swift", "if timeout == 3 && oldTelemetryShape {", "if timeout == 3 {",
                                "CodexSetupTests/testMigrationPreservesShortTimeoutWhenHandlerIsCustomized"),
    "hook-removals": ("CodexHookInstallation.swift", "CodexHookSettingsEditor.migrate(data)", "CodexHookSettingsEditor.edit(data, install: true)",
                      "CodexSetupTests/testMigrationPreservesRemovedEventsCustomTimeoutAndFormatting"),
    "client-envelopes": ("CodexTranscriptParser.swift", '"<task-notification>", "<realtime_delegation>",', "",
                         "CodexMemoryTests/testClientEnvelopesPreserveHumanSuffixAndQuotes"),
    "inline-envelopes": ("CodexTranscriptParser.swift", "if let end = inlineClientEnvelopeEnd(in: text) {", "if let end: String.Index = nil {",
                         "CodexMemoryTests/testClientEnvelopesPreserveHumanSuffixAndQuotes"),
    "partial-snapshot": ("MemoryIndex.swift", "if !complete {", "if false {",
                         "CodexMemoryTests/testIncompleteSnapshotIsRemovedAndExistingDestinationNeverOverwritten"),
    "handoff-installation": ("SessionHandoff.swift", 'let executable, executable.hasPrefix("/") else { return false }',
                             'let executable, executable.hasPrefix("/") else { return false }; return true; /*',
                             "SessionHandoffTests/testHandoffRequiresExistingDirectoryAndExecutableAndRechecksRemoval"),
}
selected = args.only or list(mutations)
if any(key not in mutations for key in selected):
    parser.error("Sabotage inconnu")

with tempfile.TemporaryDirectory(prefix="atoll-review-sabotage-") as folder:
    root = Path(folder)
    package = root / "AtollCore"
    shutil.copytree(repo / "AtollCore", package, ignore=shutil.ignore_patterns(".build", ".swiftpm", ".DS_Store"))
    (root / "docs").symlink_to(repo / "docs", target_is_directory=True)
    command = ["swift", "test", "--package-path", str(package), "--filter"]
    filters = "|".join(sorted(set(mutations[name][3] for name in selected)))
    baseline = subprocess.run(command + [filters], capture_output=True, text=True, timeout=180)
    if baseline.returncode:
        raise SystemExit("Tests de base non verts :\n" + baseline.stdout + baseline.stderr)
    print("PASS tests de base avant sabotage", flush=True)
    for name in selected:
        file, needle, replacement, case = mutations[name]
        path = package / "Sources/AtollCore" / file
        original = path.read_text()
        if original.count(needle) != 1:
            raise SystemExit("Couture introuvable ou ambiguë : " + name)
        changed = original.replace(needle, replacement)
        if name == "handoff-installation":
            changed = changed.replace("return fm.isExecutableFile(atPath: executable)", "return fm.isExecutableFile(atPath: executable) */")
        try:
            path.write_text(changed)
            result = subprocess.run(command + [case], capture_output=True, text=True, timeout=120)
            output = result.stdout + result.stderr
            if result.returncode == 0 or "Test Case" not in output or " failed" not in output or "error: emit-module" in output:
                raise SystemExit("Sabotage non détecté par le test : " + name + "\n" + output)
            print("PASS sabotage " + name, flush=True)
        finally:
            path.write_text(original)
