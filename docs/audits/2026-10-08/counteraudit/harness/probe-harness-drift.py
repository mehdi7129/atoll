#!/usr/bin/env python3
"""Contre-épreuve du faux CLI de test-codex-exec, aucun appel modèle."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('repo', type=Path)
args = parser.parse_args()
repo = args.repo.resolve()
original = (repo / 'Scripts/test-codex-exec.py').read_text()
root_line = 'repo = Path(__file__).resolve().parent.parent'
old_argv = "if sys.argv[1:] == ['app-server', '--listen', 'stdio://']:"
new_argv = "if sys.argv[1:] == ['-c', 'features.plugins=false', 'app-server', '--listen', 'stdio://']:"
assert original.count(root_line) == 1 and original.count(old_argv) == 1
failure = 'préparation réelle impossible avec le catalogue factice'
results = {}
with tempfile.TemporaryDirectory(prefix='atoll-harness-counteraudit-') as temporary:
    root = Path(temporary)
    for variant in ['original', 'fixture_argv_updated', 'original_noop']:
        source = original.replace(root_line, 'repo = Path(' + repr(str(repo)) + ')')
        if variant == 'fixture_argv_updated':
            source = source.replace(old_argv, new_argv)
        if variant == 'original_noop':
            assert source.count('copy.write_text(sabotaged)') == 1
            source = source.replace('copy.write_text(sabotaged)', 'copy.write_text(content)')
        script = root / (variant + '.py')
        script.write_text(source)
        for sabotage in ([True] if variant == 'original_noop' else [False, True]):
            command = ['python3', str(script), '--prepare-only']
            if sabotage:
                command.append('--sabotage-instructions-file')
            run = subprocess.run(command, capture_output=True, text=True, timeout=180)
            key = variant + ('_sabotage' if sabotage else '_nominal')
            results[key] = {
                'exit_code': run.returncode,
                'catalogue_preparation_failure_visible_in_stderr': failure in run.stderr,
                'reported_pass': [line for line in run.stdout.splitlines() if line.startswith('PASS')],
            }
    # On constate le défaut de garde, pas une correction du produit.
    assert results['original_nominal']['exit_code'] != 0
    assert results['original_nominal']['catalogue_preparation_failure_visible_in_stderr']
    assert results['original_sabotage']['exit_code'] == 0
    assert results['original_noop_sabotage']['exit_code'] == 0
    assert results['fixture_argv_updated_nominal']['exit_code'] == 0
    assert results['fixture_argv_updated_sabotage']['exit_code'] == 0
print(json.dumps(results, ensure_ascii=False, indent=2))
