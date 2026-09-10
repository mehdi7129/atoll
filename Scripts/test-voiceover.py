#!/usr/bin/env python3
"""Recette des annonces VoiceOver sur une copie Debug protégée.

Prérequis : VoiceOver et son contrôle AppleScript déjà autorisés et activés.
Ce script ne change aucune permission ni préférence VoiceOver. Il ouvre des
cartes fictives, parcourt le curseur natif et vérifie les phrases réellement
émises ; la synthèse audio elle-même n'est pas enregistrée.
"""
import argparse
import json
import plistlib
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--expect-decorations", action="store_true")
args = parser.parse_args()
app = args.app.resolve()
with (app / "Contents/Info.plist").open("rb") as f:
    info = plistlib.load(f)
if info.get("AtollPreviewOnly") is not True or not info["CFBundleIdentifier"].startswith("dev.mehdiguiard.atoll.previewtest."):
    parser.error("Une copie préparée par prepare-preview.py est obligatoire.")
args.output.mkdir(parents=True, exist_ok=True)

def osa(command):
    return subprocess.check_output(["osascript", "-e", "with timeout of 5 seconds", "-e", command, "-e", "end timeout"], text=True, timeout=8).strip()

if subprocess.check_output(["defaults", "read", "com.apple.universalaccess", "voiceOverOnOffKey"], text=True).strip() != "1":
    raise SystemExit("VoiceOver doit être activé pour cette recette.")
osa('tell application "VoiceOver" to get content of last phrase')

def read():
    return osa('tell application "VoiceOver" to return (text under cursor of vo cursor) & " | " & (content of last phrase)')

def move(direction):
    osa('tell application "VoiceOver" to tell vo cursor to move ' + direction)
    time.sleep(0.25)  # Le curseur et la phrase sont publiés après la commande.

def collect():
    move("to first item")
    phrases = []
    for _ in range(38):
        phrase = read()
        if len(phrases) > 2 and phrase == phrases[-1] == phrases[-2]:
            break
        phrases.append(phrase)
        move("right")
    return phrases

results = []
for provider in ["codex", "claude"]:
    options = ["--codex-preview", "--preview-cards"] + (["--preview-codex-card"] if provider == "codex" else [])
    with (args.output / f"{provider}.log").open("w") as log:
        process = subprocess.Popen([str(app / "Contents/MacOS/Atoll"), *options], stdout=log, stderr=log)
        try:
            time.sleep(2)
            osa('tell application id "' + info["CFBundleIdentifier"] + '" to activate')
            time.sleep(0.8)
            assert osa('tell application "System Events" to return name of first process whose frontmost is true') == "Atoll", "La recette a perdu le focus"
            phrases = collect()
            text = "\n".join(phrases)
            expected = ["Claude Code", "Codex", "Sélectionné", "DEMANDE"]
            expected += ["apply_patch", "REFUSER", "AUTORISER", "DÉCIDER DANS CODEX", "exemple.txt"] if provider == "codex" else ["plan", "feedback", "REVISE", "APPROVE"]
            assert all(word.lower() in text.lower() for word in expected), "Annonce utile manquante : " + str([w for w in expected if w.lower() not in text.lower()])
            decorated = any(character in text for character in "░▒▓─")
            assert decorated == args.expect_decorations, "Séparateurs décoratifs annoncés" if decorated else "Sabotage non reproduit"
            (args.output / f"{provider}-phrases.json").write_text(json.dumps(phrases, ensure_ascii=False, indent=2))
            if provider == "codex":
                move("to first item")
                for _ in range(35):
                    if "DÉCIDER DANS CODEX" in read():
                        break
                    move("right")
                else:
                    raise AssertionError("Décision inaccessible au curseur VoiceOver")
                osa('tell application "VoiceOver" to tell vo cursor to perform action')
                time.sleep(0.6)
                after = collect()
                after_text = "\n".join(after)
                assert "REVISE" in after_text and "DÉCIDER DANS CODEX" not in after_text, "VoiceOver n'a pas résolu la carte Codex"
                (args.output / "after-handback.json").write_text(json.dumps(after, ensure_ascii=False, indent=2))
            results.append({"provider": provider, "passed": True, "announcements": len(phrases), "decorationsExpected": args.expect_decorations})
            print("PASS VoiceOver " + provider + " : annonces, navigation et contrôles accessibles", flush=True)
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            # Domaine courant de la copie et ancien format pour les contre-épreuves.
            for domain in [f"dev.mehdiguiard.atoll.preview.{info['CFBundleIdentifier']}",
                           f"dev.mehdiguiard.atoll.preview.{process.pid}"]:
                subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
(args.output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
