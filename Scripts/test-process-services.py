#!/usr/bin/env python3
"""Services réels Fleet/Keychain/helper, fixtures privées, aucun CLI authentifié."""
import argparse
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--build-dir', type=Path, required=True)
parser.add_argument('--sabotage', choices=['heartbeat', 'serialization', 'coalescing', 'barrier', 'fleet-ownership', 'keychain-ownership'])
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
inputs = ['App/FleetPoller.swift', 'App/ModelQuotaPoller.swift', 'App/HookInstaller.swift',
          'App/ClaudeExecutable.swift', 'App/CodexExecutable.swift',
          'AtollCore/Sources/AtollCore/BoundedProcessRunner.swift']
report = {'source_sha256': {p: hashlib.sha256((repo / p).read_bytes()).hexdigest() for p in inputs}, 'scenarios': []}
with tempfile.TemporaryDirectory(prefix='atoll-process-services-') as temporary:
    root = Path(temporary)
    source = root / 'HookInstaller.swift'
    text = (repo / 'App/HookInstaller.swift').read_text()
    if args.sabotage and not args.sabotage.endswith('ownership'):
        needle, replacement = {
            'heartbeat': ('let result = try await BoundedProcessRunner.run(process, timeout: timeout,',
                          'Thread.sleep(forTimeInterval: 0.4)\n            let result = try await BoundedProcessRunner.run(process, timeout: timeout,'),
            'serialization': ('if let previous { await previous.value }', '_ = previous'),
            'coalescing': ('if let (id, operation) = pending[key], tailID == id',
                           'if let (_, operation) = pending[key]'),
            'barrier': ('while let operation = tail {\n            let id = tailID\n            await operation.value\n            if tailID == id { break }\n        }',
                        'if let tail { await tail.value }'),
        }[args.sabotage]
        assert text.count(needle) == 1
        text = text.replace(needle, replacement)
    # Témoins dans la copie compilée : prouver l'entrée des appels et de la
    # barrière, sans supposer que créer une Task suffit à l'avoir exécutée.
    needle = 'guard !CodexPreview.enabled else { return }'
    assert text.count(needle) == 1
    text = text.replace(needle, 'HookFixtureProbe.calls.append(verb)\n        ' + needle)
    needle = 'static func waitForPendingOperation() async {'
    assert text.count(needle) == 1
    text = text.replace(needle, needle + '\n        HookFixtureProbe.barrierEntered = true')
    source.write_text(text)
    objects = sorted((args.build_dir / 'AtollCore.build').glob('*.o'))
    assert objects
    fleet, keychain = repo / 'App/FleetPoller.swift', repo / 'App/ModelQuotaPoller.swift'
    if args.sabotage in ['fleet-ownership', 'keychain-ownership']:
        original, needle = (fleet, 'guard !collectingProbe, activeProbe?.isRunning != true else { return nil }') if args.sabotage == 'fleet-ownership' else (keychain, 'guard !collectingKeychainRead, activeKeychainRead?.isRunning != true else { return nil }')
        text = original.read_text()
        assert text.count(needle) == 1
        copy = root / original.name
        guard = 'guard !collectingProbe else { return nil }' if args.sabotage == 'fleet-ownership' else 'guard !collectingKeychainRead else { return nil }'
        copy.write_text(text.replace(needle, guard))
        if args.sabotage == 'fleet-ownership': fleet = copy
        else: keychain = copy
    # Même primitive, seule la capture d'identité peut être rendue indisponible
    # dans les deux scénarios dédiés. Aucun signal réel vers un PID inconnu.
    runner = root / 'BoundedProcessRunner.swift'
    text = (repo / 'AtollCore/Sources/AtollCore/BoundedProcessRunner.swift').read_text()
    needle = 'let identity = try ProcessIdentity.launch(process)'
    assert text.count(needle) == 1
    runner.write_text('import AtollCore\n' + text.replace(needle,
        'let capturedIdentity = try ProcessIdentity.launch(process)\n                let identity = ProcessInfo.processInfo.environment["ATOLL_PROCESS_NO_IDENTITY"] == "1" ? nil : capturedIdentity'))
    # Seuls les deux emplacements globaux sont relocalisés : ils ne doivent
    # jamais court-circuiter le fallback vers le vrai CLI installé sur l'hôte.
    codex = root / 'CodexExecutable.swift'
    codex.write_text((repo / 'App/CodexExecutable.swift').read_text()
        .replace('"/opt/homebrew/bin/codex"', json.dumps(str(root / 'absent-homebrew-codex')))
        .replace('"/usr/local/bin/codex"', json.dumps(str(root / 'absent-local-codex'))))
    binary = root / 'process-services'
    result = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
        '-I', str(args.build_dir / 'Modules'), '-lsqlite3', str(source),
        str(fleet), str(keychain), str(runner),
        str(repo / 'App/ClaudeExecutable.swift'), str(codex),
        str(repo / 'Scripts/process-tests/Stubs.swift'), str(repo / 'Scripts/process-tests/Main.swift'),
        *map(str, objects), '-o', str(binary)], capture_output=True, text=True, timeout=900)
    (args.output / 'compile.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    cases = ['fleet', 'keychain', 'heartbeat', 'large-stderr', 'serial', 'writer-exclusion', 'alternating', 'queue-barrier', 'precondition-order', 'interruption', 'nonzero']
    cases += ['resolve-claude', 'resolve-codex', 'resolve-claude-inherited', 'resolve-codex-inherited']
    cases += ['fleet-ownership', 'keychain-ownership']
    if args.sabotage:
        cases = [{'heartbeat': 'heartbeat', 'serialization': 'serial', 'coalescing': 'alternating', 'barrier': 'queue-barrier', 'fleet-ownership': 'fleet-ownership', 'keychain-ownership': 'keychain-ownership'}[args.sabotage]]
    for scenario in cases:
        home = root / scenario
        home.mkdir(mode=0o700)
        helper = home / 'fake-helper'
        shutil.copy2(repo / 'Scripts/process-tests/fake-helper.py', helper)
        helper.chmod(0o700)
        (home / 'bin').mkdir()
        for cli in ['claude', 'codex']:
            shutil.copy2(helper, home / 'bin' / cli)
        profile = 'export PATH=' + shlex.quote(str(home / 'bin') + ':/usr/bin:/bin') + '\n'
        if scenario.endswith('inherited'):
            profile += '/usr/bin/python3 -c ' + shlex.quote('import os,time; p=os.fork(); time.sleep(3) if p==0 else None; os._exit(0)') + '\n'
        (home / '.zprofile').write_text(profile)
        env = dict(os.environ, ATOLL_PROCESS_ROOT=str(home), CFFIXED_USER_HOME=str(home),
                   CODEX_HOME=str(home / '.codex'), ZDOTDIR=str(home))
        if scenario.endswith('ownership'): env['ATOLL_PROCESS_NO_IDENTITY'] = '1'
        result = subprocess.run([str(binary), scenario], env=env, capture_output=True, text=True, timeout=10)
        log = result.stdout + result.stderr
        (args.output / (scenario + '.log')).write_text(log)
        if args.sabotage:
            expected = {'heartbeat': 'A10 MainActor heartbeat delayed',
                        'serialization': 'A10 helpers overlapped or duplicate spawned',
                        'coalescing': 'A10 last intent coalesced with old operation',
                        'barrier': 'A10 state reread before queued writer ended',
                        'fleet-ownership': 'A09 probe lost live child ownership',
                        'keychain-ownership': 'A09 probe lost live child ownership'}[args.sabotage]
            passed = result.returncode == 1 and expected in log
        else:
            passed = result.returncode == 0 and 'PASS ' + scenario in log
        report['scenarios'].append({'name': scenario, 'passed': passed, 'returncode': result.returncode})
        if not passed:
            (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
            raise SystemExit(log)
    report['passed'] = True
    report['sabotage'] = args.sabotage
    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS services: {len(cases)} scenario(s), sabotage={args.sabotage}')
