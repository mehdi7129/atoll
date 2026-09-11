#!/usr/bin/env python3
"""Recette du rendu réel, sur une copie Debug isolée ; ne lance aucun CLI agent.

Les captures restent à lire : l'OCR détecte les régressions de contenu visible,
pas la qualité graphique ou VoiceOver. --case permet une reprise ciblée.
Le cas explicite settings-codex-model-focus exige la navigation clavier macOS.
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
    "motion-pill": ([], ["QUOTAS", "projet-"]),
    "motion-pill-reduced": (["--preview-reduce-motion"], ["QUOTAS", "projet-"]),
    "motion-notch": (["--preview-notch"], ["QUOTAS", "projet-"]),
    "motion-notch-reduced": (["--preview-notch", "--preview-reduce-motion"], ["QUOTAS", "projet-"]),
    "preview-preferences": (["--preview-skills"], ["APPROUVER"]),
    "skills": (["--preview-skills"], ["PROPOSITION", "SKILL.MD", "mots", "INSTALLÉ ACTUELLEMENT", "APPROUVER"]),
    "skills-position": (["--preview-skills"], ["conversion-3", "2/2", "APPROUVER"]),
    "provider-expanded": ([], ["CLAUDE CODE", "CODEX", "27%"]),
    "list-codex": (["--preview-many"], ["projet-", "autres", "QUOTAS"]),
    "list-claude": (["--preview-many", "--preview-claude"], ["projet-", "autres", "QUOTAS"]),
    "card-claude": (["--preview-cards"], ["CLAUDE", "PLAN", "Vérifier les couleurs", "feedback", "REVISE", "APPROVE"]),
    "card-codex": (["--preview-cards", "--preview-codex-card"], ["apply_patch", "REFUSER", "AUTORISER", "DÉCIDER DANS CODEX"]),
    "detail": (["--preview-detail"], ["retour", "modèle", "contexte"]),
    "detail-context": (["--preview-detail"], ["contexte", "173", "617", "258", "400", "tokens", "67%"]),
    "detail-cli-absent": (["--preview-detail", "--preview-claude"], ["retour", "modèle", "contexte"]),
    "onboarding-unset": (["--preview-onboarding"], ["COMMENCER", "moteur des analyses", "HOOKS INSTALLÉS"]),
    "onboarding-claude": (["--preview-onboarding"], ["COMMENCER", "moteur des analyses", "HOOKS INSTALLÉS"]),
    "onboarding-codex": (["--preview-onboarding"], ["COMMENCER", "moteur des analyses", "HOOKS INSTALLÉS"]),
    "onboarding-navigation": (["--preview-onboarding"], ["COMMENCER", "moteur des analyses", "HOOKS INSTALLÉS"]),
    "settings-codex": (["--preview-codex-settings"], ["Connexion à Codex", "Copier /hooks", "Vérifier la connexion", "Modèle Codex", "Choisir le modèle"]),
    "settings-codex-connected": (["--preview-codex-settings", "--preview-connected"], ["Événements reçus", "Modèle Codex", "Choisir le modèle"]),
    "settings-codex-diagnostic": (["--preview-codex-settings"], ["Projet à vérifier", "Choisir le dossier", "SubagentStart", "SubagentStop"]),
    "settings-codex-model-focus": (["--preview-all-settings", "--preview-settings=codex", "--preview-connected"], ["Modèle Codex", "Choisir un modèle"]),
    "settings-codex-model-choice": (["--preview-codex-settings", "--preview-connected"], ["Modèle de test B"]),
    "settings-codex-model-shared": (["--preview-all-settings", "--preview-settings=codex", "--preview-connected"], ["Modèle Codex", "example-b", "Régler les analyses"]),
    "settings-codex-analysis-claude": (["--preview-codex-settings", "--preview-analysis-claude"], ["Claude Code", "Régler les analyses"]),
    "settings-general": (["--preview-all-settings", "--preview-settings=general"], ["Taille de l'îlot", "Apparence", "Comportement", "Couleur de Codex"]),
    "settings-claude": (["--preview-all-settings", "--preview-settings=claude"], ["Intégration Atoll", "Plugins Claude Code", "Dépannage"]),
    "settings-claude-error": (["--preview-all-settings", "--preview-settings=claude", "--preview-plugin-error"], ["Inventaire indisponible", "Plugins Claude Code"]),
    "settings-learning": (["--preview-all-settings", "--preview-settings=learning"], ["Bilans de session", "Analyses d'Atoll", "Modèle Codex", "Mémoire commune"]),
    "settings-codex-short": (["--preview-codex-settings", "--preview-narrow", "--preview-short"], ["Modèle Codex", "Choisir le modèle"]),
    "settings-codex-model-existing": (["--preview-codex-settings", "--preview-model-selected"], ["Modèle de test B"]),
    "settings-codex-model-obsolete": (["--preview-codex-settings", "--preview-model-obsolete"], ["ancien-modele", "indisponible", "Choisis-en un autre"]),
    "settings-codex-model-offline": (["--preview-codex-settings", "--preview-model-selected", "--preview-models-unavailable"], ["example-b", "Catalogue indisponible"]),
    "settings-codex-narrow-light": (["--preview-codex-settings", "--preview-narrow", "--preview-light"], ["Connexion à Codex", "Modèle Codex", "Choisir le modèle", "Afficher le quota"]),
    "settings-codex-quota-off": (["--preview-codex-settings", "--preview-connected", "--preview-quota-disabled"], ["Afficher le quota"]),
    "settings-codex-removal": (["--preview-codex-settings", "--preview-connected", "--preview-advanced"], ["À installer", "Installer l'intégration Codex"]),
    "settings-codex-uninstalled": (["--preview-codex-settings", "--preview-uninstalled"], ["À installer", "Installer l'intégration Codex"]),
    "settings-codex-advanced": (["--preview-codex-settings", "--preview-connected", "--preview-advanced"], ["Dépannage", "CODEX_HOME", "Fichier des hooks", "Réparer les définitions", "Retirer l'intégration"]),
    "settings-analysis": (["--preview-analysis-settings"], ["Analyses d'Atoll", "Modèle Codex", "Choisir un modèle", "Limites et second abonnement"]),
    "settings-analysis-switch": (["--preview-analysis-settings", "--preview-model-selected"], ["Modèle Codex", "Modèle de test B"]),
    "settings-analysis-claude": (["--preview-analysis-settings", "--preview-analysis-claude"], ["Modèles Claude Code", "Rangement des notes", "Limites et second abonnement"]),
    "settings-analysis-options": (["--preview-analysis-settings"], ["2 analyses maximum", "Quota utilisé maximum", "Quota inconnu", "Utiliser l'autre abonnement"]),
    "settings-analysis-fallback": (["--preview-analysis-settings", "--preview-model-selected"], ["Modèles Claude Code", "Modèle de test B"]),
    "settings-curation-blocked": (["--preview-settings=learning", "--preview-curation-blocked"], ["Rangement bloqué"]),
    "settings-memory-off": (["--preview-settings=learning", "--preview-recall-enabled"], ["Mémoire commune", "Joindre les souvenirs"]),
    "settings-memory-rebuild": (["--preview-settings=learning"], ["Mémoire commune"]),
    "settings-skills-destination": (["--preview-settings=learning"], ["Analyses d'Atoll"]),
    "settings-autonomy": (["--preview-all-settings", "--preview-settings=autonomy"], ["Autonomie de Claude Code", "aucune demande automatiquement", "Codex"]),
    "settings-autonomy-cancel": (["--preview-all-settings", "--preview-settings=autonomy"], ["aucune demande automatiquement"]),
    "settings-autonomy-parked": (["--preview-all-settings", "--preview-settings=autonomy", "--preview-parked-deny"], ["encore suspendues"]),
    "settings-alerts": (["--preview-all-settings", "--preview-settings=alerts", "--preview-uninstalled"], ["Sons d'Atoll", "Claude Code et Codex", "Décision attendue", "Tour terminé"]),
    "settings-alerts-parked": (["--preview-all-settings", "--preview-settings=alerts", "--preview-sounds=parked", "--preview-uninstalled"], ["Anciens sons de Claude Code", "Restaurer les anciens sons"]),
    "settings-alerts-unreadable": (["--preview-all-settings", "--preview-settings=alerts", "--preview-sounds=unreadable"], ["sauvegarde des anciens sons est illisible"]),
    "settings-alerts-detected": (["--preview-all-settings", "--preview-settings=alerts", "--preview-sounds=detected"], ["Anciens sons de Claude Code", "Voir les sons détectés"]),
    "settings-alerts-missing": (["--preview-settings=alerts", "--preview-sound-missing"], ["fichier introuvable", "cet événement est muet"]),
    "settings-catalog-error": (["--preview-codex-settings", "--preview-connected", "--preview-catalog-error"], ["Catalogue indisponible"]),
    "settings-alerts-silent": (["--preview-settings=alerts"], ["Silencieux", "Tour terminé"]),
    "settings-updates": (["--preview-all-settings", "--preview-settings=updates"], ["Version installée", "build", "Vérifier maintenant", "uniquement cette vérification"]),
    "settings-updates-manual": (["--preview-all-settings", "--preview-settings=updates"], ["Vérification simulée"]),
    "settings-about": (["--preview-all-settings", "--preview-settings=about"], ["build", "GPL-3.0-or-later", "Claude Code et Codex CLI"]),
    "idle-notch": (["--preview-empty", "--preview-notch", "--preview-compact"], []),
    "rockstar": (["--preview-empty", "--preview-compact", "--preview-rockstar"], ["18%"]),
    "rockstar-notch": (["--preview-empty", "--preview-compact", "--preview-rockstar", "--preview-notch"], ["18%"]),
    "compact": (["--preview-compact"], ["projet-", "18%"]),
    "compact-claude": (["--preview-compact", "--preview-claude"], ["projet-", "27%"]),
    "light": (["--preview-many", "--preview-light"], ["projet-", "autres", "QUOTAS"]),
}
for pane in ["general", "claude", "codex", "autonomy", "alerts", "learning", "updates", "about"]:
    for light in [False, True]:
        name = "settings-window-" + pane + ("-light" if light else "-dark")
        options = ["--preview-all-settings", "--preview-settings=" + pane, "--preview-narrow", "--preview-short"]
        if light: options.append("--preview-light")
        cases[name] = (options, [])

for width in ["small", "medium", "large"]:
    for notch in [False, True]:
        for light in [False, True]:
            for reduced in [False, True]:
                name = "matrix-" + "-".join([width, "notch" if notch else "pill", "light" if light else "dark", "reduced" if reduced else "motion"])
                options = ["--preview-compact", "--preview-width-" + width]
                if notch: options.append("--preview-notch")
                if light: options.append("--preview-light")
                if reduced: options.append("--preview-reduce-motion")
                cases[name] = (options, ["projet", "18%"])
for index in range(3):
    cases[f"physical-screen-{index}"] = (["--preview-compact", "--preview-native-screen", f"--preview-screen={index}"], ["projet", "18%"])
selected = args.case or [name for name in cases if not name.startswith("physical-screen-") and name != "settings-codex-model-focus"]
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

    keyboard_navigation = read("keyboard", 0)
    (args.output / "keyboard.json").write_text(json.dumps({"navigation_enabled": keyboard_navigation}))
    if "settings-codex-model-focus" in selected and not keyboard_navigation:
        parser.error("settings-codex-model-focus exige Réglages Système → Clavier → Navigation au clavier. Le script ne modifie pas ce réglage.")
    screens = read("screens", 0)
    (args.output / "screens.json").write_text(json.dumps(screens, ensure_ascii=False, indent=2))
    for name in selected:
        if name.startswith("physical-screen-") and int(name.rsplit("-", 1)[1]) >= len(screens):
            parser.error("Écran physique absent : " + name)
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
                subprocess.run([str(probe), "activate", str(process.pid)], check=True)
                time.sleep(0.8)
                front_pid = subprocess.check_output(["osascript", "-e", 'tell application "System Events" to return unix id of first process whose frontmost is true'], text=True).strip()
                for _ in range(3):
                    if front_pid == str(process.pid):
                        break
                    subprocess.run([str(probe), "activate", str(process.pid)], check=True)
                    time.sleep(0.5)
                    front_pid = subprocess.check_output(["osascript", "-e", 'tell application "System Events" to return unix id of first process whose frontmost is true'], text=True).strip()
                if front_pid != str(process.pid):
                    raise RuntimeError("Le focus n'appartient pas à la copie de recette")
                if name == "settings-codex-diagnostic":
                    subprocess.run([str(probe), "press", str(process.pid), "Vérifier la connexion"], check=True)
                    time.sleep(0.5)
                    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window["kCGWindowNumber"]), str(args.output / (name + "-opened.png"))], check=True)
                    (args.output / (name + "-opened-ax.json")).write_text(json.dumps(read("elements", process.pid), ensure_ascii=False, indent=2))
                    subprocess.run([str(probe), "press", str(process.pid), "Vérifier les hooks"], check=True)
                    time.sleep(0.5)
                model_navigation = name in ["settings-codex-model-focus", "settings-codex-model-choice", "settings-codex-model-shared", "settings-codex-model-existing", "settings-codex-model-obsolete", "settings-codex-model-offline"]
                if model_navigation:
                    title = "Choisir le modèle" if name in ["settings-codex-model-focus", "settings-codex-model-choice", "settings-codex-model-shared"] else "Régler les analyses"
                    subprocess.run([str(probe), "press", str(process.pid), title], check=True)
                    time.sleep(0.6)
                model_visible = any(e["id"] == "codex-analysis-model" for e in read("elements", process.pid)) if model_navigation else False
                if name == "settings-codex-model-focus":
                    if not any(e["id"] == "codex-analysis-model" and e.get("focused") == "1" for e in read("elements", process.pid)):
                        case_failures.append("le raccourci n'a pas donné le focus au modèle")
                if model_navigation and not model_visible:
                    case_failures.append("raccourci : choix du modèle inaccessible")
                if name in ["settings-codex-model-choice", "settings-codex-model-shared"] and model_visible:
                    subprocess.run([str(probe), "press", str(process.pid), "codex-analysis-model"], check=True)
                    time.sleep(0.3)
                    subprocess.run([str(probe), "press", str(process.pid), "Modèle de test B"], check=True)
                    time.sleep(0.5)
                    subprocess.run([str(probe), "press", str(process.pid), "Actualiser les modèles"], check=True)
                    time.sleep(0.5)
                if name == "settings-codex-model-shared":
                    subprocess.run([str(probe), "press", str(process.pid), "button:Codex"], check=True)
                    time.sleep(0.5)
                if name == "settings-analysis-switch":
                    subprocess.run([str(probe), "press", str(process.pid), "Claude Code"], check=True)
                    time.sleep(0.5)
                    if any(e["id"] == "codex-analysis-model" for e in read("elements", process.pid)):
                        case_failures.append("modèle Codex encore visible après passage à Claude")
                    subprocess.run([str(probe), "press", str(process.pid), "Codex CLI"], check=True)
                    time.sleep(0.5)
                if name in ["settings-analysis-options", "settings-analysis-fallback"]:
                    subprocess.run([str(probe), "press", str(process.pid), "Limites et second abonnement"], check=True)
                    time.sleep(0.5)
                if name == "settings-analysis-fallback":
                    subprocess.run([str(probe), "press", str(process.pid), "analysis-fallback"], check=True)
                    time.sleep(0.5)
                if name == "settings-memory-off":
                    subprocess.run([str(probe), "press", str(process.pid), "Rappel automatique"], check=True)
                    subprocess.run([str(probe), "press", str(process.pid), "memory-indexing"], check=True)
                    time.sleep(0.5)
                if name == "settings-memory-rebuild":
                    subprocess.run([str(probe), "press", str(process.pid), "Entretien de la mémoire"], check=True)
                    subprocess.run([str(probe), "press", str(process.pid), "Reconstruire l'index"], check=True)
                    time.sleep(0.5)
                    if not any("seront perdus" in e["label"] for e in read("elements", process.pid)):
                        case_failures.append("conséquence de reconstruction absente")
                    subprocess.run(["/opt/homebrew/bin/cliclick", "kp:esc"], check=True)
                if name == "settings-skills-destination":
                    subprocess.run([str(probe), "press", str(process.pid), "skill-destination"], check=True)
                    time.sleep(0.3)
                    subprocess.run([str(probe), "press", str(process.pid), "menu:Claude Code"], check=True)
                    time.sleep(0.3)
                if name == "settings-autonomy-cancel":
                    subprocess.run([str(probe), "press", str(process.pid), "Rockstar"], check=True)
                    time.sleep(0.5)
                    if not any("Activer le mode Rockstar" in e["label"] for e in read("elements", process.pid)):
                        case_failures.append("confirmation Rockstar absente")
                    subprocess.run(["/opt/homebrew/bin/cliclick", "kp:esc"], check=True)
                if name == "settings-alerts-silent":
                    subprocess.run([str(probe), "press", str(process.pid), "sound-decisionNeeded"], check=True)
                    time.sleep(0.3)
                    subprocess.run([str(probe), "press", str(process.pid), "Silencieux"], check=True)
                if name == "settings-catalog-error":
                    subprocess.run([str(probe), "press", str(process.pid), "Skills et plugins Codex"], check=True)
                    subprocess.run([str(probe), "press", str(process.pid), "Lire le catalogue de ce projet"], check=True)
                    subprocess.run([str(probe), "press", str(process.pid), "Skills et plugins Codex"], check=True)
                if name == "settings-updates-manual":
                    subprocess.run([str(probe), "press", str(process.pid), "Vérifier maintenant"], check=True)
                time.sleep(0.3)
                if name == "settings-codex-removal":
                    subprocess.run([str(probe), "press", str(process.pid), "Retirer l'intégration Codex"], check=True)
                    time.sleep(0.5)
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
                if name == "provider-expanded":
                    subprocess.run([str(probe), "press", str(process.pid), "Claude Code"], check=True)
                    time.sleep(0.5)
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
                if name.startswith("settings-"):
                    subprocess.run([str(probe), "activate", str(process.pid)], check=True)
                    b = read("window", process.pid)[0]["kCGWindowBounds"]
                    # La fenêtre Settings peut être devant sans être la fenêtre
                    # clavier ; son titre observé la réactive avant la capture.
                    x, y = int(b["X"] + b["Width"] / 2), int(b["Y"] + 13)
                    subprocess.run(["/opt/homebrew/bin/cliclick", "-r", f"c:={x},={y}"], check=True)
                    time.sleep(0.3)
                path = args.output / (name + ".png")
                subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window["kCGWindowNumber"]), str(path)], check=True)
                observed = read("ocr", path)
                (args.output / (name + ".json")).write_text(json.dumps(observed, ensure_ascii=False, indent=2))
                # Les contrôles de recette au-dessus de l'îlot ne sont pas des preuves.
                text = "\n".join(line["text"] for line in observed["lines"] if name.startswith("onboarding-") or name.startswith("settings-") or name.startswith("skills") or line["y"] > 0.19)
                def normalized(value):
                    return "".join(c for c in unicodedata.normalize("NFD", value.casefold()) if unicodedata.category(c) != "Mn")
                missing = [label for label in expected if normalized(label) not in normalized(text)]
                if name in ["settings-updates", "settings-about"]:
                    version = str(app_info["CFBundleShortVersionString"])
                    build = "build " + str(app_info["CFBundleVersion"])
                    for label in [version, build]:
                        if normalized(label) not in normalized(text): missing.append("version installée incorrecte : " + label)
                missing += case_failures
                if name.startswith("settings-"):
                    elements = read("elements", process.pid)
                    (args.output / (name + "-ax.json")).write_text(json.dumps(elements, ensure_ascii=False, indent=2))
                    disclosure = "Vérifier la connexion" if name in ["settings-codex", "settings-codex-diagnostic"] else "Limites et second abonnement" if name == "settings-analysis-options" else None
                    if disclosure:
                        wanted_expansion = "0" if name == "settings-codex" else "1"
                        if not any(e["role"] == "AXDisclosureTriangle" and disclosure in e["label"] and e["value"] == wanted_expansion for e in elements):
                            missing.append("état du volet inaccessible : " + disclosure)
                    all_labels = "\n".join(e["label"] for e in elements)
                    def preference(key):
                        value = subprocess.run(["defaults", "read", preview_domain, key], capture_output=True, text=True)
                        return value.stdout.strip() if value.returncode == 0 else None
                    if "--preview-all-settings" in options:
                        for label in ["Général", "Claude Code", "Codex", "Autonomie", "Alertes", "Apprentissage", "Mises à jour", "À propos"]:
                            if not any(e["role"] in ["AXRadioButton", "AXButton", "AXCheckBox"] and label in e["label"] for e in elements):
                                missing.append("onglet natif inaccessible : " + label)
                    if name in ["settings-codex", "settings-codex-connected", "settings-codex-model-shared"] and any(e["id"] == "codex-analysis-model" for e in elements):
                        missing.append("édition du modèle encore dupliquée dans Codex")
                    if name == "settings-claude" and "Mémoire commune" in all_labels:
                        missing.append("mémoire commune encore dans Claude")
                    if name == "settings-learning":
                        for label in ["Mémoire commune", "Proposer les skills pour", "Skills appris", "Journal des analyses"]:
                            if label not in all_labels: missing.append("réglage déplacé inaccessible : " + label)
                    if name == "settings-memory-off":
                        if preference("learningProactiveRecall") != "0": missing.append("rappel resté actif sans indexation")
                        if not any(e["id"] == "memory-proactive" and e.get("enabled") == "0" for e in elements):
                            missing.append("rappel non grisé sans indexation")
                    if name == "settings-autonomy-cancel" and preference("autonomyLevel") not in [None, "manual"]:
                        missing.append("Rockstar activé malgré annulation")
                    if name == "settings-skills-destination":
                        if preference("learningSkillDestination") != "claude": missing.append("destination non enregistrée")
                        if preference("analysisProvider") != "codex": missing.append("destination a changé le moteur")
                    if name in ["settings-alerts-silent", "settings-alerts-missing"]:
                        if not any(e["id"] == "sound-preview-decisionNeeded" and e.get("enabled") == "0" for e in elements):
                            missing.append("écoute active pour un événement muet")
                    forbidden = []
                    if name == "settings-alerts": forbidden += ["Anciens sons de Claude", "Installe l'intégration"]
                    if name == "settings-updates":
                        forbidden += ["ne contacte jamais le réseau"]
                        if any(normalized(e["label"].strip()) == "a jour" for e in elements):
                            missing.append("succès de mise à jour inventé")

                    if name not in ["settings-codex-diagnostic", "settings-codex-advanced", "settings-codex-removal", "settings-analysis-options", "settings-analysis-fallback"]:
                        forbidden += ["Projet à vérifier", "Choisir le dossier", "Vérifier les hooks", "CODEX_HOME", "Réparer les définitions", "Quota inconnu"]
                    if name == "settings-codex-connected":
                        forbidden += ["Copier /hooks"]
                    if name == "settings-codex-quota-off":
                        forbidden += ["Actualiser le quota", "% utilisés"]
                    if name in ["settings-analysis-claude", "settings-codex-analysis-claude"]:
                        forbidden += ["Modèle Codex"]
                    missing += ["option superflue visible : " + label for label in forbidden if normalized(label) in normalized(text)]
                    if name.startswith("settings-codex") or name.startswith("settings-analysis"):
                        value = subprocess.run(["defaults", "read", preview_domain, "analysisCodexModel"], capture_output=True, text=True)
                        actual = value.stdout.strip() if value.returncode == 0 else None
                        wanted = "example-b" if name in ["settings-codex-model-choice", "settings-codex-model-shared", "settings-codex-model-existing", "settings-codex-model-offline", "settings-analysis-switch", "settings-analysis-fallback"] else "ancien-modele" if name == "settings-codex-model-obsolete" else ""
                        if actual != wanted:
                            missing.append(f"choix du modèle inattendu : {wanted!r} → {actual!r}")
                if "--preview-compact" in options:
                    elements = read("elements", process.pid)
                    (args.output / (name + "-accessibility.json")).write_text(json.dumps(elements, ensure_ascii=False, indent=2))
                    if any(e["role"] == "AXButton" and "sessions," in e["label"] for e in elements):
                        missing.append("sélecteur de fournisseur encore présent dans le compact")
                    if re.search(r"\b(?:CL|CX)\s*\d", text):
                        missing.append("préfixe CL/CX encore visible")
                    if "--preview-rockstar" in options and not any("Claude Rockstar actif" in e["label"] for e in elements):
                        missing.append("marqueur Rockstar inaccessible")
                    if "--preview-empty" not in options:
                        project = "projet-0" if "--preview-claude" in options else "projet-1"
                        if not any(e["role"] == "AXStaticText" and project in e["label"] for e in elements):
                            missing.append("nom complet du projet inaccessible")
                    lines = [line for line in observed["lines"] if line["y"] > 0.19]
                    activity = next((line for line in lines if "projet" in line["text"]), None)
                    percentage = "27%" if "--preview-claude" in options else "18%"
                    quota = next((line for line in lines if percentage in line["text"]), None)
                    if activity and quota:
                        offset = abs(activity["y"] + activity["height"] / 2 - quota["y"] - quota["height"] / 2)
                        if offset > max(activity["height"], quota["height"]) * 0.6:
                            missing.append("activité et quota sur deux lignes")
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
                (args.output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
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
