#!/usr/bin/env python3
"""Vraies classes SoundCenter/TerminalJumpService, CLI factices et sons non joués."""
import argparse, hashlib, json, os, subprocess, tempfile
from pathlib import Path
REPO = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--build-dir', type=Path)
p.add_argument('--output', required=True, type=Path)
p.add_argument('--sabotage', action='store_true')
a = p.parse_args(); a.output.mkdir(parents=True, exist_ok=True)

def run(args, name, **kw):
    r = subprocess.run(list(map(str,args)), text=True, capture_output=True, timeout=180, **kw)
    (a.output/(name+'.log')).write_text(r.stdout+r.stderr)
    return r

if not a.build_dir:
    base = ['swift','build','--package-path',REPO/'AtollCore','--build-system','native','--jobs','4']
    r = run(base, 'core'); assert r.returncode == 0, r.stderr
    a.build_dir = Path(subprocess.check_output(list(map(str,base+['--show-bin-path'])),text=True).strip())
summary = {'scenarios': [], 'sabotages': [], 'sources': {}}
for f in ['App/SoundCenter.swift','App/TerminalJumpService.swift','Scripts/feedback-tests/Main.swift']:
    summary['sources'][f] = hashlib.sha256((REPO/f).read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='atoll-feedback-') as tmp:
    root = Path(tmp)
    mutations = [(None,None,None,None)]
    if a.sabotage:
        mutations += [('sound','loaded = NSSound(named: name)?.copy() as? NSSound','loaded = NSSound(named: name)','A15 instances partagées'),
                      ('jump','if result?.succeeded == true, activate(anchor.bundleID) {','if result?.succeeded != nil {','A17 succès ou granularité inventé'),
                      ('await','let result = try? await BoundedProcessRunner.run(process, timeout: timeout)','try? process.run()\n            let result: BoundedProcessRunner.Result? = nil','A17 fin CLI non attendue'),
                      ('order','await previous?.value','_ = previous','A17 ordre des jumps perdu')]
    for name, needle, replacement, expected in mutations:
        case = name or 'nominal'; folder = root/case; folder.mkdir()
        sound = (REPO/'App/SoundCenter.swift').read_text()
        jump = (REPO/'App/TerminalJumpService.swift').read_text()
        if name:
            text = sound if name == 'sound' else jump
            assert text.count(needle) == 1, 'Couture ambiguë '+case
            text = text.replace(needle,replacement)
            if name == 'sound': sound = text
            else: jump = text
        # Le vrai point d'entrée jump, son ordonnancement et perform sont conservés.
        # Seuls la résolution du CLI et le focus système sont des collaborateurs privés.
        focus = 'return await focusIDE(cli: cli, kind: kind, anchor: anchor)'
        assert jump.count(focus) == 1, 'Couture de fixture ambiguë'
        jump = jump.replace(focus, '''return await focusIDE(cli: cli, kind: kind, anchor: anchor,
                resolveCLI: { _, _ in FeedbackJumpFixture.shared.cli },
                activate: { FeedbackJumpFixture.shared.activate($0) }, timeout: 3)''')
        sound += '\nextension SoundCenter { func fixtureSound(_ choice: SoundChoice, _ event: SoundEvent) -> NSSound? { sound(for: choice, event: event) } }\n'
        (folder/'SoundCenter.swift').write_text(sound)
        (folder/'TerminalJumpService.swift').write_text(jump)
        # Seul le verrou du helper (autre lot) est stubé ; aucun geste de parking n'est appelé.
        (folder/'Stubs.swift').write_text('enum HookInstaller { static func requireNoActiveHelper() throws {} }\n')
        binary = folder/'fixture'
        cmd = ['swiftc','-swift-version','5','-parse-as-library','-I',a.build_dir/'Modules','-lsqlite3',
               folder/'SoundCenter.swift',folder/'TerminalJumpService.swift',folder/'Stubs.swift',REPO/'App/AutomationPermission.swift',
               REPO/'Scripts/feedback-tests/Main.swift',*sorted((a.build_dir/'AtollCore.build').glob('*.o')),'-o',binary]
        r = run(cmd,case+'-build'); assert r.returncode == 0, r.stderr
        home = folder/'home'; home.mkdir()
        env = dict(os.environ,CFFIXED_USER_HOME=str(home),CODEX_HOME=str(home/'.codex'))
        r = run([binary],case,env=env)
        if expected:
            assert r.returncode != 0 and expected in r.stderr, 'Sabotage non causal '+case+': '+r.stdout+r.stderr
            summary['sabotages'].append(case)
        else:
            assert r.returncode == 0, r.stdout+r.stderr
            summary['scenarios'] = r.stdout.splitlines()
        print('PASS',case,flush=True)
(a.output/'results.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False))
