#!/usr/bin/env python3
"""A06 : vrai serveur/cartes/sessions, helpers Unix privés, aucun CLI authentifié."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-dir", type=Path)
parser.add_argument("--output", type=Path)
parser.add_argument("--sabotage", choices=["card", "phase", "helper-exit", "disconnected-helper"])
args = parser.parse_args()
work = Path(tempfile.mkdtemp(prefix="atoll-claude-permissions-", dir=Path.home() / "Library/Caches"))
command = ["swift", "build", "--package-path", str(REPO / "AtollCore"), "--build-system", "native",
           "--scratch-path", str(work / "core"), "--jobs", "2"]
if args.build_dir:
    build = args.build_dir.resolve()
else:
    subprocess.run(command, check=True)
    build = Path(subprocess.check_output(command + ["--show-bin-path"], text=True).strip())
objects = sorted((build / "AtollCore.build").glob("*.o"))
assert objects and (build / "Modules").is_dir(), "Core compilé absent"
expected = None
if args.sabotage:
    subprocess.run([sys.executable, str(Path(__file__).resolve()), "--build-dir", str(build),
                    "--output", str(work / "baseline.json")], check=True)
    expected = {"card": "tool event removed unrelated card", "phase": "tool event erased waiting phase",
                "helper-exit": "helper exit did not expire exact card",
                "disconnected-helper": "fast helper exit left a ghost card"}[args.sabotage]
sources = []
for relative in ["App/BridgeServer.swift", "App/InteractionCenter.swift", "App/SessionStore.swift"]:
    text = (REPO / relative).read_text()
    if relative == "App/SessionStore.swift" and args.sabotage in ["card", "phase"]:
        if args.sabotage == "card":
            needle = "        case .stop, .sessionEnd, .userPromptSubmit:"
            replacement = "        case .postToolUse, .stop, .sessionEnd, .userPromptSubmit:"
        else:
            needle = '''        if let index = sessions.firstIndex(where: { $0.id == event.sessionID }),
           sessions[index].phase.isAlive,
           let request = InteractionCenter.shared.pending.first(where: { $0.sessionID == event.sessionID }) {
            sessions[index].phase = .waitingPermission(tool: request.toolSummary ?? request.toolName)
        }'''
            replacement = "        // Garde de phase supprimée par sabotage."
        assert text.count(needle) == 1, "Couture absente ou ambiguë"
        text = text.replace(needle, replacement)
    if relative == "App/BridgeServer.swift":
        if args.sabotage == "helper-exit":
            needle = "            watchPendingHelper(requestID, fd: fd)"
            assert text.count(needle) == 1, "Couture watcher absente ou ambiguë"
            text = text.replace(needle, "            // Watcher retiré par sabotage.")
        if args.sabotage == "disconnected-helper":
            needle = "            if peerResult == -1, errno == ENOTCONN { pendingRepliesTimeout(requestID) }"
            assert text.count(needle) == 1, "Couture connexion fermée absente ou ambiguë"
            text = text.replace(needle, "            // Fermeture déjà survenue ignorée par sabotage.")
        text += '''
// Accès de test limité au filet déjà existant, sur sa queue de sérialisation.
extension BridgeServer {
    func pauseForTesting() { queue.suspend() }
    func resumeForTesting() { queue.resume() }
    func expireForTesting(_ id: String) {
        queue.async { self.pendingRepliesTimeout(id) }
    }
}
'''
    destination = work / Path(relative).name
    destination.write_text(text)
    sources.append(destination)
# Copier exactement le transport du helper, avant son enrichissement/dispatch.
bridge = (REPO / "Bridge/main.swift").read_text()
marker = "// MARK: - Enrichissement + envoi"
assert bridge.count(marker) == 1, "Frontière du transport ambiguë"
client = work / "BridgeClient.swift"
client.write_text(bridge.split(marker)[0])
sources += [client, REPO / "App/TranscriptTailer.swift", REPO / "Shared/ProcessInspector.swift",
            REPO / "Scripts/claude-permission-tests/Stubs.swift", REPO / "Scripts/claude-permission-tests/Main.swift"]
binary = work / "claude-permission-probe"
subprocess.run(["swiftc", "-swift-version", "5", "-whole-module-optimization", "-Onone", "-parse-as-library", "-I", str(build / "Modules"),
                "-lsqlite3", "-import-objc-header", str(REPO / "Shared/BridgingHeader.h"),
                *map(str, sources), *map(str, objects), "-o", str(binary)], check=True)
home = work / "home"
home.mkdir(mode=0o700)
environment = os.environ.copy()
environment.update(CFFIXED_USER_HOME=str(home), CODEX_HOME=str(home / ".codex"))
result = subprocess.run([str(binary), str(home)], env=environment, capture_output=True, text=True, timeout=90)
(work / "stdout.log").write_text(result.stdout)
(work / "stderr.log").write_text(result.stderr)
if expected:
    assert result.returncode != 0 and expected in result.stderr, result.stdout + result.stderr
    report = {"sabotage": args.sabotage, "compiled": True, "baseline": True, "detected": expected}
else:
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
report["evidence"] = str(work)
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(report, indent=2, ensure_ascii=False))
