#!/usr/bin/env python3
"""Recette Codex native : définitions sans auth ou tour passif coordonné.

Ne crée aucun thread/tour, ne copie aucun compte et ne lance pas Atoll. Le helper
fourni est copié avant emploi ; seuls status/install-codex sont exécutés. Cette
recette par défaut qualifie l'acceptation des définitions. --fixture --live
exécute un tour payé dans une copie privée déjà lancée par le coordinateur.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import shlex
import subprocess
import tempfile
import threading
import time


class RPC:
    def __init__(self, executable, env, cwd, root, bypass_hook_trust=False):
        self.messages = []
        self.pending = []
        self.incoming = queue.Queue()
        self.stderr = (root / "app-server.stderr").open("wb")
        command = [executable, "-c", "features.plugins=false"]
        if bypass_hook_trust:
            command += ["--dangerously-bypass-hook-trust"]
        self.process = subprocess.Popen(
            command + ["app-server", "--listen", "stdio://"],
            cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.stderr, text=True, bufsize=1)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.process.stdout:
            try:
                self.incoming.put(json.loads(line))
            except json.JSONDecodeError:
                self.incoming.put({"invalidLine": line.rstrip()})
        self.incoming.put(None)

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + "\n")
        self.process.stdin.flush()

    def request(self, identifier, method, params):
        self.send({"id": identifier, "method": method, "params": params})
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            value = self.incoming.get(timeout=max(0.01, deadline - time.monotonic()))
            if value is None:
                raise RuntimeError("app-server a fermé stdout avant la réponse")
            self.messages.append(value)
            if value.get("id") == identifier:
                assert "error" not in value, value
                return value["result"]
            self.pending.append(value)
        raise TimeoutError(method)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            # Popen possède ce processus enfant ; aucun PID externe n'est ciblé.
            self.process.terminate()
            self.process.wait(timeout=5)
        self.reader.join(timeout=1)
        self.stderr.close()


def private_environment(root):
    # Une liste blanche exclut aussi les credentials injectés par le shell.
    env = {key: os.environ[key] for key in ("PATH", "USER", "LOGNAME", "LANG", "LC_ALL")
           if key in os.environ}
    env.update(HOME=str(root / "home"), CFFIXED_USER_HOME=str(root / "home"),
               CODEX_HOME=str(root / "codex"), TMPDIR=str(root / "tmp"),
               XDG_CACHE_HOME=str(root / "cache"), XDG_CONFIG_HOME=str(root / "config"))
    return env


def read_state(path, codex_home, thread_id=None, phase=None, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            state = json.loads(path.read_text())
            assert Path(state["codexHome"]).resolve() == codex_home
            assert state["codexServerRunning"] is True
            if thread_id is None:
                return state
            # AgentSession sépare les fournisseurs par un préfixe public ; le
            # protocole natif utilise, lui, le session_id sans ce préfixe.
            rows = [row for row in state["sessions"] if row["id"] == "codex:" + thread_id and row["provider"] == "codex"]
            if rows and phase in rows[0]["phase"]:
                assert rows[0]["stateConfirmedByHook"] is True, rows[0]
                assert state["pendingInteractions"] == [], state
                return state
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.1)
    raise AssertionError(f"État natif absent : {thread_id=} {phase=} dans {path}")


def self_check():
    """Le wire session_id doit corréler l'id applicatif préfixé, strictement."""
    with tempfile.TemporaryDirectory(prefix="atoll-native-state-check-", dir="/private/tmp") as directory:
        root = Path(directory)
        codex = root / "codex"
        codex.mkdir()
        state_file = root / "state.json"
        row = {"id": "codex:native-thread-fixture", "provider": "codex",
               "phase": "awaitingPermission(tool: Bash)", "stateConfirmedByHook": True}
        state = {"codexHome": str(codex), "codexServerRunning": True,
                 "sessions": [row], "pendingInteractions": []}
        state_file.write_text(json.dumps(state))
        assert read_state(state_file, codex, "native-thread-fixture", "awaitingPermission", timeout=0.01) == state
        for identifier, provider, wire_id in (
                ("native-thread-fixture", "codex", "native-thread-fixture"),
                ("codex:native-thread-fixture", "claude", "native-thread-fixture"),
                ("codex:another-thread", "codex", "native-thread-fixture")):
            row.update(id=identifier, provider=provider)
            state_file.write_text(json.dumps(state))
            try:
                read_state(state_file, codex, wire_id, "awaitingPermission", timeout=0.01)
            except AssertionError:
                continue
            raise AssertionError("Une session étrangère ou sans préfixe a été acceptée")
    print("PASS self-check : préfixe provider, fournisseur et thread exacts")


def live_fixture(args):
    """Un seul tour payé, seulement après lancement coordonné de l'app privée."""
    manifest = json.loads(args.fixture.read_text())
    root = Path(manifest["root"]).resolve()
    assert root.parent == Path("/private/tmp") and root.name.startswith("atoll-native-cli-")
    home, codex_home, project, app = [Path(manifest[key]).resolve()
                                     for key in ("home", "codexHome", "project", "app")]
    assert home == root / "home" and codex_home == root / "codex" and project == root / "project"
    assert app.parent == root and (codex_home / "auth.json").is_file()
    assert args.model, "Choisir explicitement le modèle de cette recette"
    state_path = home / "Library/Application Support/Atoll/state.json"
    initial = read_state(state_path, codex_home)
    (root / "native-state-before.json").write_text(json.dumps(initial, indent=2))
    env = private_environment(root)
    for key in ("TMPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME"):
        Path(env[key]).mkdir(mode=0o700, exist_ok=True)
    env["CODEX_HOME"] = str(codex_home)
    hooks_path = codex_home / "hooks.json"
    definitions = json.loads(hooks_path.read_text())
    assert set(definitions["hooks"]) == {"PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
        "PostCompact", "SessionStart", "SessionEnd", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "Interrupt"}
    wrapper = home / ".atoll/bin/atoll-codex-bridge"
    assert wrapper.is_file()
    helper = app / "Contents/Helpers/atoll-bridge"
    helper_hash = hashlib.sha256(helper.read_bytes()).hexdigest()
    records = root / "native-hook-records"
    records.mkdir(mode=0o700, exist_ok=True)
    assert not list(records.iterdir()), "Une fixture ne doit servir qu'à un seul tour natif"
    recorder = root / "native-hook-recorder.py"
    recorder.write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys,time,uuid
from pathlib import Path
payload=sys.stdin.buffer.read()
started=time.time()
result=subprocess.run([sys.argv[1]],input=payload,capture_output=True,timeout=5)
record={"payload":json.loads(payload),"stdoutBytes":len(result.stdout),"stderrBytes":len(result.stderr),
        "exitCode":result.returncode,"duration":time.time()-started}
Path(sys.argv[2],uuid.uuid4().hex+".json").write_text(json.dumps(record,indent=2))
# Relais transparent : un écart du helper n'est pas masqué à son CLI natif.
sys.stdout.buffer.write(result.stdout);sys.stdout.buffer.flush()
sys.stderr.buffer.write(result.stderr);sys.stderr.buffer.flush()
sys.exit(result.returncode)
''')
    recorder.chmod(0o700)
    record_command = shlex.join([shutil.which("python3"), str(recorder), str(wrapper), str(records)])
    for event, groups in definitions["hooks"].items():
        assert len(groups) == 1 and len(groups[0]["hooks"]) == 1, event
        handler = groups[0]["hooks"][0]
        assert handler["command"] in ('"$HOME/.atoll/bin/atoll-codex-bridge"', str(wrapper), '"' + str(wrapper) + '"'), handler
        assert handler.get("async", False) is (event not in ("Stop", "SessionEnd")), handler
        assert handler["timeout"] == 3, handler
        handler["command"] = record_command
    (root / "native-original-hooks.json").write_bytes(hooks_path.read_bytes())
    hooks_path.write_text(json.dumps(definitions, indent=2) + "\n")
    rpc = RPC(args.codex, env, project, root)
    approval_requests, received, thread_id, turn_id = [], [], None, None
    completed = None
    try:
        rpc.request(1, "initialize", {"clientInfo": {"name": "atoll_native_passive_fixture", "version": "0.1.0"},
                                      "capabilities": {"experimentalApi": True}})
        rpc.send({"method": "initialized"})
        listed = rpc.request(2, "hooks/list", {"cwds": [str(project)]})
        hooks = listed["data"][0]["hooks"]
        assert len(hooks) == 12 and not listed["data"][0].get("errors"), listed
        assert all(hook["command"] == record_command and Path(hook["sourcePath"]).resolve() == hooks_path for hook in hooks)
        # Confiance native des hashes effectivement revus, dans CE home jetable.
        rpc.request(3, "config/value/write", {"filePath": str(codex_home / "config.toml"), "keyPath": "hooks.state",
                    "value": {hook["key"]: {"trusted_hash": hook["currentHash"]} for hook in hooks}, "mergeStrategy": "replace"})
        trusted = rpc.request(4, "hooks/list", {"cwds": [str(project)]})
        assert all(hook["trustStatus"] == "trusted" for hook in trusted["data"][0]["hooks"]), trusted
        (root / "native-trusted-hooks.json").write_text(json.dumps(trusted, indent=2))
        started = rpc.request(5, "thread/start", {"model": args.model, "cwd": str(project), "sandbox": "read-only",
                    "approvalPolicy": "on-request", "approvalsReviewer": "user", "ephemeral": False,
                    "developerInstructions": "This is a minimal native approval test. Execute only the one command requested. Never delegate, browse, retry, or run another tool. After it completes, finish immediately."})
        thread_id = started["thread"]["id"]
        marker = root / "native-permission-marker"
        command = "printf atoll_native_permission > " + shlex.quote(str(marker))
        prompt = ("Native approval test. Call exec_command exactly once with cmd=" + json.dumps(command)
                  + ", sandbox_permissions=require_escalated, justification=Native permission test. "
                    "The host will decide. After the command completes, do not retry or use another tool; answer only done.")
        turn = rpc.request(6, "turn/start", {"threadId": thread_id, "input": [{"type": "text", "text": prompt}], "effort": "low"})
        turn_id = turn["turn"]["id"]
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            value = rpc.pending.pop(0) if rpc.pending else rpc.incoming.get(timeout=max(0.1, deadline - time.monotonic()))
            if value is None:
                raise RuntimeError("app-server fermé pendant le tour")
            if value not in rpc.messages:
                rpc.messages.append(value)
            method, params = value.get("method"), value.get("params", {})
            received.append(value)
            if method == "item/commandExecution/requestApproval":
                approval_requests.append(value)
                assert params["threadId"] == thread_id and params["turnId"] == turn_id, value
                assert "accept" in params["availableDecisions"], value
                native_command = shlex.split(params["command"])
                assert len(native_command) == 3 and native_command[0] in ("/bin/zsh", "/bin/bash", "/bin/sh")
                assert native_command[1:] == ["-lc", command] and Path(params["cwd"]).resolve() == project, params
                waiting = read_state(state_path, codex_home, thread_id, "awaitingPermission")
                (root / "native-state-waiting.json").write_text(json.dumps(waiting, indent=2))
                # L'absence de réponse Atoll doit laisser la demande native ouverte.
                time.sleep(1)
                read_state(state_path, codex_home, thread_id, "awaitingPermission", timeout=1)
                assert not marker.exists(), "La commande a précédé l'accord natif"
                # Seul le client natif rend une décision, jamais le helper Atoll.
                rpc.send({"id": value["id"], "result": {"decision": "accept"}})
            elif method and "id" in value:
                rpc.send({"id": value["id"], "error": {"code": -32601, "message": "Unsupported in minimal native fixture"}})
                raise AssertionError("Requête native inattendue : " + method)
            elif method == "turn/completed" and params.get("turn", {}).get("id") == turn_id:
                completed = params["turn"]
                break
        assert completed and completed["status"] == "completed", completed
        assert len(approval_requests) == 1, approval_requests
        assert marker.read_text() == "atoll_native_permission", "Marqueur de la commande approuvée absent ou différent"
        commands = [value for value in received if value.get("method") == "item/started"
                    and value.get("params", {}).get("item", {}).get("type") == "commandExecution"]
        assert len(commands) == 1, "La recette doit rester à une seule commande"
        idle = read_state(state_path, codex_home, thread_id, "awaitingInput")
        (root / "native-state-after-stop.json").write_text(json.dumps(idle, indent=2))
        assert any(value.get("method") == "hook/completed" and value["params"]["run"]["eventName"] == "stop"
                   and value["params"]["run"]["executionMode"] == "sync" and value["params"]["run"]["status"] == "completed"
                   and not value["params"]["run"]["entries"] for value in received), "Stop synchrone natif non confirmé"
    finally:
        rpc.close()
        (root / "native-rpc.json").write_text(json.dumps(rpc.messages, indent=2))
    observations = [json.loads(path.read_text()) for path in records.glob("*.json")]
    events = [observation["payload"]["hook_event_name"] for observation in observations]
    assert "PermissionRequest" in events and "Stop" in events, events
    assert all(observation["exitCode"] == 0 and observation["stdoutBytes"] == 0 and observation["stderrBytes"] == 0
               for observation in observations), observations
    assert hashlib.sha256(helper.read_bytes()).hexdigest() == helper_hash, "L'artefact a changé"
    report = {"result": "PASS", "scope": "native_permission_and_stop_actual_app_and_helper", "fixture": str(root),
              "model": args.model, "turnsStarted": 1, "nativeDecision": "accept", "nativeDeclineQualified": False,
              "commands": 1, "approvalRequests": len(approval_requests),
              "events": events, "threadId": thread_id, "turnId": turn_id, "helperSHA256": helper_hash,
              "helperStdoutBytes": sum(observation["stdoutBytes"] for observation in observations),
              "appWaitingObserved": True, "appIdleAfterStopObserved": True, "tuiIdentityQualified": False,
              "trustScope": str(codex_home / "config.toml"), "artifactModified": False}
    output = args.output or root / "native-results.json"
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path,
                        help="helper d'un artefact construit ; sera copié dans la fixture")
    parser.add_argument("--codex", default=shutil.which("codex"))
    parser.add_argument("--output", type=Path, help="rapport JSON, sans credentials")
    parser.add_argument("--fixture", type=Path, help="fixture.json préparée ; exige --live et l'app privée déjà lancée")
    parser.add_argument("--live", action="store_true", help="un seul tour modèle authentifié, après coordination explicite")
    parser.add_argument("--model", help="modèle explicite pour --live")
    parser.add_argument("--self-check", action="store_true", help="corrélation des identifiants, hors ligne")
    args = parser.parse_args()
    if args.self_check:
        return self_check()
    if args.fixture or args.live:
        assert args.fixture and args.live and args.codex, "--fixture et --live sont indissociables"
        return live_fixture(args)
    assert args.codex and args.helper and args.helper.is_file(), "Codex et helper requis"
    root = Path(tempfile.mkdtemp(prefix="atoll-native-passive-", dir="/private/tmp"))
    for name in ("home", "codex", "project", "tmp", "cache", "config"):
        (root / name).mkdir(mode=0o700)
    env = private_environment(root)
    helper = root / "atoll-bridge"
    shutil.copy2(args.helper, helper)
    assert hashlib.sha256(helper.read_bytes()).digest() == hashlib.sha256(args.helper.read_bytes()).digest()
    status = json.loads(subprocess.check_output([str(helper), "status"], env=env, text=True))
    assert Path(status["memoryIndexPath"]).resolve() == root / "home/.atoll/memory.db"
    assert Path(status["codex"]["home"]).resolve() == root / "codex"
    subprocess.run([str(helper), "install-codex"], env=env, check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    definitions_path = root / "codex/hooks.json"
    definitions_before = definitions_path.read_bytes()
    definitions = json.loads(definitions_before)["hooks"]
    expected = {}
    for event, groups in definitions.items():
        handlers = [hook for group in groups for hook in group["hooks"]]
        assert len(handlers) == 1, (event, handlers)
        expected[event[0].lower() + event[1:]] = handlers[0]
    rpc = RPC(args.codex, env, root / "project", root)
    try:
        initialized = rpc.request(1, "initialize", {"clientInfo": {
            "name": "atoll_native_readonly_fixture", "title": "Atoll private hook validation", "version": "0.1.0"}})
        rpc.send({"method": "initialized"})
        result = rpc.request(2, "hooks/list", {"cwds": [str(root / "project")]})
    finally:
        rpc.close()
        (root / "rpc.json").write_text(json.dumps(rpc.messages, indent=2))
    assert len(result["data"]) == 1, result
    listing = result["data"][0]
    assert not listing.get("errors"), listing.get("errors")
    hooks = listing["hooks"]
    assert len(hooks) == len(expected) == 12, hooks
    for hook in hooks:
        wanted = expected[hook["eventName"]]
        assert hook["command"] == wanted["command"], hook
        assert hook.get("async", False) is wanted.get("async", False), hook
        assert hook["timeoutSec"] == wanted["timeout"] == 3, hook
        assert hook["enabled"] is True, hook
        assert hook["trustStatus"] not in ("trusted", "managed"), hook
    assert definitions_path.read_bytes() == definitions_before, "hooks/list a modifié hooks.json"
    assert not (root / "codex/auth.json").exists(), "auth inattendue"
    assert not (root / "codex/config.toml").exists(), "config/trust inattendue"
    assert not any(value.get("method", "").startswith(("thread/", "turn/")) for value in rpc.messages)
    report = {"result": "PASS", "scope": "native_definitions_no_auth_no_model",
              "root": str(root), "codexVersion": subprocess.check_output([args.codex, "--version"], env=env, text=True).strip(),
              "helperSHA256": hashlib.sha256(helper.read_bytes()).hexdigest(),
              "initialized": initialized, "recognized": len(hooks),
              "events": [{key: hook.get(key) for key in ("eventName", "async", "timeoutSec", "enabled", "trustStatus")}
                         for hook in hooks], "authCopied": False, "modelCalls": 0,
              "runtimeEventsQualified": False, "trustGranted": False}
    output = args.output or root / "results.json"
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"result": report["result"], "recognized": len(hooks), "report": str(output), "fixture": str(root)}))


if __name__ == "__main__":
    main()
