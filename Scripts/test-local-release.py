#!/usr/bin/env python3
"""Éprouve le packaging local avec outils factices, sans build, clés ni publication."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
RELEASE = (ROOT / 'Scripts/release.sh').read_text()
VERIFIER = (ROOT / 'Scripts/verify-release.py').read_text()
FAKE = r'''#!/usr/bin/env python3
import json, os, plistlib, shutil, subprocess, sys, uuid
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps([name, *args])+'\n')
if name == 'codesign':
    if '--entitlements' in args and '-d' in args:
        values = {'com.apple.security.automation.apple-events': True} if os.environ.get('BAD_ENTITLEMENTS') and str(args[-1]).endswith('/MacOS/Atoll') else {}
        sys.stdout.buffer.write(plistlib.dumps(values))
    elif '-dvv' in args or '-dvvv' in args:
        print('Authority=Developer ID Application: Fixture\nTeamIdentifier=X524H8XA4L\nCodeDirectory v=20500 flags=0x10000(runtime)', file=sys.stderr)
elif name == 'lipo': print('arm64 x86_64' if not os.environ.get('BAD_ARCH') else 'arm64')
elif name == 'xcrun' and args[:2] == ['notarytool', 'submit']:
    print('id: 12345678-1234-1234-1234-123456789abc\nstatus: Accepted')
elif name == 'fixture-trash':
    target=Path(args[-1]); shutil.move(str(target), str(Path(os.environ['RECYCLE']) / uuid.uuid4().hex))
elif name == 'hdiutil' and args[0] == 'create':
    stage=Path(args[args.index('-srcfolder')+1]); subprocess.run(['/usr/bin/ditto','-c','-k','--keepParent',str(stage/'Atoll.app'),args[-1]],check=True)
elif name == 'hdiutil' and args[0] == 'attach':
    mount=Path(args[args.index('-mountpoint')+1]); subprocess.run(['/usr/bin/ditto','-xk',args[-1],str(mount)],check=True)
    if os.environ.get('BAD_DMG'): (mount/'Atoll.app/Contents/different').write_text('different')
    sys.stdout.buffer.write(plistlib.dumps({'system-entities':[{'mount-point':str(mount)}]}))
elif name == 'generate_appcast':
    (Path(args[-1])/'appcast.xml').write_text('appcast generated')
'''


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(command, env, success=True):
    result = subprocess.run([str(x) for x in command], env=env, capture_output=True, text=True, timeout=45)
    assert (result.returncode == 0) == success, (command, result.returncode, result.stdout, result.stderr)
    return result


with tempfile.TemporaryDirectory(prefix='atoll-local-release-') as temporary:
    base = Path(temporary)
    repo, dd, tools = base/'repo', base/'derived data', base/'tools'
    for directory in [repo/'Scripts', repo/'App', repo/'docs', repo/'dist/updates', tools, base/'recycle']:
        directory.mkdir(parents=True)
    (repo/'project.yml').write_text('MARKETING_VERSION: "0.19.0"\nCURRENT_PROJECT_VERSION: "43"\n')
    (repo/'Scripts/check-docs.py').write_text('raise SystemExit(0)\n')
    (repo/'docs/appcast.xml').write_text('public feed preserved')
    (repo/'dist/updates/old.zip').write_bytes(b'published archive')
    (repo/'dist/updates/appcast.xml').write_text('archived feed preserved')
    for name in ['codesign','lipo','xcrun','spctl','hdiutil','xcodegen','xcodebuild','fixture-trash']:
        (tools/name).write_text(FAKE); (tools/name).chmod(0o755)
    generator=dd/'SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast'
    generator.parent.mkdir(parents=True); generator.write_text(FAKE); generator.chmod(0o755)
    module = load(ROOT/'Scripts/verify-release.py', 'verify_release')
    app=dd/'Build/Products/Release/Atoll.app'
    for relative in module.MACHOS:
        binary=app/relative; binary.parent.mkdir(parents=True,exist_ok=True)
        binary.write_bytes(bytes.fromhex('cffaedfe')+b'fixture'); binary.chmod(0o755)
    info={'CFBundleIdentifier':'dev.mehdiguiard.atoll','CFBundleShortVersionString':'0.19.0','CFBundleVersion':'43',
          'SUPublicEDKey':'fixture public key','SUFeedURL':'https://mehdi7129.github.io/atoll/appcast.xml'}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    (repo/'App/Info.plist').write_bytes(plistlib.dumps(info))
    (repo/'App/Atoll.entitlements').write_bytes(plistlib.dumps({}))
    env=dict(os.environ, PATH=str(tools)+os.pathsep+os.environ['PATH'], CALLS=str(base/'calls.jsonl'),
             RECYCLE=str(base/'recycle'), ATOLL_RELEASE_DERIVED_DATA=str(dd))
    instrumented=RELEASE.replace('/usr/bin/trash --stopOnError "$1"','fixture-trash --stopOnError "$1"')
    assert instrumented != RELEASE, 'Instrumentation du nettoyage absente'
    script=repo/'Scripts/release.sh'; script.write_text(instrumented)
    protected={p:p.read_bytes() for p in [repo/'docs/appcast.xml',repo/'dist/updates/old.zip',repo/'dist/updates/appcast.xml']}

    def local_packaging_oracle():
        (base/'calls.jsonl').write_text('')
        run(['/bin/zsh',script,'--local'],env)
        assert all(p.read_bytes()==value for p,value in protected.items()), 'Publication locale modifiée'
        calls=[json.loads(x) for x in (base/'calls.jsonl').read_text().splitlines()]
        assert not any(x[0]=='generate_appcast' for x in calls), 'Appcast généré en mode local'
        assert not (repo/'dist/updates/Atoll-0.19.0.zip').exists(), 'ZIP copié dans updates'
        assert all((repo/'dist/0.19.0'/name).is_file() for name in ['Atoll-0.19.0.zip','Atoll-0.19.0.dmg','notary-app.log','notary-dmg.log'])
        assert len([x for x in calls if x[:3]==['xcrun','notarytool','submit']])==2, 'Deux notarisations requises'
        assert len([x for x in calls if x[:3]==['xcrun','stapler','staple']])==2, 'Deux staples requis'
    local_packaging_oracle()
    print('PASS packaging local : deux notarisations/staples, appcast et archives préservés')
    run(['/bin/zsh',script,'--unknown'],env,success=False)
    stop=re.search(r'^if \$LOCAL_ONLY; then\n.*?^fi\n',instrumented,re.M|re.S)
    assert stop, 'Sortie locale introuvable'
    script.write_text(instrumented[:stop.start()]+instrumented[stop.end():])
    try: local_packaging_oracle()
    except AssertionError: print('PASS sabotage : suppression de la sortie locale détectée')
    else: raise AssertionError('Sabotage sortie locale non détecté')
    script.write_text(instrumented)
    # Repartir de sentinelles intactes après le mutant exécuté uniquement ici.
    for p,value in protected.items(): p.write_bytes(value)
    copied=repo/'dist/updates/Atoll-0.19.0.zip'
    if copied.exists(): copied.unlink()
    local_packaging_oracle()
    script.write_text(instrumented.replace('if ! $LOCAL_ONLY; then cp "$ZIP" "$UPDATES/"; fi', 'cp "$ZIP" "$UPDATES/"'))
    try: local_packaging_oracle()
    except AssertionError as error:
        assert 'ZIP copié' in str(error), error
        print('PASS sabotage : copie intempestive du ZIP dans updates détectée')
    else: raise AssertionError('Sabotage copie ZIP non détecté')
    copied.unlink(); script.write_text(instrumented)
    moved=repo/'dist/saved-updates'; (repo/'dist/updates').rename(moved)
    run(['/bin/zsh',script,'--local'],env)
    assert not (repo/'dist/updates').exists(), 'Dossier updates créé en mode local'
    moved.rename(repo/'dist/updates')
    run(['/bin/zsh',script],env)
    assert copied.is_file() and (repo/'docs/appcast.xml').read_text()=='appcast generated', 'Mode public historique perdu'
    for p,value in protected.items(): p.write_bytes(value)
    copied.unlink()
    print('PASS compatibilité : le mode normal prépare toujours les archives et l’appcast')
    verifier=repo/'Scripts/verify-release.py'; verifier.write_text(VERIFIER)
    def verify(extra_env=None, success=True):
        result=run(['python3',verifier,'--repo',repo,'--local','--version','0.19.0','--build','43','--output',base/'proof'],
                   dict(env,**(extra_env or {})),success)
        report=max((base/'proof').glob('run-*/validation.json'),key=lambda p:p.stat().st_mtime_ns)
        return json.loads(report.read_text()),result
    report,_=verify()
    assert report['status']=='passed' and report['localOnly'] and report['temporaryArtifactsRemoved']
    assert len(report['executableComponents'])==7 and len(report['notEvaluated'])==4
    print('PASS vérification locale complète : sept binaires, identité, staples, Gatekeeper, DMG=ZIP')
    for variable,message in [('BAD_ENTITLEMENTS','Entitlements app'),('BAD_ARCH','non universel'),('BAD_DMG','DMG différente')]:
        report,_=verify({variable:'1'},success=False)
        assert message in report['error'] and report['temporaryArtifactsRemoved'],report
    print('PASS rejets : ancien entitlement Apple Events, architecture incomplète, contenu DMG différent')
    needle='require(values == {}, "Entitlements app inattendus : le bundle essentiel doit avoir un dictionnaire vide")'
    assert VERIFIER.count(needle)==1
    verifier.write_text(VERIFIER.replace(needle,'require(True, "neutralisé")'))
    report,_=verify({'BAD_ENTITLEMENTS':'1'})
    assert report['status']=='passed' and any(x['entitlements'] for x in report['executableComponents'])
    print('PASS sabotage : neutraliser le contrôle entitlements laisse passer le cas rejeté')
    verifier.write_text(VERIFIER)

    checker=load(ROOT/'Scripts/check-docs.py','check_docs')
    checker.ROOT=repo
    (repo/'README.md').write_text('Version préparée : **v0.19.0**, build 43. La dernière version publiée reste **v0.18.7, build 42**.\n')
    (repo/'CLAUDE.md').write_text('Version publiée : **v0.18.7**, build 42\nVersion préparée : **v0.19.0**, build 43\n')
    feed=repo/'docs/appcast.xml'; feed.write_text('<sparkle:shortVersionString>0.18.7</sparkle:shortVersionString>')
    checker.errors.clear(); checker.check_versions(); assert not checker.errors,checker.errors
    # Le contrôle nominal doit échouer si l'exception « préparée/publiée » disparaît.
    checker_source=(ROOT/'Scripts/check-docs.py').read_text()
    mutant=repo/'Scripts/check-docs-mutant.py'
    needle='and not preflight and not prepared_with_old_feed:'
    assert checker_source.count(needle)==1
    mutant.write_text(checker_source.replace(needle,'and not preflight:'))
    mutant_checker=load(mutant,'check_docs_mutant'); mutant_checker.ROOT=repo
    mutant_checker.check_versions()
    assert any('appcast' in x for x in mutant_checker.errors),mutant_checker.errors
    print('PASS sabotage : retrait de la distinction préparée/publiée détecté')
    feed.write_text('<sparkle:shortVersionString>0.18.6</sparkle:shortVersionString>')
    checker.errors.clear(); checker.check_versions(); assert any('appcast' in x for x in checker.errors),checker.errors
    feed.write_text('<sparkle:shortVersionString>0.18.7</sparkle:shortVersionString>')
    (repo/'CLAUDE.md').write_text('Version publiée : **v0.18.7**\nVersion préparée : **v0.18.9**\n')
    checker.errors.clear(); checker.check_versions(preflight=True); assert any('prépare' in x for x in checker.errors),checker.errors
    (repo/'CLAUDE.md').write_text('Version publiée : **v0.18.7**\nVersion préparée : **v0.19.0**, build 42\n')
    checker.errors.clear(); checker.check_versions(preflight=True); assert any('build 42' in x for x in checker.errors),checker.errors
    print('PASS versions : candidat déclaré accepté, ancien flux publié conservé, incohérences rejetées')
print('PASS sans build, signature réelle, notarisation, publication ou lancement app')
