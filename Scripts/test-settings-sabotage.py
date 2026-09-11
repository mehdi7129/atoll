#!/usr/bin/env python3
"""Vérifie les assertions UI sur cinq défauts compilés volontairement.

Copies temporaires et aperçus protégés uniquement. Un échec de compilation ou
un incident du harnais ne compte jamais comme une régression détectée.
--mutation focus ajoute un contrôle ciblé, avec la navigation clavier macOS activée.
"""
import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
mutations = {
    "model": (
        "App/CodexAnalysisModelPicker.swift",
        "case .available(let values): models = values; loaded = true",
        'case .available(let values): models = values; loaded = true\n            if selection.isEmpty { selection = values.first?.model ?? "" }',
        "settings-analysis", "choix du modèle inattendu",
    ),
    "recall": (
        "App/MemorySettingsSection.swift", "if !enabled, proactive {", "if false, proactive {",
        "settings-memory-off", "rappel resté actif",
    ),
    "sounds": (
        "App/SoundSettingsView.swift", "ForEach(SoundEvent.allCases, id:",
        "ForEach(hooksInstalled ? SoundEvent.allCases : [], id:",
        "settings-alerts", "Tour terminé",
    ),
    "missing-sound": (
        "App/SoundSettingsView.swift", "choice(event).isSilent || missingCustom != nil", "choice(event).isSilent",
        "settings-alerts-missing", "écoute active pour un événement muet",
    ),
    "navigation": (
        "App/SettingsView.swift", 'selectedTab = "apprentissage"', 'selectedTab = "codex"',
        "settings-codex-model-shared", "raccourci : choix du modèle inaccessible",
    ),
    "focus": (
        "App/CodexAnalysisModelPicker.swift", "modelFocused = true", "modelFocused = false",
        "settings-codex-model-focus", "le raccourci n'a pas donné le focus au modèle",
    ),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--mutation", action="append", choices=mutations)
args = parser.parse_args()
args.output = args.output.resolve()
args.output.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="atoll-settings-mutants-") as directory:
    root = Path(directory)
    files = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=repo
    ).decode().split("\0")
    for name in filter(None, files):
        source = repo / name
        if source.is_file():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    originals = {row[0]: (root / row[0]).read_text() for row in mutations.values()}
    subprocess.run(["xcodegen", "generate"], cwd=root, check=True, stdout=subprocess.DEVNULL)
    derived = root / "DerivedData"
    results = []
    for mutation in args.mutation or [name for name in mutations if name != "focus"]:
        for name, content in originals.items():
            (root / name).write_text(content)
        name, needle, replacement, case, expected_failure = mutations[mutation]
        source = root / name
        content = source.read_text()
        assert content.count(needle) == 1, (mutation, "point de mutation ambigu")
        source.write_text(content.replace(needle, replacement))
        output = args.output / mutation
        output.mkdir(parents=True, exist_ok=True)
        with (output / "build.log").open("w") as log:
            subprocess.run(["xcodebuild", "-project", "Atoll.xcodeproj", "-scheme", "Atoll",
                            "-configuration", "Debug", "-derivedDataPath", str(derived), "build"],
                           cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
        app = Path("/private/tmp") / f"Atoll-settings-mutant-{os.getpid()}-{mutation}.app"
        subprocess.run(["python3", str(repo / "Scripts/prepare-preview.py"),
                        str(derived / "Build/Products/Debug/Atoll.app"), str(app)], check=True)
        subprocess.run(["python3", str(repo / "Scripts/test-ui.py"), "--app", str(app),
                        "--output", str(output), "--case", case, "--expect-failure"], check=True)
        observed = json.loads((output / "results.json").read_text())
        assert any(expected_failure in failure for row in observed for failure in row["failures"]), observed
        results.append({"mutation": mutation, "case": case, "detected": True,
                        "failure": expected_failure})
        (args.output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
        print("PASS " + mutation + " : défaut compilé et détecté", flush=True)
