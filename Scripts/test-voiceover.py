#!/usr/bin/env python3
"""Recette des annonces VoiceOver sur une copie Debug protégée.

Prérequis : VoiceOver et son contrôle AppleScript déjà autorisés et activés.
Ce script ne change aucune permission ni préférence VoiceOver. Il ouvre des
sessions et contrôles de skills fictifs, parcourt le curseur natif et vérifie les phrases réellement
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
for name, options, expected in [
    ("codex-detail", ["--preview-detail"], ["retour", "modèle", "contexte", "lecture seule"]),
    ("claude-detail", ["--preview-detail", "--preview-claude"], ["retour", "modèle", "Action attendue dans le CLI"]),
    ("skills", ["--preview-settings=learning"], ["Créer automatiquement des propositions de skills", "Moteur"]),
]:
    options = ["--codex-preview", *options]
    with (args.output / f"{name}.log").open("w") as log:
        process = subprocess.Popen([str(app / "Contents/MacOS/Atoll"), *options], stdout=log, stderr=log)
        try:
            time.sleep(2)
            osa('tell application id "' + info["CFBundleIdentifier"] + '" to activate')
            time.sleep(0.8)
            assert osa('tell application "System Events" to return name of first process whose frontmost is true') == "Atoll", "La recette a perdu le focus"
            phrases = collect()
            text = "\n".join(phrases)
            assert all(word.lower() in text.lower() for word in expected), "Annonce utile manquante : " + str([w for w in expected if w.lower() not in text.lower()])
            (args.output / f"{name}-phrases.json").write_text(json.dumps(phrases, ensure_ascii=False, indent=2))
            results.append({"case": name, "passed": True, "announcements": len(phrases)})
            print("PASS VoiceOver " + name + " : annonces et navigation", flush=True)
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
