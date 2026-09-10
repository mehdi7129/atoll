#!/usr/bin/env python3
"""Copie un build Debug pour une recette qui reste isolée sans arguments CLI."""
import argparse
import plistlib
import subprocess
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
if "Debug" not in args.source.parts or args.destination.exists():
    parser.error("Fournir un build Debug et une destination nouvelle.")
if args.destination.parent.resolve() != Path("/private/tmp"):
    parser.error("Les copies de recette doivent rester dans /private/tmp.")
subprocess.run(["ditto", str(args.source), str(args.destination)], check=True)
info = args.destination / "Contents/Info.plist"
with info.open("rb") as stream:
    values = plistlib.load(stream)
values["CFBundleIdentifier"] = "dev.mehdiguiard.atoll.previewtest." + uuid.uuid4().hex
values["AtollPreviewOnly"] = True
with info.open("wb") as stream:
    plistlib.dump(values, stream)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(args.destination)], check=True)
print(args.destination)
