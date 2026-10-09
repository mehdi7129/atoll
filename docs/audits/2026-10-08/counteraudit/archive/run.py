#!/usr/bin/env python3
"""Actual AtollCore archiveInstalled, isolated fixtures; reuses an existing native build."""
from pathlib import Path
import argparse, subprocess, tempfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('repo', type=Path)
parser.add_argument('--build-dir', type=Path, help='Existing native AtollCore build directory')
args = parser.parse_args()
repo = args.repo.resolve()
build = args.build_dir.resolve() if args.build_dir else Path(subprocess.check_output(
    ['swift', 'build', '--build-system', 'native', '--package-path', str(repo / 'AtollCore'), '--show-bin-path'], text=True).strip())
assert (build / 'Modules/AtollCore.swiftmodule').exists(), 'Build AtollCore first (native)'
source = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='atoll-archive-compile-') as temp:
    binary = Path(temp) / 'probe'
    command = ['swiftc', '-swift-version', '5', '-parse-as-library', '-I', str(build / 'Modules'), '-lsqlite3', str(source / 'Probe.swift')]
    command += [str(p) for p in sorted((build / 'AtollCore.build').glob('*.o'))]
    subprocess.run(command + ['-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
