#!/usr/bin/env python3
"""A21 : helper entier compilé, socket/homes privés, lecteur stdout ouvert/fermé."""
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
assert objects
report = {'scenarios': [], 'source_sha256': {p: hashlib.sha256((repo/p).read_bytes()).hexdigest()
    for p in ['Bridge/main.swift', 'Bridge/CodexBridge.swift', 'Shared/ProcessInspector.swift']}}
with tempfile.TemporaryDirectory(prefix='atoll-stdout-') as temporary:
    root = Path(temporary)
    # Même classe complète, seule l'adresse du socket est injectable pour la recette.
    paths = (repo / 'AtollCore/Sources/AtollCore/CodexPaths.swift').read_text()
    needle = '"/tmp/atoll-codex-\\(getuid()).sock"'
    assert paths.count(needle) == 1
    local_paths = root / 'CodexPaths.swift'
    local_paths.write_text('import AtollCore\n' + paths.replace(needle, 'ProcessInfo.processInfo.environment["ATOLL_TEST_SOCKET"]!'))
    bridge = repo / 'Bridge/CodexBridge.swift'
    if args.sabotage:
        original = bridge.read_text()
        assert original.count('_ = replyToStdout(json)') == 1
        bridge = root / 'CodexBridge.swift'
        bridge.write_text(original.replace('_ = replyToStdout(json)', 'FileHandle.standardOutput.write(json)'))
    sources = [repo / 'Bridge/main.swift', repo / 'Shared/ProcessInspector.swift', bridge, local_paths]
    sources += sorted(p for p in (repo/'Bridge').glob('*.swift') if p.name not in ['main.swift','CodexBridge.swift'])
    helper = root / 'atoll-bridge'
    command = ['swiftc', '-swift-version', '5', '-I', str(args.build_dir/'Modules'), '-lsqlite3',
               '-import-objc-header', str(repo/'Shared/BridgingHeader.h'), *map(str,sources), *map(str,objects), '-o', str(helper)]
    compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
    (args.output/'compile.log').write_text(compiled.stdout + compiled.stderr)
    if compiled.returncode: raise SystemExit(compiled.stderr)
    for closed in [False, True]:
        home = root / ('closed' if closed else 'open')
        home.mkdir(mode=0o700)
        socket_path = root / ('c.sock' if closed else 'o.sock')
        env = dict(os.environ, CFFIXED_USER_HOME=str(home), CODEX_HOME=str(home/'.codex'), ATOLL_TEST_SOCKET=str(socket_path))
        env.pop('ATOLL_RETROSPECTIVE', None)
        state = subprocess.run([str(helper),'status'], env=env, capture_output=True, text=True, timeout=10)
        assert state.returncode == 0
        state = json.loads(state.stdout)
        assert Path(state['memoryIndexPath']).resolve() == (home/'.atoll/memory.db').resolve()
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(socket_path))
        server.listen(1)
        server.settimeout(5)
        replies = []
        def answer():
            try:
                conn,_ = server.accept()
                with conn:
                    conn.settimeout(5)
                    chunks=[]
                    while data := conn.recv(65536): chunks.append(data)
                    envelope = json.loads(b''.join(chunks))
                    assert envelope['payload']['hook_event_name'] == 'PermissionRequest'
                    conn.sendall(b'{"behavior":"allow"}')
                    replies.append(True)
            finally:
                server.close()
        thread = threading.Thread(target=answer)
        thread.start()
        payload = json.dumps({'hook_event_name':'PermissionRequest','session_id':'fixture','cwd':'/fixture',
                              'tool_name':'Bash','tool_input':{'command':'true'}}).encode()
        if closed:
            reader,writer=os.pipe()
            os.close(reader)
            process=subprocess.Popen([str(helper),'codex-hook'], env=env, stdin=subprocess.PIPE, stdout=writer, stderr=subprocess.PIPE)
            os.close(writer)
            stdout,stderr=process.communicate(payload,timeout=10)
        else:
            process=subprocess.Popen([str(helper),'codex-hook'], env=env, stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            stdout,stderr=process.communicate(payload,timeout=10)
        thread.join(timeout=6)
        assert replies == [True] and not thread.is_alive(), 'Transport factice non exercé'
        (args.output/('closed.log' if closed else 'open.log')).write_bytes(stderr)
        if closed and args.sabotage:
            passed=process.returncode != 0 and b'NSFileHandleOperationException' in stderr and b'Broken pipe' in stderr
        elif closed:
            passed=process.returncode == 0 and stderr == b''
        else:
            expected={'hookSpecificOutput':{'hookEventName':'PermissionRequest','decision':{'behavior':'allow'}}}
            passed=process.returncode == 0 and json.loads(stdout) == expected and stderr == b''
        report['scenarios'].append({'closed_stdout':closed,'returncode':process.returncode,'passed':passed})
        assert passed, stderr.decode(errors='replace')
    # Le writer existant est compilé verbatim ; seule l'API POSIX write est
    # substituée pour imposer EINTR puis plusieurs écritures partielles.
    main=(repo/'Bridge/main.swift').read_text()
    start=main.index('@discardableResult\nfunc replyToStdout(')
    end=main.index('\n/// Mode statusline',start)
    writer_source=root/'Writer.swift'
    writer_source.write_text('''import Foundation
import Darwin
var calls = 0
var collected = Data()
func write(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
    calls += 1
    if calls == 1 { errno = EINTR; return -1 }
    let length = min(2, count)
    collected.append(pointer.assumingMemoryBound(to: UInt8.self), count: length)
    return length
}
''' + main[start:end] + '''
let expected = Data("fixture decision json".utf8)
guard replyToStdout(expected), collected == expected, calls > 3 else { exit(1) }
print("PASS partial writes and EINTR")
''')
    writer=root/'writer'
    subprocess.run(['swiftc',str(writer_source),'-o',str(writer)],check=True,capture_output=True,timeout=60)
    result=subprocess.run([str(writer)],capture_output=True,text=True,timeout=5)
    assert result.returncode == 0 and 'PASS partial writes and EINTR' in result.stdout
    report['partial_write_and_eintr']=True
    report['sabotage']=args.sabotage
    report['passed']=True
    (args.output/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS A21 opened/closed stdout, partial write/EINTR, sabotage='+str(args.sabotage))
