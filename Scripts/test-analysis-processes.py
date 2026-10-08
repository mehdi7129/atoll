#!/usr/bin/env python3
"""A09 : vrais services d’apprentissage, descendant privé gardant les deux pipes."""
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--build-dir', type=Path, required=True)
parser.add_argument('--sabotage', choices=['retrospective', 'curation'])
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
sources = ['App/' + file + '.swift' for file in
           ['RetrospectiveRunner', 'NotesCurationService', 'AnalysisExecution', 'CodexInteractionCenter', 'PluginInventory']]
report = {'source_sha256': {p: hashlib.sha256((repo / p).read_bytes()).hexdigest() for p in sources}, 'scenarios': []}
with tempfile.TemporaryDirectory(prefix='atoll-analysis-processes-') as temporary:
    root = Path(temporary)
    binary = root / 'analysis-processes'
    compiled = []
    for path in sources:
        if Path(path).stem in ['RetrospectiveRunner', 'NotesCurationService']:
            text = (repo / path).read_text()
            # Délais seulement accélérés : les classes, leur ownership et les
            # gardes de budget restent ceux du produit. Le stub ProcessInspector
            # retourne volontairement une identité invalide pour refuser le kill.
            text = text.replace('let timeoutSeconds: TimeInterval = 600', 'let timeoutSeconds: TimeInterval = 1')
            text = text.replace('terminationGrace: 5)', 'terminationGrace: 0.1)')
            target = {'retrospective': 'RetrospectiveRunner', 'curation': 'NotesCurationService'}.get(args.sabotage)
            if Path(path).stem == target:
                needle = 'if let process, process.isRunning {'
                assert text.count(needle) == 1
                text = text.replace(needle, 'if false, let process, process.isRunning {')
            copy = root / Path(path).name
            copy.write_text(text)
            compiled.append(str(copy))
        else:
            compiled.append(str(repo / path))
    command = ['swiftc', '-swift-version', '5', '-D', 'DEBUG', '-parse-as-library',
        '-I', str(args.build_dir / 'Modules'), '-lsqlite3',
        *compiled, str(repo / 'Scripts/runtime-tests/Stubs.swift'),
        str(repo / 'Scripts/process-tests/AnalysisMain.swift'),
        *map(str, sorted((args.build_dir / 'AtollCore.build').glob('*.o'))), '-o', str(binary)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=300)
    (args.output / 'compile.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    cases = [(service, provider, survivor) for service in ['retrospective', 'curation']
             for provider in ['claude', 'codex'] for survivor in [False, True]]
    if args.sabotage:
        cases = [(args.sabotage, 'claude', True)]
    for service, provider, survivor in cases:
            name = service + '-' + provider + ('-survivor' if survivor else '')
            fixture = root / name
            fixture.mkdir(mode=0o700)
            env = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(fixture), ZDOTDIR=str(fixture),
                       CFFIXED_USER_HOME=str(fixture), CODEX_HOME=str(fixture / '.codex'))
            result = subprocess.run([str(binary), service, provider] + (['survivor'] if survivor else []), env=env,
                                    capture_output=True, text=True, timeout=20)
            log = result.stdout + result.stderr
            (args.output / (name + '.log')).write_text(log)
            passed = result.returncode == 0 and 'PASS ' + service + '/' + provider in log
            if args.sabotage:
                passed = result.returncode == 1 and ('A09 live child lost analysis ownership' in log
                    or 'A09 second retrospective overlapped live child' in log)
            report['scenarios'].append({'name': name, 'passed': passed, 'returncode': result.returncode})
            if not passed:
                (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
                raise SystemExit(log)
    report['passed'] = True
    report['sabotage'] = args.sabotage
    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS {len(cases)} analysis process scenarios, sabotage={args.sabotage}')
