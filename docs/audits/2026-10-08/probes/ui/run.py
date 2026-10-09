#!/usr/bin/env python3
"""Trois probes UI hors GUI, sans son joué, configuration, auth ou CLI réel.

python3 run.py --repo /chemin/atoll --output /chemin/preuves-neuves
Les exécutables/fichiers produits restent dans output ; aucun nettoyage destructeur.
"""
import argparse
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo, output = args.repo.resolve(), args.output.resolve()
output.mkdir(parents=True, exist_ok=False)

def run(name, source, arguments=()):
    path = output / (name + '.swift')
    binary = output / name
    path.write_text(source)
    compiled = subprocess.run(['swiftc', str(path), '-o', str(binary)], capture_output=True, text=True)
    (output / (name + '-compile.log')).write_text(compiled.stdout + compiled.stderr)
    compiled.check_returncode()
    result = subprocess.run([str(binary), *map(str, arguments)], capture_output=True, text=True, timeout=15)
    (output / (name + '-result.txt')).write_text(result.stdout)
    (output / (name + '-stderr.txt')).write_text(result.stderr)
    result.check_returncode()
    return result.stdout

sound = run('sound', '''import AppKit
let first = NSSound(named: "Glass")
let second = NSSound(named: "Glass")
print("glass_available=\\(first != nil)")
print("same_instance=\\(first === second)")
if let first, let second {
    first.volume = 0.2
    second.volume = 0.8
    print("first_volume_after_second=\\(first.volume)")
}
''')

drain = (repo / 'AtollCore/Sources/AtollCore/BoundedProcessOutput.swift').read_text()
pipe = run('pipe', drain + '''
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
process.arguments = ["-c", "import os,time; pid=os.fork(); time.sleep(1.2) if pid==0 else None; os._exit(0)"]
let stdout = Pipe()
process.standardOutput = stdout
process.standardError = FileHandle.nullDevice
process.standardInput = FileHandle.nullDevice
let started = Date()
try process.run()
Thread.sleep(forTimeInterval: 0.2)
print("parent_running_at_deadline=\\(process.isRunning)")
let bytes = BoundedProcessOutput.drain(stdout.fileHandleForReading, cap: 4_194_304)
process.waitUntilExit()
print("elapsed_seconds=\\(Date().timeIntervalSince(started))")
print("output_bytes=\\(bytes.count)")
print("parent_exit=\\(process.terminationStatus)")
''')

source = (repo / 'App/TerminalJumpService.swift').read_text()
start = source.index('    private static func focusIDE(')
end = source.index('    private static func resolveIDECLI(', start)
focus = source[start:end].replace('private static func focusIDE', 'static func focusIDE', 1)
fake = output / 'fake-ide'
# Le cwd de la commande est donné par le vrai corps focusIDE (-r <root>).
fake.write_text('#!/bin/sh\nprintf exit42 > "$2/exited"\nexit 42\n')
fake.chmod(0o700)
jump = run('jump', '''import Foundation
struct TerminalKind { var displayName = "FixtureIDE" }
struct TerminalAnchor { var cwd: String?; var bundleID: String? }
enum WorkspaceRoot { static func resolve(cwd: String, gitExists: (String) -> Bool) -> String { cwd } }
enum Probe {
    enum Result { case focused(String, granularity: String); case failed(String) }
    static func resolveIDECLI(cli: String, bundleID: String?) -> String? { CommandLine.arguments[1] }
    @discardableResult static func activateBundle(_ bundleID: String?) -> Bool { print("activation_success=false"); return false }
''' + focus + '''}
let result = Probe.focusIDE(cli: "fixture", kind: TerminalKind(), anchor: TerminalAnchor(cwd: CommandLine.arguments[2], bundleID: "fixture"))
print("result=\\(result)")
Thread.sleep(forTimeInterval: 1.0)
print("fake_cli_exited=\\(FileManager.default.fileExists(atPath: CommandLine.arguments[2] + "/exited"))")
''', [fake, output])

observed = {
    'sound_shared_instance': 'glass_available=true' in sound and 'same_instance=true' in sound and 'first_volume_after_second=0.8' in sound,
    'pipe_waits_after_parent_exit': 'parent_running_at_deadline=false' in pipe and float(pipe.split('elapsed_seconds=')[1].splitlines()[0]) > 1.0,
    'jump_false_success': 'activation_success=false' in jump and 'result=focused(' in jump and (output / 'exited').read_text() == 'exit42',
}
(output / 'result.json').write_text(json.dumps(observed, indent=2) + '\n')
print(json.dumps(observed, indent=2))
if not all(observed.values()):
    raise SystemExit('Au moins un constat non reproduit dans cet environnement.')
