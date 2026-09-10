#!/usr/bin/env python3
"""Rebuild isolé : reproduit les défauts de carte, d'accueil et de helper nu.

Le checkout de travail reste intact. Les assertions réutilisent les mêmes
recettes que le build corrigé ; une panne de compilation ne compte pas.
"""
import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="atoll-ui-mutant-") as folder:
    root = Path(folder)
    files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=repo).decode().split("\0")
    for name in filter(None, files):
        source = repo / name
        if not source.is_file():
            continue
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    # Layout de la carte avant R03, sous un scroll englobant comme à la review.
    old_card = subprocess.check_output(["git", "show", "f25fee6:App/CodexInteractionCardView.swift"], cwd=repo)
    (root / "App/CodexInteractionCardView.swift").write_bytes(old_card)
    path = root / "App/ExpandedView.swift"
    text = path.read_text()
    needle = "CodexInteractionCardView(request: request, colors: colors).id(selected)"
    assert text.count(needle) == 1
    path.write_text(text.replace(needle, "ScrollView { " + needle + " }.frame(maxWidth: .infinity, maxHeight: .infinity)"))
    path = root / "App/OnboardingView.swift"
    text = path.read_text()
    needle = "ProviderPreferences.shared.selection = provider"
    assert text.count(needle) == 1
    path.write_text(text.replace(needle, needle + '''
            if UserDefaults.standard.string(forKey: LearningSettings.analysisProviderKey) == nil {
                UserDefaults.standard.set(provider.rawValue, forKey: LearningSettings.analysisProviderKey)
            }'''))
    path = root / "Bridge/CodexBridge.swift"
    text = path.read_text()
    needle = "let helperURL = URL(fileURLWithPath: helperPath)"
    assert text.count(needle) == 1
    path.write_text(text.replace(needle, "let helperURL = URL(fileURLWithPath: CommandLine.arguments[0])"))
    subprocess.run(["xcodegen", "generate"], cwd=root, check=True, stdout=subprocess.DEVNULL)
    derived = root / "DerivedData"
    with (args.output / "build.log").open("w") as stream:
        subprocess.run(["xcodebuild", "-project", "Atoll.xcodeproj", "-scheme", "Atoll", "-configuration", "Debug",
                        "-derivedDataPath", str(derived), "build"], cwd=root, stdout=stream, stderr=subprocess.STDOUT, check=True)
    app = Path("/private/tmp") / ("Atoll-PR2-mutant-" + str(os.getpid()) + ".app")
    subprocess.run(["python3", str(repo / "Scripts/prepare-preview.py"), str(derived / "Build/Products/Debug/Atoll.app"), str(app)], check=True)
    for case in ["card-codex", "onboarding-unset"]:
        subprocess.run(["python3", str(repo / "Scripts/test-ui.py"), "--app", str(app), "--output", str(args.output / case),
                        "--case", case, "--expect-failure"], check=True)
    result = subprocess.run(["python3", str(repo / "Scripts/test-codex-install-recall.py"), str(app / "Contents/Helpers/atoll-bridge")],
                            capture_output=True, text=True)
    (args.output / "bare-helper.log").write_text(result.stdout + result.stderr)
    if result.returncode == 0 or "nom nu : helper réel perdu" not in result.stderr:
        raise SystemExit("Sabotage du helper nu non détecté : " + result.stderr)
    print("PASS sabotage helper nu ; copies UI conservées dans " + str(app))
