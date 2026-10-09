#!/usr/bin/env python3
"""Services plugins réels, CLI privés et catalogue contrôlé, sans app ni compte."""
import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--core-build", type=Path, required=True)
    parser.add_argument("--skip-core-build", action="store_true")
    parser.add_argument("--sabotage", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if not args.skip_core_build:
        subprocess.run(["swift", "build", "--package-path", str(REPO / "AtollCore"),
                        "--scratch-path", str(args.core_build), "--build-system", "native", "--jobs", "4"], check=True)
    build = Path(subprocess.check_output([
        "swift", "build", "--package-path", str(REPO / "AtollCore"), "--scratch-path", str(args.core_build),
        "--build-system", "native", "--show-bin-path"], text=True).strip())
    mutations = [
        ("cancel-global", "App/PluginInventory.swift", "Self.inFlight.terminate(scope: scope)",
         "Self.inFlight.terminate()", "cancel", "A12-scope-preserves-mutation"),
        ("unbounded-details", "App/PluginInventory.swift",
         "self.detailConcurrencyLimit = max(1, min(2, detailConcurrencyLimit))",
         "self.detailConcurrencyLimit = 30", "queue", "A13-bounded-concurrency"),
        ("stale-cost-cache", "App/PluginInventory.swift", "return current != nil && current == previous",
         "return true", "cache", "A14-source-invalidates"),
        ("accept-old-cost", "App/PluginInventory.swift",
         "request.generation == operationGeneration && costVersion(for: request.id, in: snapshot) == request.version",
         "request.generation == operationGeneration", "cache", "A14-reject-late-version"),
        ("accept-old-catalog", "App/CodexCatalogState.swift",
         "generation == request && context == requested && !Task.isCancelled", "true",
         "catalog", "A20-reject-stale-result"),
        ("ignore-home-change", "App/CodexCatalogState.swift", "guard context != next else { return }",
         "guard context?.projectPath != next.projectPath || context?.executableOverride != next.executableOverride else { return }",
         "catalog", "A20-loaded-home-clears"),
        ("unbounded-plugin-drain", "App/PluginInventory.swift",
         '''let result = await BoundedProcessRunner.collect(process: process, stdout: stdout, stderr: stderr,
            identity: identity, deadline: deadline, stdoutCap: 4_194_304, stderrCap: 4000)
        return CommandOutcome(status: result.succeeded ? 0 : (result.status == 0 ? 1 : result.status ?? -1),
                              output: result.stdout, errorTail: lastMeaningfulLine(result.stderr),
                              killedByWatchdog: result.timedOut)''',
         '''async let out = Task.detached { BoundedProcessOutput.drain(stdout.fileHandleForReading, cap: 4_194_304) }.value
        async let err = Task.detached { BoundedProcessOutput.drain(stderr.fileHandleForReading, cap: 4000, tail: true) }.value
        let output = await out; let error = await err
        await Task.detached { process.waitUntilExit() }.value
        return CommandOutcome(status: process.terminationStatus, output: output,
                              errorTail: lastMeaningfulLine(error), killedByWatchdog: false)''',
         "pipe", "A09-plugin-inherited-pipe-bounded"),
    ]
    mutations += [
        ("release-live-registry", "App/PluginInventory.swift", "if process.isRunning {",
         "if false, process.isRunning {", "survivor", "A09-plugin-live-search-ownership"),
        ("release-live-scope", "App/PluginInventory.swift", "if inFlight.isRunning(scope: scope) {",
         "if false, inFlight.isRunning(scope: scope) {", "survivor", "A09-plugin-live-search-ownership"),
        ("overlap-live-fallback", "App/PluginInventory.swift", "!Self.inFlight.isRunning(scope: request.token)",
         "true", "survivor", "A09-plugin-live-detail-ownership"),
        ("unbounded-search-refresh-wait", "App/PluginInventory.swift",
         "guard ContinuousClock.now < refreshDeadline else", "guard true else",
         "refresh-wait", "A09-plugin-refresh-wait-search-bounded"),
        ("unbounded-mutation-refresh-wait", "App/PluginInventory.swift",
         "guard ContinuousClock.now < deadline else", "guard true else",
         "refresh-wait", "A09-plugin-refresh-wait-mutation-bounded"),
    ]
    results = []
    with tempfile.TemporaryDirectory(prefix="atoll-plugin-services-") as temporary:
        private = Path(temporary)
        sources = ["App/PluginInventory.swift", "App/CodexCatalogState.swift"]

        def run(name, mutation=None):
            root = private / name
            root.mkdir()
            shutil.copy2(REPO / "Scripts/plugin-tests/fake-cli.py", root / "fake-cli-template")
            compiled = []
            for relative in sources:
                text = (REPO / relative).read_text()
                if mutation and relative == mutation[1]:
                    if text.count(mutation[2]) != 1:
                        raise SystemExit("Couture de sabotage absente ou ambiguë : " + name)
                    text = text.replace(mutation[2], mutation[3])
                if relative == "App/PluginInventory.swift":
                    # Seulement les délais du scénario survivant sont accélérés.
                    # Le vrai run, le registre, les gardes et le budget restent compilés.
                    timing = "let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))"
                    assert text.count(timing) == 1
                    text = text.replace(timing, "let deadline = ContinuousClock.now.advanced(by: .seconds("
                        'ProcessInfo.processInfo.environment["ATOLL_PLUGIN_SURVIVOR"] == "1" ? 0.05 : max(0, timeout)))')
                    waiting = "let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))"
                    assert text.count(waiting) == 2
                    text = text.replace(waiting, "let deadline = ContinuousClock.now.advanced(by: .seconds("
                        'ProcessInfo.processInfo.environment["ATOLL_PLUGIN_WAITING"] == "1" ? 1.0 : timeout))')
                    waiting = "let refreshDeadline = ContinuousClock.now.advanced(by: .seconds(Self.availableTimeout))"
                    assert text.count(waiting) == 1
                    text = text.replace(waiting, "let refreshDeadline = ContinuousClock.now.advanced(by: .seconds("
                        'ProcessInfo.processInfo.environment["ATOLL_PLUGIN_WAITING"] == "1" ? 1.0 : Self.availableTimeout))')
                    collect = "identity: identity, deadline: deadline, stdoutCap: 4_194_304, stderrCap: 4000)"
                    if collect in text:
                        text = text.replace(collect, "identity: identity, deadline: deadline, stdoutCap: 4_194_304, "
                            'stderrCap: 4000, terminationGrace: ProcessInfo.processInfo.environment["ATOLL_PLUGIN_SURVIVOR"] == "1" ? 0.05 : 1)')
                target = root / Path(relative).name
                target.write_text(text)
                compiled.append(str(target))
            command = ["swiftc", "-swift-version", "5", "-D", "DEBUG", "-parse-as-library", "-I", str(build / "Modules"),
                       "-lsqlite3"] + compiled + [str(REPO / "Scripts/plugin-tests/Stubs.swift"),
                       str(REPO / "Scripts/plugin-tests/Main.swift")]
            command += [str(path) for path in sorted((build / "AtollCore.build").glob("*.o"))]
            binary = root / "plugin-tests"
            build_result = subprocess.run(command + ["-o", str(binary)], capture_output=True, text=True, timeout=600)
            (args.output / (name + "-build.log")).write_text(build_result.stdout + build_result.stderr)
            if build_result.returncode:
                raise SystemExit("Compilation échouée ; aucun verdict de sabotage.\n" + build_result.stderr[-5000:])
            environment = dict(os.environ, ATOLL_PLUGIN_TEST_ROOT=str(root), ZDOTDIR=str(root))
            result = subprocess.run([str(binary), mutation[4] if mutation else "all"], env=environment,
                                    capture_output=True, text=True, timeout=90)
            (args.output / (name + ".log")).write_text(result.stdout + result.stderr)
            if mutation:
                passed = result.returncode != 0 and "FAIL " + mutation[5] in result.stderr
                results.append({"name": name, "compiled": True, "detected": passed, "assertion": mutation[5]})
            else:
                passed = result.returncode == 0 and all("PASS " + code in result.stdout for code in ["A09", "A12", "A13", "A14", "A20"])
                if passed:
                    metrics = json.loads(result.stdout.splitlines()[-1])
                    results.append({"name": name, "passed": True, "metrics": metrics})
            (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            if not passed:
                raise SystemExit("Résultat non conforme : " + name + "\n" + result.stdout[-2000:] + result.stderr[-3000:])
            print("PASS " + name, flush=True)

        run("baseline")
        if args.sabotage:
            for mutation in mutations:
                run(mutation[0], mutation)


if __name__ == "__main__":
    main()
