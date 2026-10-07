#!/usr/bin/env python3
"""Mesure le vrai transport Codex sur un home privé et un catalogue Git local.

Sans --live, aucun compte n'est copié. --live autorise uniquement les RPC de
lecture quota/modèles ; aucune conversation ni génération de modèle. La copie
privée d'authentification est retirée dans finally, jamais exposée aux journaux.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import tempfile
import time


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--auth-source", type=Path)
    parser.add_argument("--duration", type=float, default=0)
    parser.add_argument("--interval", type=float, default=120)
    args = parser.parse_args()
    if args.duration < 0 or args.interval <= 0:
        parser.error("Durée positive ou nulle, intervalle strictement positif.")
    if args.auth_source and not args.live:
        parser.error("--auth-source exige --live.")
    repo = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    if (output / "result.json").exists():
        parser.error("Le résultat existe déjà : choisir un nouveau dossier.")
    root = Path(tempfile.mkdtemp(prefix="atoll-read-storage-", dir="/private/tmp"))
    os.chmod(root, 0o700)
    home, codex, git_repo, shims = [root / name for name in ["home", "codex", "marketplace", "bin"]]
    for path in [home, codex, git_repo, shims]:
        path.mkdir(mode=0o700)
    logs = root / "git-commands.jsonl"
    launches = root / "launches.jsonl"
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
           "CFFIXED_USER_HOME": str(home), "CODEX_HOME": str(codex),
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "LANG": "en_US.UTF-8"}
    (git_repo / ".claude-plugin").mkdir()
    write_json(git_repo / ".claude-plugin/marketplace.json", {
        "name": "atoll-storage-fixture", "owner": {"name": "Local test"},
        "plugins": [{"name": "fixture", "source": "./plugin"}]})
    (git_repo / "plugin/.claude-plugin").mkdir(parents=True)
    write_json(git_repo / "plugin/.claude-plugin/plugin.json", {
        "name": "fixture", "description": "Local fixture", "version": "1.0.0"})
    for command in [["init", "-q"], ["add", "."],
                    ["-c", "user.name=Local test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"]]:
        subprocess.run(["/usr/bin/git", *command], cwd=git_repo, env=env, check=True, capture_output=True)
    (codex / "config.toml").write_text(
        'cli_auth_credentials_store = "file"\n'
        '[marketplaces.atoll-storage-fixture]\nsource_type = "git"\n'
        f'source = "{git_repo.as_uri()}"\n'
        '[plugins."fixture@atoll-storage-fixture"]\nenabled = true\n')
    python = shutil.which("python3")
    git_shim = shims / "git"
    git_shim.write_text(f"#!{python}\nimport json,os,sys\n"
        "with open(os.environ['ATOLL_READ_GIT_LOG'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
        "os.execv('/usr/bin/git', ['/usr/bin/git', *sys.argv[1:]])\n")
    git_shim.chmod(0o700)
    codex_shim = shims / "codex"
    executable = args.codex.resolve(strict=True)
    codex_shim.write_text(f"#!{python}\nimport json,os,sys,time\n"
        f"with open({str(launches)!r}, 'a') as f: f.write(json.dumps({{'at':time.time(),'args':sys.argv[1:]}})+'\\n')\n"
        f"os.execv({str(executable)!r}, [{str(executable)!r}, *sys.argv[1:]])\n")
    codex_shim.chmod(0o700)
    env["PATH"] = str(shims) + ":" + env["PATH"]
    env["ATOLL_READ_GIT_LOG"] = str(logs)
    # Le témoin prouve que la fixture et l'observation détectent réellement
    # une synchronisation. Il n'utilise jamais la copie d'authentification.
    control_home = root / "control"
    control_home.mkdir(mode=0o700)
    shutil.copyfile(codex / "config.toml", control_home / "config.toml")
    control_log = root / "control-git.jsonl"
    control_env = {**env, "CODEX_HOME": str(control_home), "ATOLL_READ_GIT_LOG": str(control_log)}
    control = subprocess.Popen([str(executable), "app-server", "--listen", "stdio://"],
        env=control_env, cwd=control_home, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        initialize = {"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "atoll-storage-control", "version": "1"}}}
        control.stdin.write(json.dumps(initialize).encode() + b"\n")
        control.stdin.flush()
        time.sleep(2)
        try:
            control.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            control.terminate()
            try:
                control.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                control.kill()
                control.communicate(timeout=1)
    finally:
        if control.poll() is None:
            control.kill()
            control.wait(timeout=2)
    control_commands = [json.loads(line) for line in control_log.read_text().splitlines()] if control_log.exists() else []
    positive = any("clone" in command and git_repo.as_uri() in command for command in control_commands)
    write_json(output / "positive-control.json", {"passed": positive, "commands": control_commands,
        "exitCode": control.returncode, "authenticated": False})
    if not positive:
        raise RuntimeError("Témoin positif absent : la fixture n'a produit aucun clone Git observable")
    subprocess.run(["swift", "build", "--build-system", "native", "--package-path", str(repo / "AtollCore")], check=True)
    build = Path(subprocess.check_output(["swift", "build", "--build-system", "native",
        "--package-path", str(repo / "AtollCore"), "--show-bin-path"], text=True).strip())
    source = root / "Main.swift"
    source.write_text('''import Foundation
import AtollCore
@main enum Main {
    static func main() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let home = URL(fileURLWithPath: CommandLine.arguments[2])
        let mode = CommandLine.arguments[3]
        var report: [String: Any] = ["mode": mode]
        if mode == "quota" {
            switch CodexAccountClient.read(executable: executable, home: home, timeout: 20) {
            case .available(let quota):
                report["available"] = true
                report["bucketCount"] = quota.buckets.count
                report["fresh"] = quota.isFresh(at: Date())
            case .unavailable(let reason):
                report["available"] = false
                report["reason"] = reason
            }
        } else {
            switch CodexReadClient.read(.models(), executable: executable, home: home, timeout: 20) {
            case .available(let data):
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                report["available"] = true
                report["modelCount"] = (result?["data"] as? [Any])?.count ?? 0
            case .unavailable(let reason):
                report["available"] = false
                report["reason"] = reason
            }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
''')
    binary = root / "read-transport"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(build / "Modules"),
        "-lsqlite3", str(source), *[str(x) for x in sorted((build / "AtollCore.build").glob("*.o"))],
        "-o", str(binary)], check=True)
    auth = codex / "auth.json"
    source_hash = hashlib.sha256((repo / "AtollCore/Sources/AtollCore/CodexReadClient.swift").read_bytes()).hexdigest()
    report = {"fixture": str(root), "live": args.live, "executable": str(executable),
              "transportSha256": source_hash,
              "harnessBinarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "positiveControl": positive,
              "durationRequested": args.duration, "reads": [], "passed": False}
    def inventory():
        staging = codex / ".tmp/marketplaces/.staging"
        entries = list(staging.iterdir()) if staging.exists() else []
        allocated = sum(p.stat().st_blocks * 512 for d in entries for p in d.rglob("*") if p.is_file())
        return {"directories": len(entries), "allocatedBytes": allocated}
    def read(mode):
        start = time.monotonic()
        usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
        result = subprocess.run([str(binary), str(codex_shim), str(codex), mode], env=env,
            cwd=root, capture_output=True, text=True, timeout=30)
        usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        if result.returncode:
            raise RuntimeError(f"Transport terminé avec code {result.returncode}")
        value = json.loads(result.stdout)
        value.update(elapsed=round(time.monotonic() - start, 3), at=time.time(), staging=inventory())
        # Temps CPU cumulé du harness et de ses enfants récoltés, hors build.
        value["cpuSeconds"] = round((usage_after.ru_utime + usage_after.ru_stime)
                                    - (usage_before.ru_utime + usage_before.ru_stime), 4)
        value["gitCommands"] = len(logs.read_text().splitlines()) if logs.exists() else 0
        report["reads"].append(value)
        write_json(output / "progress.json", report)
        print(json.dumps(value, ensure_ascii=False), flush=True)
        if value["gitCommands"] or value["staging"]["directories"]:
            raise RuntimeError("Synchronisation Git ou staging observé pendant une lecture isolée")
        if mode == "models" and (not value["available"] or value.get("modelCount", 0) == 0):
            raise RuntimeError("Liste des modèles absente : la mesure ne peut pas réussir sans réponse Codex")
        if not args.live and mode == "quota" and not value["available"] and value.get("reason") != "connexion requise — lance codex login":
            raise RuntimeError("Échec inattendu de la lecture sans compte")
        if args.live and (not value["available"] or (mode == "quota" and not value.get("fresh"))):
            raise RuntimeError("Lecture authentifiée indisponible ou périmée")
    try:
        if args.live:
            origin = args.auth_source or Path.home() / ".codex/auth.json"
            with origin.open("rb") as input_file, auth.open("xb") as output_file:
                os.chmod(auth, 0o600)
                shutil.copyfileobj(input_file, output_file)
        report["startedAt"] = time.time()
        start = time.monotonic()
        read("models")
        next_read = start
        while True:
            pause = next_read - time.monotonic()
            if pause > 0:
                time.sleep(pause)
            read("quota")
            if time.monotonic() - start >= args.duration:
                break
            next_read += args.interval
        report["durationMeasured"] = round(time.monotonic() - start, 3)
        report["passed"] = True
    finally:
        if auth.exists():
            auth.unlink()
        report["authCopyRemoved"] = not auth.exists()
        report["finishedAt"] = time.time()
        report["finalStaging"] = inventory()
        for name, path in [("git-commands.jsonl", logs), ("launches.jsonl", launches)]:
            if path.exists():
                shutil.copyfile(path, output / name)
        write_json(output / "result.json", report)
    print("PASS transport isolé : aucune synchronisation Git ni staging", flush=True)


if __name__ == "__main__":
    main()
