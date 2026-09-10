#!/usr/bin/env python3
"""Recette du rendu réel, sur une copie Debug isolée ; ne lance aucun CLI agent.

Les captures restent à lire : l'OCR détecte les régressions de contenu visible,
pas la qualité graphique, le focus ou VoiceOver. --case permet une reprise ciblée.
Un ancien build peut servir de sabotage avec --expect-failure.
"""
import argparse
import json
import plistlib
import subprocess
import tempfile
import time
import unicodedata
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--case", action="append")
parser.add_argument("--expect-failure", action="store_true")
args = parser.parse_args()
app = args.app.resolve()
with (app / "Contents/Info.plist").open("rb") as stream:
    bundle_id = plistlib.load(stream)["CFBundleIdentifier"]
if "Build/Products" in str(app) or app == Path.home() / "Applications/Atoll.app":
    parser.error("Fournir une copie de recette, jamais le produit de build ni l'app stable.")
args.output.mkdir(parents=True, exist_ok=True)

SWIFT = r'''
import AppKit
import Vision
import Foundation
if ["press", "frame"].contains(CommandLine.arguments[1]) {
    let application = AXUIElementCreateApplication(pid_t(CommandLine.arguments[2])!)
    let title = CommandLine.arguments[3]
    func find(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if let value = value as? String, value.contains(title) {
                return element
            }
        }
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        for child in value as? [AXUIElement] ?? [] { if let found = find(child) { return found } }
        return nil
    }
    guard let element = find(application) else { fatalError("Bouton de recette introuvable : " + title) }
    if CommandLine.arguments[1] == "press" {
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { fatalError("AXPress refusé") }
    } else {
        var position: CFTypeRef?, size: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
        var point = CGPoint.zero, dimensions = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
        print("{\"x\":\(point.x + dimensions.width / 2),\"y\":\(point.y + dimensions.height / 2)}")
    }
} else if CommandLine.arguments[1] == "window" {
    let pid = Int(CommandLine.arguments[2])!
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let matches = list.filter {
        ($0[kCGWindowOwnerPID as String] as? Int) == pid &&
        ($0[kCGWindowName as String] as? String ?? "").contains("recette isolée")
    }
    print(String(data: try JSONSerialization.data(withJSONObject: matches), encoding: .utf8)!)
} else {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    let data = try Data(contentsOf: url)
    let bitmap = NSBitmapImageRep(data: data)!
    // Le monospacé des ailes fait quelques pixels sur un écran 1×. Agrandir
    // uniquement l'entrée OCR ; la capture conservée reste l'originale.
    let canvas = CGContext(data: nil, width: bitmap.pixelsWide * 3, height: bitmap.pixelsHigh * 3,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    canvas.interpolationQuality = .none
    canvas.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["fr-FR", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: canvas.makeImage()!).perform([request])
    let lines = (request.results ?? []).compactMap { observation -> [String: Any]? in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        let b = observation.boundingBox
        return ["text": text, "x": b.minX, "y": 1 - b.maxY, "width": b.width, "height": b.height]
    }
    // Hors de l'encoche 180 pt, dans une aile indûment peinte par l'ancien code.
    let color = bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * 0.353),
                               y: Int(Double(bitmap.pixelsHigh) * 0.22))!.usingColorSpace(.deviceRGB)!
    let output: [String: Any] = ["lines": lines, "wingBrightness": color.redComponent,
                               "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh]
    print(String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8)!)
}
'''

cases = {
    "motion-pill": ([], ["QUOTAS", "projet-"]),
    "motion-pill-reduced": (["--preview-reduce-motion"], ["QUOTAS", "projet-"]),
    "motion-notch": (["--preview-notch"], ["QUOTAS", "projet-"]),
    "motion-notch-reduced": (["--preview-notch", "--preview-reduce-motion"], ["QUOTAS", "projet-"]),
    "preview-preferences": (["--preview-skills"], ["APPROUVER"]),
    "skills": (["--preview-skills"], ["PROPOSITION", "SKILL.MD", "mots", "INSTALLÉ ACTUELLEMENT", "APPROUVER"]),
    "skills-position": (["--preview-skills"], ["conversion-3", "2/2", "APPROUVER"]),
    "selector-hover": (["--preview-compact"], ["27%"]),
    "list-codex": (["--preview-many"], ["projet-", "autres", "QUOTAS"]),
    "list-claude": (["--preview-many", "--preview-claude"], ["projet-", "autres", "QUOTAS"]),
    "card-claude": (["--preview-cards"], ["CLAUDE", "PLAN", "Vérifier les couleurs", "feedback", "REVISE", "APPROVE"]),
    "card-codex": (["--preview-cards", "--preview-codex-card"], ["apply_patch", "REFUSER", "AUTORISER", "DÉCIDER DANS CODEX"]),
    "detail": (["--preview-detail"], ["retour", "modèle", "contexte"]),
    "detail-cli-absent": (["--preview-detail", "--preview-claude"], ["retour", "modèle", "contexte"]),
    "onboarding-unset": (["--preview-onboarding"], ["COMMENCER", "moteur des analyses", "HOOKS INSTALLÉS"]),
    "onboarding-claude": (["--preview-onboarding"], ["COMMENCER", "moteur des analyses", "HOOKS INSTALLÉS"]),
    "onboarding-codex": (["--preview-onboarding"], ["COMMENCER", "moteur des analyses", "HOOKS INSTALLÉS"]),
    "onboarding-navigation": (["--preview-onboarding"], ["COMMENCER", "moteur des analyses", "HOOKS INSTALLÉS"]),
    "settings-codex": (["--preview-codex-settings"], ["Codex CLI", "Appliquer le dossier Codex", "Vérifier avec Codex"]),
    "idle-notch": (["--preview-empty", "--preview-notch", "--preview-compact"], []),
    "rockstar": (["--preview-empty", "--preview-compact", "--preview-rockstar"], ["CLAUDE", "ROCKSTAR", "18%"]),
    "rockstar-notch": (["--preview-empty", "--preview-compact", "--preview-rockstar", "--preview-notch"], ["CLAUDE", "ROCKSTAR", "18%"]),
    "compact": (["--preview-compact"], ["projet-", "18%"]),
    "light": (["--preview-many", "--preview-light"], ["projet-", "autres", "QUOTAS"]),
}
for width in ["small", "medium", "large"]:
    for notch in [False, True]:
        for light in [False, True]:
            for reduced in [False, True]:
                name = "matrix-" + "-".join([width, "notch" if notch else "pill", "light" if light else "dark", "reduced" if reduced else "motion"])
                options = ["--preview-compact", "--preview-width-" + width]
                if notch: options.append("--preview-notch")
                if light: options.append("--preview-light")
                if reduced: options.append("--preview-reduce-motion")
                cases[name] = (options, ["projet-", "18%"])
selected = args.case or list(cases)
if any(name not in cases for name in selected):
    parser.error("Cas inconnus : " + str(selected))

with tempfile.TemporaryDirectory(prefix="atoll-ui-probe-") as directory:
    root = Path(directory)
    source = root / "probe.swift"
    source.write_text(SWIFT)
    probe = root / "probe"
    subprocess.run(["swiftc", str(source), "-o", str(probe)], check=True)

    def read(mode, value):
        return json.loads(subprocess.check_output([str(probe), mode, str(value)], text=True))

    results = []
    for name in selected:
        options, expected = cases[name]
        case_failures = []
        preview_domain = "dev.mehdiguiard.atoll.preview." + bundle_id
        if name == "preview-preferences":
            subprocess.run(["defaults", "write", preview_domain, "fixtureStale", "-string", "interrupted-preview"], check=True)
        isolated_preferences = name.startswith("onboarding-") or name == "detail-cli-absent"
        if isolated_preferences:
            if not bundle_id.startswith("dev.mehdiguiard.atoll.previewtest."):
                raise SystemExit("Ce cas nécessite une copie avec un bundle ID dev.mehdiguiard.atoll.previewtest.*")
            subprocess.run(["defaults", "delete", bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if name in ["onboarding-claude", "onboarding-codex"]:
                subprocess.run(["defaults", "write", bundle_id, "analysisProvider", "-string", name.split("-")[1]], check=True)
            if name == "detail-cli-absent":
                subprocess.run(["defaults", "write", bundle_id, "codexExecutablePath", "-string", "/atoll-fixture/cli-absent"], check=True)
        with (args.output / (name + ".log")).open("w") as log:
            process = subprocess.Popen([str(app / "Contents/MacOS/Atoll"), "--codex-preview", *options], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 20
                windows = []
                while time.monotonic() < deadline and process.poll() is None:
                    windows = read("window", process.pid)
                    if windows:
                        break
                    time.sleep(0.2)
                if not windows:
                    raise RuntimeError("Fenêtre de recette introuvable pour " + name)
                window = windows[0]
                time.sleep(2)
                # NSHostingView peut finir de redimensionner la fenêtre après
                # sa première apparition (notamment la bienvenue 560×500).
                window = read("window", process.pid)[0]
                (args.output / (name + "-window.json")).write_text(json.dumps(window, indent=2))
                b = window["kCGWindowBounds"]
                subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to activate'], check=True)
                time.sleep(0.8)
                front_pid = subprocess.check_output(["osascript", "-e", 'tell application "System Events" to return unix id of first process whose frontmost is true'], text=True).strip()
                if front_pid != str(process.pid):
                    raise RuntimeError("Le focus n'appartient pas à la copie de recette")
                if name.startswith("motion-"):
                    video = args.output / (name + ".mov")
                    recorder = subprocess.Popen(["/usr/sbin/screencapture", "-v", "-V", "6", "-l", str(window["kCGWindowNumber"]), str(video)], stdout=log, stderr=log)
                    try:
                        time.sleep(0.8)
                        subprocess.run([str(probe), "press", str(process.pid), "Animation"], check=True)
                        recorder.wait(timeout=12)
                        if recorder.returncode != 0:
                            raise RuntimeError("Capture vidéo échouée")
                    finally:
                        if recorder.poll() is None:
                            recorder.terminate()
                            recorder.wait(timeout=5)
                if name == "selector-hover":
                    before = args.output / "selector-hover-before.png"
                    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window["kCGWindowNumber"]), str(before)], check=True)
                    target = json.loads(subprocess.check_output([str(probe), "frame", str(process.pid), "Claude Code"], text=True))
                    x, y = int(target["x"]), int(target["y"])
                    (args.output / "selector-pointer.json").write_text(json.dumps(target))
                    subprocess.run(["/opt/homebrew/bin/cliclick", f"m:={x},={y}"], check=True)
                    time.sleep(0.7)
                    hovered = args.output / "selector-hover-wait.png"
                    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window["kCGWindowNumber"]), str(hovered)], check=True)
                    hover_text = "\n".join(line["text"] for line in read("ocr", hovered)["lines"] if line["y"] > 0.19)
                    if "QUOTAS" in hover_text or "SESSIONS" in hover_text:
                        case_failures.append("Le sélecteur compact s'est déplacé avant le clic")
                    else:
                        subprocess.run(["/opt/homebrew/bin/cliclick", "-w", "150", f"c:={x},={y}"], check=True)
                        time.sleep(0.3)
                if name == "skills-position":
                    before = args.output / "skills-position-before.png"
                    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window["kCGWindowNumber"]), str(before)], check=True)
                    subprocess.run([str(probe), "press", str(process.pid), "SUIV"], check=True)
                    time.sleep(0.5)
                    selected_capture = args.output / "skills-position-selected.png"
                    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window["kCGWindowNumber"]), str(selected_capture)], check=True)
                    before_text = " ".join(line["text"] for line in read("ocr", selected_capture)["lines"])
                    if "conversion-2" not in before_text:
                        raise AssertionError("La navigation de recette n'a pas sélectionné la seconde proposition")
                    subprocess.run(["/opt/homebrew/bin/cliclick", "kd:cmd", "kp:delete", "ku:cmd"], check=True)
                    time.sleep(0.5)
                if name.startswith("onboarding-"):
                    before = args.output / (name + "-before.png")
                    for attempt in range(4):
                        subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window["kCGWindowNumber"]), str(before)], check=True)
                        lines = read("ocr", before)["lines"]
                        if any("HOOKS INSTALLÉS" in line["text"] for line in lines):
                            break
                        if attempt == 3:
                            raise RuntimeError("Le clic de recette n'a pas activé l'installation simulée ; résultat non interprétable.")
                        button = next(line for line in lines if "INSTALLER LES HOOKS" in line["text"])
                        b = read("window", process.pid)[0]["kCGWindowBounds"]
                        x = int(b["X"] + b["Width"] * (button["x"] + button["width"] / 2))
                        y = int(b["Y"] + b["Height"] * (button["y"] + button["height"] / 2))
                        subprocess.run(["/opt/homebrew/bin/cliclick", "-r", "-w", "150", f"c:={x},={y}"], check=True)
                        time.sleep(1)
                    if name == "onboarding-navigation":
                        button = next(line for line in lines if "moteur des analyses" in line["text"])
                        b = read("window", process.pid)[0]["kCGWindowBounds"]
                        x = int(b["X"] + b["Width"] * (button["x"] + button["width"] / 2))
                        y = int(b["Y"] + b["Height"] * (button["y"] + button["height"] / 2))
                        for _ in range(3):
                            subprocess.run(["/opt/homebrew/bin/cliclick", "-r", "-w", "150", f"c:={x},={y}"], check=True)
                            time.sleep(0.5)
                            tab = subprocess.run(["defaults", "read", bundle_id, "settingsTab"], capture_output=True, text=True)
                            if tab.stdout.strip() == "apprentissage":
                                break
                path = args.output / (name + ".png")
                subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window["kCGWindowNumber"]), str(path)], check=True)
                observed = read("ocr", path)
                (args.output / (name + ".json")).write_text(json.dumps(observed, ensure_ascii=False, indent=2))
                # Les contrôles de recette au-dessus de l'îlot ne sont pas des preuves.
                text = "\n".join(line["text"] for line in observed["lines"] if name.startswith("onboarding-") or name == "settings-codex" or name.startswith("skills") or line["y"] > 0.19)
                def normalized(value):
                    return "".join(c for c in unicodedata.normalize("NFD", value.casefold()) if unicodedata.category(c) != "Mn")
                missing = [label for label in expected if normalized(label) not in normalized(text)]
                missing += case_failures
                if name == "preview-preferences":
                    stale = subprocess.run(["defaults", "read", preview_domain, "fixtureStale"], capture_output=True)
                    if stale.returncode == 0:
                        missing.append("préférences de la recette interrompue conservées")
                if name.startswith("onboarding-"):
                    engine = subprocess.run(["defaults", "read", bundle_id, "analysisProvider"], capture_output=True, text=True)
                    wanted = name.split("-")[1] if name in ["onboarding-claude", "onboarding-codex"] else None
                    actual = engine.stdout.strip() if engine.returncode == 0 else None
                    if actual != wanted:
                        missing.append(f"moteur modifié par l'installation : {wanted!r} → {actual!r}")
                    if name == "onboarding-navigation" and tab.stdout.strip() != "apprentissage":
                        missing.append("le lien ne sélectionne pas l'onglet Apprentissage")
                if name == "detail-cli-absent" and "CONTINUER DANS" in text:
                    missing.append("relais proposé sans CLI cible")
                if name == "idle-notch":
                    if "repos" in text.casefold() or "CX" in text or "CL" in text:
                        missing.append("l'îlot montre du texte au repos")
                    if observed["wingBrightness"] < 0.1:
                        missing.append("les ailes restent peintes au repos")
                results.append({"case": name, "passed": not missing, "failures": missing})
                print(("FAIL " if missing else "PASS ") + name + (": " + "; ".join(missing) if missing else ""), flush=True)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                # Anciennes previews : nettoyer leur domaine dédié après Ctrl-C.
                subprocess.run(["defaults", "delete", f"dev.mehdiguiard.atoll.preview.{process.pid}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["defaults", "delete", preview_domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if isolated_preferences:
                    subprocess.run(["defaults", "delete", bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (args.output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
    failed = any(not result["passed"] for result in results)
    if args.expect_failure:
        if not failed:
            raise SystemExit("Sabotage non détecté.")
        print("PASS sabotage visuel détecté sur l'ancien build.")
    elif failed:
        raise SystemExit(1)
