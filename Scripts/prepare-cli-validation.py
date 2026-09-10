#!/usr/bin/env python3
"""Prépare une copie native et deux homes privés, sans lancer l'application.

Le compte Codex est copié pour une recette authentifiée explicitement demandée.
Avant lancement, fermer l'Atoll normal : les sockets restent ceux du vrai produit.
Une réouverture sans ces racines lance uniquement l'aperçu fictif.
"""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
args = parser.parse_args()
if "Debug" not in args.source.parts:
    parser.error("Fournir le build Debug.")
root = Path(tempfile.mkdtemp(prefix="atoll-native-cli-", dir="/private/tmp"))
home, codex, project = [root / name for name in ["home", "codex", "project"]]
for path in [home, codex, project]:
    path.mkdir(mode=0o700)
app = root / "Atoll-native-validation.app"
subprocess.run(["ditto", str(args.source), str(app)], check=True)
info_path = app / "Contents/Info.plist"
with info_path.open("rb") as f:
    info = plistlib.load(f)
info.update(CFBundleIdentifier="dev.mehdiguiard.atoll.nativetest." + uuid.uuid4().hex,
            AtollValidationHome=str(home), AtollValidationCodexHome=str(codex))
with info_path.open("wb") as f:
    plistlib.dump(info, f)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
shutil.copyfile(Path.home() / ".codex/auth.json", codex / "auth.json")
(codex / "auth.json").chmod(0o600)
env = dict(os.environ, CFFIXED_USER_HOME=str(home), CODEX_HOME=str(codex))
env.pop("ATOLL_RETROSPECTIVE", None)
helper = app / "Contents/Helpers/atoll-bridge"
status = json.loads(subprocess.check_output([str(helper), "status"], env=env, text=True))
assert Path(status["memoryIndexPath"]).resolve() == home / ".atoll/memory.db", "Home Foundation non isolé"
assert Path(status["codex"]["home"]).resolve() == codex, "Home Codex non isolé"
subprocess.run([str(helper), "install-codex"], env=env, check=True)
hooks = codex / "hooks.json"
definitions = json.loads(hooks.read_text())
# Le shell du CLI garde son HOME d'authentification. Le hook de CETTE fixture
# vise explicitement le wrapper privé, sans modifier les définitions du produit.
for entries in definitions["hooks"].values():
    for entry in entries:
        for hook in entry["hooks"]:
            hook["command"] = hook["command"].replace('$HOME/.atoll/bin/atoll-codex-bridge', str(home / ".atoll/bin/atoll-codex-bridge"))
            assert '$HOME' not in hook["command"] and str(home) in hook["command"], "Hook de recette non isolé"
hooks.write_text(json.dumps(definitions, indent=2))
manifest = {"root": str(root), "app": str(app), "home": str(home), "codexHome": str(codex),
            "project": str(project), "bundleID": info["CFBundleIdentifier"]}
(root / "fixture.json").write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest, indent=2))
