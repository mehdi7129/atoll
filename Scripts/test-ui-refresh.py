#!/usr/bin/env python3
"""A16/A20 : vraies vues montées, données privées et mutations UI compilées.

Les adaptations sont limitées aux sources jetables de la recette : garde
d'aperçu des vues, journal privé et lecteur catalogue déjà injectable. Aucun
fichier produit du dépôt ni configuration personnelle n'est modifié.
"""
import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--sabotage', action='store_true')
args = parser.parse_args()
args.output = args.output.resolve()
args.output.mkdir(parents=True, exist_ok=True)
source = args.output / 'source'
derived = args.output / 'DerivedData'
source.mkdir(exist_ok=True)
report = {'source_sha256': {}, 'cases': [], 'sabotages': [], 'passed': False}
lock = Path('/private/tmp/atoll-ui-test.lock').open('w')
fcntl.flock(lock.fileno(), fcntl.LOCK_EX)


def save():
    (args.output / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


def replace(text, needle, replacement, count=1):
    assert text.count(needle) == count, (needle, text.count(needle))
    return text.replace(needle, replacement)


files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=REPO).decode().split('\0')
for name in filter(None, files):
    original = REPO / name
    if original.is_file():
        destination = source / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, destination)

names = ['App/CodexPreview.swift', 'App/LearningSettingsPane.swift', 'App/CodexSettingsPane.swift',
         'App/CodexCatalogSection.swift', 'App/CodexCatalogState.swift', 'App/RetrospectiveRunner.swift']
originals = {name: (REPO / name).read_text() for name in names}
report['source_sha256'] = {name: hashlib.sha256((REPO / name).read_bytes()).hexdigest() for name in names}
report['adaptations'] = ['global preview preserved', 'private Foundation home and app preference domain asserted',
    'only view preview guards bypassed in temporary sources', 'actual journal persistence and delivery recovery',
    'catalogue resolver/reader injected through existing constructor',
    'home button keeps actual state assignment; service boundary selects only private home without starting services']


def adapt(mutation=None):
    texts = dict(originals)
    texts['App/CodexPreview.swift'] = replace(texts['App/CodexPreview.swift'],
        'let args = CommandLine.arguments\n        let requestedScreen',
        'UIRefreshFixture.prepare()\n        let args = CommandLine.arguments\n        let requestedScreen')
    texts['App/CodexPreview.swift'] = replace(texts['App/CodexPreview.swift'],
        'window.makeKeyAndOrderFront(nil)\n        NSApp.setActivationPolicy',
        'window.makeKeyAndOrderFront(nil)\n        UIRefreshFixture.start()\n        NSApp.setActivationPolicy')
    learning = texts['App/LearningSettingsPane.swift']
    learning = replace(learning, 'guard !CodexPreview.enabled else { return }', '', 1)
    learning = replace(learning, 'if !CodexPreview.enabled { attempts = runner.recentAttempts() }',
                       'attempts = runner.recentAttempts()')
    learning = replace(learning, 'if !CodexPreview.enabled { refreshNotes() }', 'refreshNotes()', 2)
    if mutation == 'journal':
        learning = replace(learning, '.onChange(of: runner.journalRevision) { _, _ in\n            attempts = runner.recentAttempts()',
                            '.onChange(of: runner.journalRevision) { _, _ in\n            if false { attempts = runner.recentAttempts() }')
    if mutation == 'notes':
        learning = replace(learning, '.onChange(of: runner.notesRevision) { _, _ in\n            refreshNotes()',
                            '.onChange(of: runner.notesRevision) { _, _ in\n            if false { refreshNotes() }')
    texts['App/LearningSettingsPane.swift'] = learning
    catalog = texts['App/CodexCatalogSection.swift']
    catalog = replace(catalog, '@State private var catalog = CodexCatalogState()', '@State private var catalog = UIRefreshFixture.catalog()')
    start = catalog.index('        guard !CodexPreview.enabled else {', catalog.index('    private func refresh()'))
    end = catalog.index('        catalog.refresh(context: context)', start)
    catalog = catalog[:start] + catalog[end:]
    texts['App/CodexCatalogSection.swift'] = catalog
    texts['App/CodexCatalogState.swift'] = replace(texts['App/CodexCatalogState.swift'],
        'guard let self else { return }\n            defer {',
        'guard let self else { return }\n            defer { UIRefreshFixture.catalogTaskEnded() }\n            defer {')
    pane = texts['App/CodexSettingsPane.swift']
    pane = replace(pane, 'CodexPreview.enabled ? "" : CodexPaths.configuredHome ?? ""', 'CodexPaths.configuredHome ?? ""')
    pane = replace(pane, 'CodexPreview.enabled ? URL(fileURLWithPath: "/compte-codex") : CodexPaths.homeURL', 'CodexPaths.homeURL')
    pane = replace(pane, 'TextField("CODEX_HOME", text: $homePath, prompt: Text("Détection automatique"))',
                   'TextField("CODEX_HOME", text: $homePath, prompt: Text("Détection automatique"))\n                            .accessibilityIdentifier("ui-fixture-home")')
    pane = replace(pane, '        .onAppear {',
                   '        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AtollUIFixtureHome"))) { note in\n            homePath = note.object as! String\n        }\n        .onAppear {')
    pane = replace(pane, 'Button("Appliquer le dossier Codex") {\n                            guard !CodexPreview.enabled else { return }',
                   'Button("Appliquer le dossier Codex") {')
    pane = replace(pane, 'try CodexService.shared.changeHome(to: path.isEmpty ? nil : (path as NSString).expandingTildeInPath)',
                   'try CodexPaths.selectHome(path.isEmpty ? nil : (path as NSString).expandingTildeInPath)')
    if mutation == 'home':
        pane = replace(pane, '                                catalogHome = CodexPaths.homeURL',
                       '                                // Mutant : home affiché au catalogue non actualisé.')
    texts['App/CodexSettingsPane.swift'] = pane
    texts['App/RetrospectiveRunner.swift'] += (REPO / 'Scripts/ui-refresh-tests/RunnerExtension.swift.inc').read_text()
    for name, text in texts.items(): (source / name).write_text(text)
    shutil.copy2(REPO / 'Scripts/ui-refresh-tests/Fixture.swift', source / 'App/UIRefreshFixture.swift')


adapt()
with (args.output / 'xcodegen.log').open('w') as log:
    subprocess.run(['xcodegen', 'generate'], cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True)
probe = args.output / 'probe'
subprocess.run(['swiftc', str(REPO / 'Scripts/ui-refresh-tests/Probe.swift'), '-o', str(probe)], check=True)


def build(mutation):
    adapt(mutation)
    label = mutation or 'nominal'
    with (args.output / (label + '-build.log')).open('w') as log:
        subprocess.run(['xcodebuild', '-project', 'Atoll.xcodeproj', '-scheme', 'Atoll', '-configuration', 'Debug',
                        '-derivedDataPath', str(derived), '-jobs', '2', 'CODE_SIGNING_ALLOWED=NO', 'build'],
                       cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1200)
    app = Path('/private/tmp') / ('Atoll-ui-refresh-' + str(os.getpid()) + '-' + label + '.app')
    subprocess.run(['python3', str(REPO / 'Scripts/prepare-preview.py'), str(derived / 'Build/Products/Debug/Atoll.app'), str(app)], check=True)
    return app


def run(app, case, mutation=None):
    label = (mutation or 'nominal') + '-' + case
    output = args.output / label
    attempt = 1
    while output.exists():
        attempt += 1
        output = args.output / (label + '-' + str(attempt))
    output.mkdir()
    root = output / 'fixture'
    for name in ['home', 'home-a', 'home-b']: (root / name).mkdir(parents=True)
    with (app / 'Contents/Info.plist').open('rb') as stream: info = plistlib.load(stream)
    assert info.get('AtollPreviewOnly') and info['CFBundleIdentifier'].startswith('dev.mehdiguiard.atoll.previewtest.')
    environment = dict(os.environ, ATOLL_UI_REFRESH_ROOT=str(root), CFFIXED_USER_HOME=str(root / 'home'),
                       CODEX_HOME=str(root / 'home-a'), ZDOTDIR=str(root / 'home'))
    for key in ['OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'ATOLL_LIVE_CODEX']: environment.pop(key, None)
    options = ['--preview-settings=learning'] if case == 'learning' else ['--preview-codex-settings', '--preview-advanced']
    with (output / 'app.log').open('w') as log:
        process = subprocess.Popen([str(app / 'Contents/MacOS/Atoll'), '--codex-preview', '--preview-quota-disabled', *options],
                                   env=environment, stdout=log, stderr=log)
        def invoke(mode, *arguments, check=True):
            return subprocess.run([str(probe), mode, str(process.pid), *map(str, arguments)], capture_output=True, text=True, check=check)
        def elements(): return json.loads(invoke('elements').stdout)
        def labels(): return '\n'.join(x['label'] for x in elements())
        def await_condition(condition, failure, seconds=8):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline and process.poll() is None:
                try:
                    if condition(): return
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                time.sleep(.1)
            raise AssertionError(failure)
        def status(): return json.loads((root / 'status.json').read_text())
        def command(action):
            identity = action + '-' + str(time.monotonic_ns())
            (root / 'command.json').write_text(json.dumps({'id': identity, 'action': action}))
            await_condition(lambda: status()['id'] == identity, 'Fixture command did not finish')
            assert not status()['error'], status()
        def snapshot(name, show=None):
            if show:
                command('scroll-bottom' if show == 'Journal des analyses' else 'scroll-top')
            time.sleep(.3)
            (output / (name + '-ax.json')).write_text(json.dumps(elements(), ensure_ascii=False, indent=2))
            windows = json.loads(invoke('window').stdout)
            window = max(windows, key=lambda item: item['kCGWindowBounds']['Width'])
            subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(window['kCGWindowNumber']), str(output / (name + '.png'))], check=True)
        def home(name):
            command(name)
            await_condition(lambda: any(x['role'] == 'AXTextField' and str(root / name) in x['label'] for x in elements()),
                            'Private home input not rendered')
            invoke('press', 'Appliquer le dossier Codex')
            await_condition(lambda: json.loads((root / 'home/.atoll/codex-home.json').read_text())['home'] == str(root / name), 'Private home not selected')
        try:
            await_condition(lambda: (root / 'status.json').exists() and bool(json.loads(invoke('window').stdout)), 'Protected window unavailable', 30)
            assert status()['home'] == str(root / 'home') and status()['codexHome'] == str(root / 'home-a')
            invoke('activate')
            time.sleep(1)
            if case == 'learning':
                invoke('press', 'Journal des analyses')
                invoke('press', 'Voir les notes')
                await_condition(lambda: 'NOTE INITIALE' in labels(), 'Initial note not rendered')
                assert any(x['role'] == 'AXButton' and 'Ranger maintenant' in x['label'] and x['enabled'] == '0' for x in elements())
                snapshot('avant-journal', 'Journal des analyses')
                command('success')
                await_condition(lambda: 'RECETTE SUCCESS' in labels(), 'A16 journal UI remained stale')
                for action in ['abstention', 'error']:
                    command(action)
                    await_condition(lambda: 'RECETTE ' + action.upper() in labels(), 'A16 journal UI remained stale')
                snapshot('apres-journal', 'Journal des analyses')
                command('recover')
                await_condition(lambda: 'Voir les notes (2)' in labels(), 'A16 notes UI remained stale')
                assert any(x['role'] == 'AXButton' and 'Ranger maintenant' in x['label'] and x['enabled'] == '1' for x in elements())
                assert status()['notesRevision'] > 0 and status()['journalRevision'] >= 4
                snapshot('apres-reprise', 'Voir les notes')
            else:
                invoke('press', 'Skills et plugins Codex')
                invoke('press', 'Lire le catalogue de ce projet')
                await_condition(lambda: 'CATALOGUE ALPHA' in labels(), 'Initial catalogue not rendered')
                snapshot('avant-home', 'Skills et plugins Codex')
                before = status()['reads']
                home('home-b')
                await_condition(lambda: 'CATALOGUE ALPHA' not in labels() and 'Catalogue à relire' in labels(), 'A20 home UI remained stale')
                assert status()['reads'] == before, 'Home change automatically read catalogue'
                snapshot('apres-home', 'Skills et plugins Codex')
                invoke('press', 'Lire le catalogue de ce projet')
                await_condition(lambda: 'CATALOGUE BETA' in labels(), 'New catalogue not rendered')
                home('home-a')
                command('delay')
                invoke('press', 'Lire le catalogue de ce projet')
                await_condition(lambda: status()['pendingRead'], 'Delayed reader did not start')
                home('home-b')
                completed = status()['completedReads']
                command('release')
                await_condition(lambda: status()['completedReads'] > completed, 'Delayed catalogue task did not finish')
                assert 'ALPHATARDIF' not in labels() and 'Catalogue à relire' in labels(), 'A20 old catalogue reappeared'
                snapshot('apres-reponse-tardive', 'Skills et plugins Codex')
            row = {'case': case, 'mutation': mutation, 'passed': True, 'status': status(), 'evidence': output.name}
            report['cases'].append(row)
            if mutation: raise AssertionError('Sabotage not detected')
        except AssertionError as error:
            snapshot('echec')
            expected = {'journal': 'A16 journal UI remained stale', 'notes': 'A16 notes UI remained stale',
                        'home': 'A20 home UI remained stale'}.get(mutation)
            if str(error) != expected: raise
            report['sabotages'].append({'mutation': mutation, 'detected': True, 'oracle': str(error), 'evidence': output.name})
        finally:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)
            for domain in [info['CFBundleIdentifier'], 'dev.mehdiguiard.atoll.preview.' + info['CFBundleIdentifier']]:
                subprocess.run(['/usr/bin/defaults', 'delete', domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment)
            save()


try:
    app = build(None)
    for case in ['learning', 'catalog']: run(app, case)
    if args.sabotage:
        run(build('journal'), 'learning', 'journal')
        run(build('notes'), 'learning', 'notes')
        run(build('home'), 'catalog', 'home')
    report['passed'] = True
    save()
    print('PASS UI refresh : deux vues montées, mutations=' + str(len(report['sabotages'])))
except Exception as error:
    report['error'] = str(error)
    save()
    raise
