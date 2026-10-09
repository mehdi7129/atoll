#!/usr/bin/env python3
"""Valide les artefacts Atoll locaux sans lancer ni installer l'application."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
TEAM = "X524H8XA4L"
MACHO_MAGIC = {bytes.fromhex(x) for x in (
    "cafebabe", "bebafeca", "cffaedfe", "feedfacf", "feedface", "cefaedfe", "cafebabf", "bfbafeca"
)}
MACHOS = {
    "Contents/MacOS/Atoll",
    "Contents/Helpers/atoll-bridge",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def verify_delta_source(name, enclosure, full_zip_name, target_build):
    source = enclosure.get(NS + "deltaFrom")
    if name == full_zip_name:
        require(source is None, "Le ZIP complet ne doit pas annoncer deltaFrom")
        return
    match = re.fullmatch(rf"Atoll{re.escape(target_build)}-([0-9]+)\.delta", name)
    require(match is not None, f"Nom de delta incorrect : {name}")
    expected = match.group(1)
    require(source == expected and int(expected) < int(target_build),
            f"Source deltaFrom incorrecte pour {name} : {source}")


def sha256(path):
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


def dump(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


def tree_manifest(root):
    result = {}
    paths = [root]
    for directory, dirs, files in os.walk(root, followlinks=False):
        paths.extend(Path(directory) / name for name in dirs + files)
    for path in sorted(paths):
        metadata = path.lstat()
        entry = {"mode": stat.S_IMODE(metadata.st_mode)}
        if stat.S_ISLNK(metadata.st_mode):
            entry.update(type="symlink", target=os.readlink(path), bytes=metadata.st_size)
        elif stat.S_ISDIR(metadata.st_mode):
            entry.update(type="directory")
        elif stat.S_ISREG(metadata.st_mode):
            entry.update(type="file", bytes=metadata.st_size, sha256=sha256(path))
        else:
            raise RuntimeError(f"Objet inattendu : {path}")
        result[path.relative_to(root).as_posix()] = entry
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=HERE.parent)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--sparkle-bin", type=Path, required=True)
    parser.add_argument("--previous-record", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version) and args.build.isdigit(), "Version/build invalides")
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="run-", dir=args.output.resolve()))
    temporary = tempfile.TemporaryDirectory(prefix="artifacts-", dir=evidence)
    work = Path(temporary.name)
    logs = evidence / "logs"
    logs.mkdir()
    report = {"status": "running", "version": args.version, "build": args.build,
              "startedAt": datetime.now(timezone.utc).isoformat(), "workDirectory": str(work),
              "appLaunched": False, "installedAppAccessed": False}
    report_path = evidence / "validation.json"
    dump(report_path, report)
    print(f"Dossier de preuve : {evidence}", flush=True)
    sequence = 0

    def run(label, command, timeout=120, expected=(0,), child_umask=-1):
        nonlocal sequence
        sequence += 1
        prefix = logs / f"{sequence:03d}-{label}"
        command = [str(value) for value in command]
        metadata = {"command": command, "timeoutSeconds": timeout, "childUmask": child_umask}
        try:
            completed = subprocess.run(command, capture_output=True, timeout=timeout, check=False, umask=child_umask)
        except subprocess.TimeoutExpired as error:
            prefix.with_suffix(".stdout").write_bytes(error.stdout or b"")
            prefix.with_suffix(".stderr").write_bytes(error.stderr or b"")
            metadata["timedOut"] = True
            dump(prefix.with_suffix(".json"), metadata)
            raise RuntimeError(f"Délai dépassé : {label}") from error
        prefix.with_suffix(".stdout").write_bytes(completed.stdout)
        prefix.with_suffix(".stderr").write_bytes(completed.stderr)
        metadata["exitCode"] = completed.returncode
        dump(prefix.with_suffix(".json"), metadata)
        require(completed.returncode in expected, f"Échec {label} (exit {completed.returncode}), voir {prefix}")
        return completed

    def verify_bundle(label, bundle):
        run(label + "-codesign", ["codesign", "--verify", "--strict", "--deep", bundle])
        run(label + "-staple", ["xcrun", "stapler", "validate", bundle])
        run(label + "-gatekeeper", ["spctl", "--assess", "--type", "execute", "--verbose=2", bundle], timeout=180)

    try:
        repo = args.repo.resolve()
        dist, updates = repo / "dist" / args.version, repo / "dist" / "updates"
        appcast = repo / "docs" / "appcast.xml"
        full_zip = dist / f"Atoll-{args.version}.zip"
        dmg = dist / f"Atoll-{args.version}.dmg"
        previous_record = json.loads(args.previous_record.read_text())
        previous_version, previous_build = previous_record["version"], str(previous_record["build"])
        require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", previous_version) and previous_build.isdigit()
                and int(previous_build) < int(args.build), "Version précédente invalide")
        previous_zip = updates / f"Atoll-{previous_version}.zip"
        patch = updates / f"Atoll{args.build}-{previous_build}.delta"
        for path in [appcast, full_zip, dmg, previous_zip, patch, dist / "notary-app.log", dist / "notary-dmg.log"]:
            require(path.is_file(), f"Artefact absent : {path}")
        previous_asset = next(x for x in previous_record["assets"] if x["name"] == previous_zip.name)
        require(re.fullmatch(r"[0-9a-f]{64}", previous_asset["sha256"]), "Empreinte précédente invalide")
        require(sha256(previous_zip) == previous_asset["sha256"] and previous_zip.stat().st_size == previous_asset["bytes"], "ZIP précédent différent de la release publiée")
        require(sha256(full_zip) == sha256(updates / full_zip.name), "ZIP de distribution différent du ZIP Sparkle")
        require(appcast.read_bytes() == (updates / "appcast.xml").read_bytes(), "Les deux appcasts diffèrent")

        items = ET.parse(appcast).getroot().findall("./channel/item")
        require(bool(items), "Appcast vide")
        item = items[0]
        require(item.findtext(NS + "version") == args.build and item.findtext(NS + "shortVersionString") == args.version, "Nouvelle release absente de la tête de l'appcast")
        for existing in items:
            version = existing.findtext(NS + "shortVersionString")
            expected_prefix = f"https://github.com/mehdi7129/atoll/releases/download/v{version}/"
            for enclosure in existing.iter("enclosure"):
                require(enclosure.attrib["url"].startswith(expected_prefix), "URL ancienne repointée vers un mauvais tag")
        enclosures = list(item.iter("enclosure"))
        require(len(enclosures) >= 2, "ZIP et delta immédiat attendus")
        assets = []
        by_name = {}
        for enclosure in enclosures:
            name = Path(unquote(urlparse(enclosure.attrib["url"]).path)).name
            require(name not in by_name, f"Enclosure dupliquée : {name}")
            require(name == full_zip.name or re.fullmatch(rf"Atoll{re.escape(args.build)}-[0-9]+\.delta", name), f"Enclosure inattendue : {name}")
            verify_delta_source(name, enclosure, full_zip.name, args.build)
            path = full_zip if name == full_zip.name else updates / name
            require(path.is_file() and path.stat().st_size == int(enclosure.attrib["length"]), f"Longueur incorrecte : {name}")
            by_name[name] = (path, enclosure.attrib[NS + "edSignature"])
            assets.append({"name": name, "bytes": path.stat().st_size, "sha256": sha256(path), "url": enclosure.attrib["url"]})
        require(full_zip.name in by_name and patch.name in by_name, "ZIP ou delta immédiat non référencé")
        require({p.name for p in updates.glob(f"Atoll{args.build}-*.delta")} == {name for name in by_name if name.endswith(".delta")}, "Deltas locaux et appcast différents")
        assets.append({"name": dmg.name, "bytes": dmg.stat().st_size, "sha256": sha256(dmg), "url": f"https://github.com/mehdi7129/atoll/releases/download/v{args.version}/{dmg.name}"})
        report["assets"] = assets
        initial_hashes = {path: sha256(path) for path in [appcast, full_zip, dmg, previous_zip, *(p for p, _ in by_name.values())]}

        for label, archive in [("old", previous_zip), ("full", full_zip)]:
            destination = work / label
            destination.mkdir()
            # Le parent 0700 garde la confidentialité ; ditto doit créer les
            # liens avec le masque normal pour conserver leurs modes 0755.
            run(label + "-extract", ["ditto", "-xk", archive, destination], child_umask=0o022)
        old, full = work / "old/Atoll.app", work / "full/Atoll.app"
        old_info = plistlib.loads((old / "Contents/Info.plist").read_bytes())
        new_info = plistlib.loads((full / "Contents/Info.plist").read_bytes())
        require((old_info["CFBundleShortVersionString"], old_info["CFBundleVersion"]) == (previous_version, previous_build), "Version du ZIP précédent incorrecte")
        require((new_info["CFBundleShortVersionString"], new_info["CFBundleVersion"]) == (args.version, args.build), "Version du nouveau ZIP incorrecte")
        require(new_info["CFBundleIdentifier"] == old_info["CFBundleIdentifier"], "Identifiant d'app modifié")
        public_key = old_info["SUPublicEDKey"]
        require(new_info["SUPublicEDKey"] == public_key, "Clé publique Sparkle modifiée")
        require(new_info["SUFeedURL"] == "https://mehdi7129.github.io/atoll/appcast.xml", "Flux Sparkle incorrect")
        verifier = work / "verify-eddsa"
        run("compile-public-verifier", ["xcrun", "swiftc", HERE / "release-tools/verify-eddsa.swift", "-o", verifier], timeout=300)
        signatures = []
        for name, (path, signature) in by_name.items():
            result = run("signature-" + name, [verifier, public_key, signature, path])
            require(result.stdout.strip() == b"VALID", "Vérificateur sans verdict positif")
            mutation = work / (name + ".mutated")
            content = bytearray(path.read_bytes())
            require(bool(content), "Asset vide")
            content[len(content) // 2] ^= 1
            mutation.write_bytes(content)
            result = run("mutation-" + name, [verifier, public_key, signature, mutation], expected=(1,))
            require(result.stdout.strip() == b"INVALID", "Mutation non rejetée explicitement")
            signatures.append({"name": name, "verified": True, "modifiedCopyRejected": True})
        report["sparkleEdDSA"] = {"publicKeySource": f"SHA256-verified published {previous_version} ZIP", "enclosures": signatures}

        actual_machos = set()
        for path in full.rglob("*"):
            if path.is_file() and not path.is_symlink():
                with path.open("rb") as stream:
                    if stream.read(4) in MACHO_MAGIC:
                        actual_machos.add(path.relative_to(full).as_posix())
        require(actual_machos == MACHOS, f"Inventaire Mach-O différent : {sorted(actual_machos ^ MACHOS)}")
        component_checks = []
        for index, relative in enumerate(sorted(MACHOS)):
            binary = full / relative
            label = f"component-{index}"
            architecture = run(label + "-architecture", ["lipo", "-archs", binary]).stdout.decode().split()
            require(set(architecture) == {"arm64", "x86_64"}, f"Binaire non universel : {relative}")
            run(label + "-verify", ["codesign", "--verify", "--strict", binary])
            signed = run(label + "-signature", ["codesign", "-dvvv", binary])
            signed_text = (signed.stdout + signed.stderr).decode()
            require("Authority=Developer ID Application:" in signed_text and f"TeamIdentifier={TEAM}" in signed_text, f"Signature incorrecte : {relative}")
            require(re.search(r"flags=0x[0-9a-fA-F]+\([^\n)]*\bruntime\b", signed_text), f"Hardened runtime absent : {relative}")
            entitlements = run(label + "-entitlements", ["codesign", "-d", "--entitlements", "-", "--xml", binary]).stdout
            values = plistlib.loads(entitlements) if entitlements.strip() else {}
            require("com.apple.security.get-task-allow" not in values, f"get-task-allow présent : {relative}")
            if relative == "Contents/MacOS/Atoll":
                require(values == {"com.apple.security.automation.apple-events": True}, "Entitlements app inattendus")
            component_checks.append({"path": relative, "architectures": sorted(architecture), "developerID": True, "team": TEAM, "hardenedRuntime": True, "entitlements": values})
        report["executableComponents"] = component_checks
        verify_bundle("full", full)

        notary = {}
        for label in ["app", "dmg"]:
            text = (dist / f"notary-{label}.log").read_text()
            statuses = re.findall(r"^\s*status:\s*(\w+)\s*$", text, re.MULTILINE)
            ids = re.findall(r"^\s*id:\s*([0-9a-f-]{36})\s*$", text, re.MULTILINE)
            require(bool(statuses) and statuses[-1] == "Accepted" and bool(ids), f"Notarisation {label} non acceptée")
            notary[label] = {"submissionID": ids[-1], "status": statuses[-1]}
        report["notarization"] = notary
        run("dmg-codesign", ["codesign", "--verify", "--strict", dmg])
        dmg_signature = run("dmg-signature", ["codesign", "-dvv", dmg])
        dmg_signature_text = (dmg_signature.stdout + dmg_signature.stderr).decode()
        require("Authority=Developer ID Application:" in dmg_signature_text and f"TeamIdentifier={TEAM}" in dmg_signature_text, "Signature Developer ID du DMG incorrecte")
        run("dmg-staple", ["xcrun", "stapler", "validate", dmg])
        run("dmg-gatekeeper", ["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg], timeout=180)

        patched = work / "patched/Atoll.app"
        patched.parent.mkdir()
        run("delta-apply", [args.sparkle_bin / "BinaryDelta", "apply", old, patched, patch], timeout=180, child_umask=0o022)
        reference_manifest = tree_manifest(full)
        patched_manifest = tree_manifest(patched)
        dump(evidence / "full-tree.json", reference_manifest)
        dump(evidence / "patched-tree.json", patched_manifest)
        require(patched_manifest == reference_manifest, "Arbre obtenu par delta différent du ZIP complet")
        verify_bundle("patched", patched)
        report["deltaUpgrade"] = {"fromBuild": previous_build, "toBuild": args.build, "patch": patch.name,
                                  "sourceArchiveMatchesPublishedSHA256": True,
                                  "filesLinksModesAndSizesEqualFullArchive": True,
                                  "comparedObjects": len(reference_manifest), "codesign": "verified",
                                  "staple": "valid", "gatekeeper": "accepted", "appLaunched": False}

        mountpoint = work / "mounted"
        mountpoint.mkdir()
        mounted = False
        try:
            attachment = run("dmg-attach", ["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", "-mountpoint", mountpoint, dmg], timeout=180)
            mounted = True
            attachment_info = plistlib.loads(attachment.stdout)
            require(any(entity.get("mount-point") == str(mountpoint) for entity in attachment_info["system-entities"]), "Point de montage DMG inattendu")
            mounted_manifest = tree_manifest(mountpoint / "Atoll.app")
            dump(evidence / "dmg-tree.json", mounted_manifest)
            require(mounted_manifest == reference_manifest, "App du DMG différente du ZIP complet")
            report["dmgBundle"] = {"readOnlyMountComparedToFullZIP": True,
                                   "filesLinksModesAndSizesEqualFullArchive": True,
                                   "comparedObjects": len(reference_manifest)}
        finally:
            if mounted or os.path.ismount(mountpoint):
                run("dmg-detach", ["hdiutil", "detach", mountpoint], timeout=120)
                require(not os.path.ismount(mountpoint), "DMG toujours monté après detach")
                if "dmgBundle" in report:
                    report["dmgBundle"]["detached"] = True
        require(all(sha256(path) == digest for path, digest in initial_hashes.items()), "Un artefact a changé pendant la vérification")
        report["appcast"] = {"sha256": sha256(appcast), "itemCount": len(items),
                             "allItemURLsUseTheirVersionTag": True, "newEnclosureCount": len(enclosures)}
        report["checks"] = {"app": "Developer ID verified", "helper": "Developer ID verified",
                            "sparkleComponents": "5 Developer ID components verified", "hardenedRuntime": "all 7 executable components verified",
                            "entitlements": "get-task-allow absent; app automation.apple-events only",
                            "appStaple": "valid", "dmgStaple": "valid", "gatekeeper": "app, dmg and patched app accepted",
                            "sparkleEdDSA": f"{len(signatures)} enclosures verified; {len(signatures)} modified copies rejected"}
        report["architectures"] = ["x86_64", "arm64"]
        report["status"] = "passed"
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        dump(report_path, report)
        print(f"PASS : {len(signatures)} signatures, sept binaires universels, delta {previous_build}→{args.build} et DMG identiques au ZIP.\n{report_path}", flush=True)
        return 0
    except Exception as error:
        report["status"] = "failed"
        report["error"] = f"{type(error).__name__}: {error}"
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        dump(report_path, report)
        print(f"FAIL : {error}\n{report_path}", file=sys.stderr, flush=True)
        return 1
    finally:
        # Ces copies sont créées exclusivement par ce vérificateur.
        try:
            temporary.cleanup()
            report["temporaryArtifactsRemoved"] = True
        except Exception as error:
            report.update(status="failed", cleanupError=type(error).__name__)
            raise
        finally:
            dump(report_path, report)


if __name__ == "__main__":
    sys.exit(main())
