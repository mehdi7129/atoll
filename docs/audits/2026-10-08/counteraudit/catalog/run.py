#!/usr/bin/env python3
"""Methods extracted unchanged; view storage and reads are controlled collaborators, not a GUI proof."""
from pathlib import Path
import argparse, subprocess, tempfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('repo', type=Path)
parser.add_argument('--build-dir', type=Path, help='Existing native AtollCore build directory')
args = parser.parse_args()
repo = args.repo.resolve()
source = Path(__file__).resolve().parent
build = args.build_dir.resolve() if args.build_dir else Path(subprocess.check_output(
    ['swift', 'build', '--build-system', 'native', '--package-path', str(repo / 'AtollCore'), '--show-bin-path'], text=True).strip())
assert (build / 'Modules/AtollCore.swiftmodule').exists(), 'Build AtollCore first (native)'
original = (repo / 'App/CodexCatalogSection.swift').read_text()
header = original[:original.index('    var body: some View {')].replace('import SwiftUI\n', '').replace('struct CodexCatalogSection: View {', '@MainActor struct CodexCatalogSection {').replace('@State ', '@ProbeState ')
methods = original[original.index('    private func matches('):]
# Toutes les méthodes sont inchangées ; seul le contrôle d'accès du harness
# permet au main situé dans le même fichier de les appeler/lire.
extracted = (header + methods).replace('private ', 'fileprivate ')
with tempfile.TemporaryDirectory(prefix='atoll-catalog-compile-') as temp:
    target = Path(temp) / 'Probe.swift'
    target.write_text((source / 'ProbeSupport.swift').read_text() + '\n' + extracted + '\n' + (source / 'ProbeMain.swift').read_text())
    binary = Path(temp) / 'probe'
    command = ['swiftc', '-swift-version', '5', '-parse-as-library', '-I', str(build / 'Modules'), '-lsqlite3', str(target)]
    command += [str(p) for p in sorted((build / 'AtollCore.build').glob('*.o'))]
    subprocess.run(command + ['-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
