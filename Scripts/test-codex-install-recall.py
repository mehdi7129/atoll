#!/usr/bin/env python3
"""Helper Codex seul : hooks passifs, aucun recall, déconnexion sans perte.

Nom conservé pour les appelants de recette historiques. CFFIXED_USER_HOME et
CODEX_HOME pointent vers des dossiers privés ; aucun modèle ni CLI authentifié.
Les anciennes données mémoire/recall et les skills gérés restent intacts.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("helper", type=Path)
parser.add_argument("--build-dir", type=Path, help="Argument legacy : cette recette ne recompile pas Core.")
args = parser.parse_args()
helper = args.helper.resolve(strict=True)
with tempfile.TemporaryDirectory(prefix="atoll-install-recall-") as directory:
    root = Path(directory)
    home, codex_home = root / "home", root / "codex home"
    home.mkdir(mode=0o700); codex_home.mkdir(mode=0o700)
    environment = dict(os.environ, CFFIXED_USER_HOME=str(home), CODEX_HOME=str(codex_home))
    environment.pop("ATOLL_RETROSPECTIVE", None)
    foreign = {"hooks": {"UserPromptSubmit": [{"matcher": "personnel", "description": "à garder", "hooks": [
        {"type": "command", "command": "printf foreign", "async": True, "timeout": 17}]}]}}
    settings = codex_home / "hooks.json"
    settings.write_text(json.dumps(foreign))
    config = codex_home / "config.toml"
    config.write_text("personal_setting = true\n")
    def run(*arguments):
        result = subprocess.run([str(helper), *arguments], env=environment, text=True, capture_output=True, timeout=10)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout
    # Prouver les racines effectivement utilisées avant de créer les données.
    status = json.loads(run("status"))
    assert Path(status["codex"]["home"]).resolve() == codex_home.resolve(), "home Foundation/env inattendu"
    assert Path(status["memoryIndexPath"]).resolve() == (home / ".atoll/memory.db").resolve(), "racine Foundation non isolée"
    run("install-codex")
    assert not (home / ".claude").exists(), "installation Codex a créé une configuration Claude"
    recall = codex_home / "skills/atoll-recall/SKILL.md"
    assert not recall.exists(), "Recall réinstallé par installation Codex"
    installed = settings.read_bytes(); stamp = settings.stat().st_mtime_ns
    run("install-codex")
    assert settings.read_bytes() == installed and settings.stat().st_mtime_ns == stamp, "installation non idempotente"
    # argv[0] nu, cwd sans helper : le wrapper doit garder l'image réelle.
    bare = subprocess.run([helper.name, "install-codex"], executable=str(helper), cwd=root,
                          env=environment, capture_output=True, text=True, timeout=10)
    assert bare.returncode == 0, bare.stderr
    wrapper = home / ".atoll/bin/atoll-codex-bridge"
    assignment = re.search(r"^BIN=(.+)$", wrapper.read_text(), flags=re.MULTILINE)
    assert assignment, "Pointeur du helper absent du wrapper"
    actual_helper = Path(shlex.split(assignment.group(1))[0]).resolve()
    assert actual_helper == helper, "nom nu : helper réel perdu dans le wrapper"
    assert actual_helper != (root / helper.name).resolve(), "nom nu : cwd gravé comme helper"
    assert not recall.exists(), "Recall réinstallé avec argv[0] nu"
    print("PASS installation argv[0] nu/deux passages : wrapper réel, Codex seul, aucun recall, idempotence.")

    # Inclure une entrée réellement gérée : restaurer uninstallAll ferait perdre
    # ce skill, même si un skill étranger hors manifeste resterait intact.
    skill = codex_home / "skills/atoll-kept/SKILL.md"
    skill.parent.mkdir(parents=True)
    markdown = "Procédure Codex à conserver."
    skill.write_text(markdown)
    resource = skill.parent / "scripts/unique.py"
    resource.parent.mkdir(); resource.write_text("unique resource\n")
    learning = home / ".atoll/learning"
    learning.mkdir(parents=True)
    scope = hashlib.sha256((status["codex"]["home"] + "/skills").encode()).hexdigest()[:16]
    manifest = learning / ("installed-v2-codex-" + scope + ".json")
    manifest.write_text(json.dumps({"v": 2, "legacySnapshot": [], "skills": [{
        "destination": "codex", "slug": "kept", "dirName": "atoll-kept", "installedAt": "2026-01-01T00:00:00Z",
        "skillSHA256": hashlib.sha256(markdown.encode()).hexdigest()}]}))
    assert json.loads(run("status"))["codex"]["learnedSkills"] == 1, "Fixture de skill Codex géré invalide"
    memory = home / ".atoll/memory.db"
    memory.write_bytes(b"opaque historical memory fixture")
    recall.parent.mkdir(parents=True)
    recall.write_text("Recall historique personnalisé : conserver sans l'exécuter.")
    protected = {file: file.read_bytes() for file in [skill, resource, manifest, memory, recall, config]}
    run("install-codex")
    for verb in ["recall", "recall-stats"]:
        result = subprocess.run([str(helper), verb, "quantique corail", "--json"], env=environment, capture_output=True, timeout=10)
        assert result.returncode == 0 and result.stdout == b"" and result.stderr == b"", "Recall legacy encore exécuté"
    run("uninstall-codex")
    assert json.loads(settings.read_text()) == foreign, "hook étranger modifié au retrait"
    for file, before in protected.items():
        assert file.exists() and file.read_bytes() == before, "Donnée/skill modifié à la déconnexion : " + str(file.relative_to(root))
    before = settings.read_bytes(); stamp = settings.stat().st_mtime_ns
    run("uninstall-codex")
    assert settings.read_bytes() == before and settings.stat().st_mtime_ns == stamp, "Deuxième retrait non idempotent"
    assert not (home / ".claude").exists(), "Configuration Claude créée au retrait Codex"
    print("PASS retrait Codex : tiers, skill géré, ressources, manifeste, mémoire, recall historique et config préservés.")
