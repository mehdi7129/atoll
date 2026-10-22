#!/usr/bin/env python3
"""A21 passif : helper entier, stdout ouvert/fermé et sockets/homes privés.

Le helper ne produit plus de décision : l'ancien writer stdout et son test de
reprise EINTR/écritures partielles n'appartiennent plus au produit. On vérifie
l'absence de sortie et de lecture, même face à un ancien serveur décisionnel.
Les mutants réintroduisent la lecture et l'écriture stdout dangereuse ; ils
compilent d'abord, puis doivent échouer sur un oracle exécuté.
"""
import argparse
import hashlib
import json
import os
import socket
import subprocess
import tempfile
import threading
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--build-dir', type=Path, required=True)
parser.add_argument('--sabotage', action='store_true')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
objects = sorted((args.build_dir / 'AtollCore.build').glob('*.o'))
assert objects, 'Objets Core compilés absents'
report = {'scenarios': [], 'sabotages': [], 'source_sha256': {p: hashlib.sha256((repo/p).read_bytes()).hexdigest()
    for p in ['Bridge/main.swift', 'Bridge/CodexBridge.swift', 'Shared/ProcessInspector.swift']}}

with tempfile.TemporaryDirectory(prefix='atoll-stdout-', dir='/private/tmp') as temporary:
    root = Path(temporary)

    def compile_helper(name, mutation=None):
        text = (repo / 'Bridge/main.swift').read_text()
        # Le vrai dispatcher passe seulement une adresse privée à la fonction
        # produit. Aucun socket Atoll normal ni configuration personnelle.
        needle = '    CodexBridge.forward()'
        assert text.count(needle) == 1
        text = text.replace(needle, '    CodexBridge.forward(socketPath: ProcessInfo.processInfo.environment["ATOLL_TEST_SOCKET"]!)')
        if mutation:
            needle = '    shutdown(fd, SHUT_WR)'
            assert text.count(needle) == 1
            extra = '\n    var reply = [UInt8](repeating: 0, count: 4096)\n    let received = read(fd, &reply, reply.count)\n'
            if mutation == 'unsafe-stdout':
                extra += '    if received > 0 { FileHandle.standardOutput.write(Data(reply.prefix(received))) }\n'
            else:
                extra += '    _ = received\n'
            text = text.replace(needle, needle + extra)
        folder = root / name
        folder.mkdir()
        source = folder / 'main.swift'
        source.write_text(text)
        helper = folder / 'atoll-bridge'
        command = ['swiftc', '-swift-version', '5', '-I', str(args.build_dir/'Modules'), '-lsqlite3',
                   '-import-objc-header', str(repo/'Shared/BridgingHeader.h'), str(source),
                   str(repo/'Shared/ProcessInspector.swift'), str(repo/'Bridge/CodexBridge.swift'),
                   *map(str, objects), '-o', str(helper)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        (args.output/(name+'-compile.log')).write_text(result.stdout + result.stderr)
        assert result.returncode == 0, result.stderr
        return helper

    def exercise(helper, closed=False, silent=False):
        name = helper.parent.name + ('-closed' if closed else '-open') + ('-silent' if silent else '-reply')
        home = root / name
        home.mkdir(mode=0o700)
        path = home / 's'
        env = dict(os.environ, CFFIXED_USER_HOME=str(home), CODEX_HOME=str(home/'.codex'), ATOLL_TEST_SOCKET=str(path))
        env.pop('ATOLL_RETROSPECTIVE', None)
        state = subprocess.run([str(helper), 'status'], env=env, capture_output=True, text=True, timeout=10)
        assert state.returncode == 0
        assert Path(json.loads(state.stdout)['memoryIndexPath']).resolve() == (home/'.atoll/memory.db').resolve()
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(path)); listener.listen(1); listener.settimeout(4)
        received, failures, delivery = [], [], []
        done = threading.Event()

        def answer():
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(4)
                    chunks = []
                    while data := connection.recv(65536):
                        chunks.append(data)
                    envelope = json.loads(b''.join(chunks))
                    assert envelope['payload']['hook_event_name'] == 'PermissionRequest'
                    assert envelope['payload']['session_id'] == 'fixture'
                    received.append(envelope)
                    if not silent:
                        try:
                            connection.sendall(b'{"behavior":"allow"}')
                            delivery.append('sent')
                        except (BrokenPipeError, ConnectionResetError):
                            # Le helper passif a le droit de sortir avant ce vieux
                            # serveur : l'enveloppe reçue est la preuve du transport.
                            delivery.append('client-already-closed')
                    done.wait(4)
            except Exception as error:
                failures.append(repr(error))
            finally:
                listener.close()
        thread = threading.Thread(target=answer, daemon=True)
        thread.start()
        payload = json.dumps({'hook_event_name':'PermissionRequest', 'session_id':'fixture', 'cwd':'/fixture',
                              'tool_name':'Bash', 'tool_input':{'command':'true'}}).encode()
        if closed:
            reader, writer = os.pipe(); os.close(reader)
            process = subprocess.Popen([str(helper), 'codex-hook'], env=env, stdin=subprocess.PIPE, stdout=writer, stderr=subprocess.PIPE)
            os.close(writer)
        else:
            process = subprocess.Popen([str(helper), 'codex-hook'], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        timed_out = False
        try:
            stdout, stderr = process.communicate(payload, timeout=2)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
            stdout, stderr = process.communicate(timeout=2)
        finally:
            done.set(); thread.join(timeout=5)
        assert len(received) == 1 and not failures and not thread.is_alive(), 'transport-not-exercised: ' + repr(failures)
        (args.output/(name+'.stderr.log')).write_bytes(stderr)
        (args.output/(name+'.stdout.log')).write_bytes(stdout or b'')
        return {'closed_stdout': closed, 'silent_server': silent, 'returncode': process.returncode,
                'timed_out': timed_out, 'stdout_empty': not stdout, 'stderr_empty': not stderr,
                'reply_delivery': delivery}, stderr

    helper = compile_helper('nominal')
    for closed, silent in [(False, False), (True, False), (False, True), (True, True)]:
        scenario, stderr = exercise(helper, closed=closed, silent=silent)
        passed = (not scenario['timed_out'] and scenario['returncode'] == 0 and
                  scenario['stdout_empty'] and scenario['stderr_empty'])
        scenario['passed'] = passed
        report['scenarios'].append(scenario)
        assert passed, 'passive-stdout-or-read-regression: ' + repr(scenario) + stderr.decode(errors='replace')

    if args.sabotage:
        mutant = compile_helper('mutant-read', 'read-reply')
        scenario, _ = exercise(mutant, silent=True)
        assert scenario['timed_out'], 'mutant-read-not-detected'
        report['sabotages'].append({'name':'read-reply', 'compiled':True, 'detected':'helper-waited-for-reply'})
        mutant = compile_helper('mutant-stdout', 'unsafe-stdout')
        scenario, _ = exercise(mutant)
        assert scenario['returncode'] == 0 and not scenario['stdout_empty'], 'mutant-output-not-detected'
        report['sabotages'].append({'name':'unsafe-stdout-open', 'compiled':True, 'detected':'stdout-not-empty'})
        scenario, stderr = exercise(mutant, closed=True)
        assert scenario['returncode'] != 0 and b'NSFileHandleOperationException' in stderr and b'Broken pipe' in stderr, 'mutant-closed-output-not-detected'
        report['sabotages'].append({'name':'unsafe-stdout-closed', 'compiled':True, 'detected':'NSFileHandleOperationException/Broken pipe'})

    report['passed'] = True
    (args.output/'results.json').write_text(json.dumps(report, indent=2)+'\n')
    print('PASS A21 passive opened/closed stdout, no reply read; sabotage='+str(args.sabotage))
