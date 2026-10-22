#!/usr/bin/env python3
"""Recette du rendu réel, sur une copie Debug isolée ; ne lance aucun CLI agent.

Les captures restent à lire : l'OCR détecte les régressions de contenu visible,
pas la qualité graphique ou VoiceOver. --case permet une reprise ciblée.
Un ancien build peut servir de sabotage avec --expect-failure.
"""
import argparse
import fcntl
import json
import plistlib
import re
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
    app_info = plistlib.load(stream)
    bundle_id = app_info["CFBundleIdentifier"]
if "Build/Products" in str(app) or app == Path.home() / "Applications/Atoll.app":
    parser.error("Fournir une copie de recette, jamais le produit de build ni l'app stable.")
if app_info.get("AtollPreviewOnly") is not True or not bundle_id.startswith("dev.mehdiguiard.atoll.previewtest."):
    parser.error("Une copie protégée par prepare-preview.py est obligatoire.")
args.output.mkdir(parents=True, exist_ok=True)
# Plusieurs builds peuvent se préparer en parallèle, jamais deux recettes GUI.
ui_lock = (Path(tempfile.gettempdir()) / "atoll-ui-test.lock").open("w")
fcntl.flock(ui_lock.fileno(), fcntl.LOCK_EX)

SWIFT = r'''
import AppKit
import Vision
import Foundation
if CommandLine.arguments[1] == "activate" {
    guard let target = NSRunningApplication(processIdentifier: pid_t(CommandLine.arguments[2])!) else { exit(1) }
    target.activate(options: [.activateAllWindows])
} else if CommandLine.arguments[1] == "keyboard" {
    print(NSApplication.shared.isFullKeyboardAccessEnabled ? "true" : "false")
} else if CommandLine.arguments[1] == "screens" {
    let screens = NSScreen.screens.enumerated().map { index, screen -> [String: Any] in
        ["index": index, "name": screen.localizedName, "scale": screen.backingScaleFactor]
    }
    print(String(data: try JSONSerialization.data(withJSONObject: screens), encoding: .utf8)!)
} else if CommandLine.arguments[1] == "elements" {
    let application = AXUIElementCreateApplication(pid_t(CommandLine.arguments[2])!)
    var entries: [[String: String]] = []
    var focused: CFTypeRef?
    AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
    func visit(_ element: AXUIElement) {
        func text(_ attribute: String) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return value as? String ?? ""
        }
        // La recette porte sur la fenêtre, pas les menus système et documents récents.
        if text(kAXRoleAttribute) == kAXMenuBarRole { return }
        let label = [text(kAXTitleAttribute), text(kAXDescriptionAttribute), text(kAXValueAttribute)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        var enabled: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
        var rawValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &rawValue)
        if !label.isEmpty || !text(kAXIdentifierAttribute).isEmpty { entries.append(["role": text(kAXRoleAttribute), "label": label, "id": text(kAXIdentifierAttribute),
            "value": (rawValue as? NSNumber)?.stringValue ?? text(kAXValueAttribute), "enabled": (enabled as? NSNumber)?.stringValue ?? "", "focused": focused.map { CFEqual($0, element) } == true ? "1" : "0"]) }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] { visit(child) }
    }
    visit(application)
    print(String(data: try JSONSerialization.data(withJSONObject: entries), encoding: .utf8)!)
} else if ["press", "frame"].contains(CommandLine.arguments[1]) {
    let application = AXUIElementCreateApplication(pid_t(CommandLine.arguments[2])!)
    let argument = CommandLine.arguments[3]
    let menuOnly = argument.hasPrefix("menu:")
    let buttonOnly = argument.hasPrefix("button:")
    let title = menuOnly ? String(argument.dropFirst(5)) : buttonOnly ? String(argument.dropFirst(7)) : argument
    func find(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        let isMenuItem = value as? String == kAXMenuItemRole
        let isButton = value as? String == kAXButtonRole
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute] {
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if let value = value as? String, value.contains(title), !menuOnly || isMenuItem, !buttonOnly || (isButton && value == title) {
                var actions: CFArray?
                AXUIElementCopyActionNames(element, &actions)
                if CommandLine.arguments[1] == "frame" || (actions as? [String] ?? []).contains(kAXPressAction) {
                    return element
                }
            }
        }
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        for child in value as? [AXUIElement] ?? [] { if let found = find(child) { return found } }
        return nil
    }
    guard let element = find(application) else { fputs("Bouton de recette introuvable : \(title)\n", stderr); exit(2) }
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
        ($0[kCGWindowLayer as String] as? Int) == 0 &&
        (($0[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) >= 500
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
    "expanded-codex": ([], ["Codex", "Sessions", "Quotas"]),
    "expanded-claude": (["--preview-claude", "--preview-light", "--preview-notch"], ["Claude Code", "Sessions", "Quotas"]),
    "many-sessions": (["--preview-many"], ["Sessions", "autres", "Quotas"]),
    "detail": (["--preview-detail"], ["retour", "modèle", "contexte", "lecture seule"]),
    "detail-claude": (["--preview-detail", "--preview-claude"], ["retour", "modèle", "Action attendue dans le CLI"]),
    "skills-review": (["--preview-skills"], ["PROPOSITION", "SKILL.MD", "APPROUVER"]),
    "skills-off": (["--preview-settings=learning"], ["Créer automatiquement des propositions de skills", "Moteur", "Skills"]),
    "skills-on": (["--preview-settings=learning", "--preview-generation-on", "--preview-learning-proposals"], ["Créer automatiquement des propositions de skills", "Propositions à revoir"]),
    "connections-codex": (["--preview-settings=connections"], ["Connexion à Codex", "Afficher le quota"]),
    "connections-claude": (["--preview-settings=connections", "--preview-claude"], ["Connexion à Claude Code", "Quota"]),
    "settings-general": (["--preview-all-settings", "--preview-settings=general", "--preview-light"], ["Général", "Connexions", "Skills", "Mises à jour", "À propos", "Apparence"]),
    "animation-pill": ([], ["Quotas"]),
    "animation-notch": (["--preview-notch"], ["Quotas"]),
    "reduced-motion": (["--preview-notch", "--preview-reduce-motion"], ["Quotas"]),
    "skills-narrow-light": (["--preview-all-settings", "--preview-settings=learning", "--preview-light", "--preview-narrow", "--preview-short"], ["Créer automatiquement des propositions de skills", "Skills"]),
    "connections-navigation": (["--preview-all-settings", "--preview-settings=connections"], ["Moteur d’analyse", "Modèle Codex"]),
    "onboarding": (["--preview-onboarding"], ["COMMENCER", "SUIVRE LES SESSIONS", "GARDER LES PROCÉDURES"]),
    "idle-notch": (["--preview-empty", "--preview-notch", "--preview-compact"], []),
}
for width in ["small", "medium", "large"]:
    for notch in [False, True]:
        cases["compact-" + width + ("-notch" if notch else "-pill")] = (
            ["--preview-compact", "--preview-width-" + width] + (["--preview-notch"] if notch else []), ["18%"])
selected = args.case or list(cases)
if any(name not in cases for name in selected):
    parser.error("Cas inconnus : " + str(selected))

def normalized(value):
    return " ".join("".join(c for c in unicodedata.normalize("NFD", value.lower()) if not unicodedata.combining(c)).split())

with tempfile.TemporaryDirectory(prefix="atoll-ui-probe-") as directory:
    root = Path(directory)
    source = root / "probe.swift"
    source.write_text(SWIFT)
    probe = root / "probe"
    subprocess.run(["swiftc", str(source), "-o", str(probe)], check=True)

    def read(mode, value):
        return json.loads(subprocess.check_output([str(probe), mode, str(value)], text=True, timeout=8))

    (args.output / "screens.json").write_text(json.dumps(read("screens", 0), ensure_ascii=False, indent=2))
    results = []
    for name in selected:
        options, expected = cases[name]
        failures = []
        with (args.output / (name + ".log")).open("w") as log:
            process = subprocess.Popen([str(app / "Contents/MacOS/Atoll"), "--codex-preview", *options], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 20
                windows = []
                while time.monotonic() < deadline and process.poll() is None:
                    windows = read("window", process.pid)
                    if windows: break
                    time.sleep(0.2)
                if not windows: raise RuntimeError("Fenêtre de recette introuvable")
                time.sleep(1.2)
                windows = read("window", process.pid)
                if not windows: raise RuntimeError("Fenêtre disparue")
                window = windows[0]
                (args.output / (name + "-window.json")).write_text(json.dumps(window, indent=2))
                if name == "connections-navigation":
                    before = read("elements", process.pid)
                    (args.output / (name + "-before-ax.json")).write_text(json.dumps(before, ensure_ascii=False, indent=2))
                    labels = ["Choisir le modèle", "Régler les analyses", "Régler la création de skills"]
                    label = next((label for label in labels if any(label in e["label"] and e["role"] == "AXButton" for e in before)), None)
                    if label is None: raise RuntimeError("Raccourci vers Skills absent")
                    subprocess.run([str(probe), "press", str(process.pid), label], check=True, timeout=8)
                    time.sleep(0.4)
                if name.startswith("animation-"):
                    with (args.output / (name + "-recording.log")).open("w") as recording_log:
                        recording = subprocess.Popen(["/usr/sbin/screencapture", "-x", "-v", "-V", "6", "-l", str(window["kCGWindowNumber"]), str(args.output / (name + ".mov"))], stdout=recording_log, stderr=recording_log)
                        try:
                            time.sleep(0.5)
                            subprocess.run([str(probe), "press", str(process.pid), "button:Animation"], check=True, timeout=8)
                            if recording.wait(timeout=12) != 0:
                                failures.append("Échec enregistrement animation")
                        finally:
                            if recording.poll() is None:
                                recording.terminate()
                                recording.wait(timeout=5)
                capture = args.output / (name + ".png")
                subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window["kCGWindowNumber"]), str(capture)], check=True, timeout=10)
                elements = read("elements", process.pid)
                (args.output / (name + "-ax.json")).write_text(json.dumps(elements, ensure_ascii=False, indent=2))
                visible = normalized(" ".join(e["label"] for e in elements))
                failures += ["Contenu absent : " + word for word in expected if normalized(word) not in visible]
                if name in ["skills-off", "skills-on"]:
                    toggle = [e for e in elements if e["id"] == "skill-generation-enabled"]
                    expected_value = "1" if name == "skills-on" else "0"
                    if len(toggle) != 1 or toggle[0]["value"] != expected_value:
                        failures.append("État initial du bouton de création incorrect : " + str(toggle))
                    else:
                        # Seul le domaine privé de l’aperçu change ; aucun CLI ne tourne.
                        subprocess.run([str(probe), "press", str(process.pid), "skill-generation-enabled"], check=True, timeout=8)
                        time.sleep(0.2)
                        after = read("elements", process.pid)
                        toggles = [e for e in after if e["id"] == "skill-generation-enabled"]
                        if len(toggles) != 1 or toggles[0]["value"] == expected_value:
                            failures.append("Le bouton de création ne bascule pas")
                        (args.output / (name + "-after-ax.json")).write_text(json.dumps(after, ensure_ascii=False, indent=2))
                if name.startswith("connections-") or name.startswith("skills-") or name == "settings-general":
                    for old in ["Rockstar", "Mémoire commune", "Rappel automatique", "Sons d’Atoll", "Plugins Claude Code"]:
                        if normalized(old) in visible: failures.append("Ancien contrôle présent : " + old)
            except Exception as error:
                failures.append(str(error))
            finally:
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                subprocess.run(["defaults", "delete", "dev.mehdiguiard.atoll.preview." + bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        results.append({"case": name, "passed": not failures, "failures": failures})
        (args.output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
        print(("FAIL " if failures else "PASS ") + name + (": " + "; ".join(failures) if failures else ""), flush=True)
passed = all(r["passed"] for r in results)
raise SystemExit(0 if passed != args.expect_failure else 1)
