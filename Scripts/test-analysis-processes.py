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
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
sources = ['App/' + file + '.swift' for file in
           ['RetrospectiveRunner', 'NotesCurationService', 'AnalysisExecution', 'CodexInteractionCenter', 'PluginInventory']]
report = {'source_sha256': {p: hashlib.sha256((repo / p).read_bytes()).hexdigest() for p in sources}, 'scenarios': []}
with tempfile.TemporaryDirectory(prefix='atoll-analysis-processes-') as temporary:
    root = Path(temporary)
    binary = root / 'analysis-processes'
    command = ['swiftc', '-swift-version', '5', '-D', 'DEBUG', '-parse-as-library',
        '-I', str(args.build_dir / 'Modules'), '-lsqlite3',
        *[str(repo / p) for p in sources], str(repo / 'Scripts/runtime-tests/Stubs.swift'),
        str(repo / 'Scripts/process-tests/AnalysisMain.swift'),
        *map(str, sorted((args.build_dir / 'AtollCore.build').glob('*.o'))), '-o', str(binary)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=300)
    (args.output / 'compile.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    for service in ['retrospective', 'curation']:
        for provider in ['claude', 'codex']:
            name = service + '-' + provider
            fixture = root / name
            fixture.mkdir(mode=0o700)
            env = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(fixture), ZDOTDIR=str(fixture),
                       CFFIXED_USER_HOME=str(fixture), CODEX_HOME=str(fixture / '.codex'))
            result = subprocess.run([str(binary), service, provider], env=env,
                                    capture_output=True, text=True, timeout=10)
            log = result.stdout + result.stderr
            (args.output / (name + '.log')).write_text(log)
            passed = result.returncode == 0 and 'PASS ' + service + '/' + provider in log
            report['scenarios'].append({'name': name, 'passed': passed, 'returncode': result.returncode})
            if not passed:
                (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
                raise SystemExit(log)
    report['passed'] = True
    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS 4 analysis process scenarios')
