#!/usr/bin/python3
import os
import sys
import time
from pathlib import Path
root = Path(os.environ['ATOLL_PROCESS_ROOT'])
verb = sys.argv[1]
if os.environ.get('ATOLL_PROCESS_NO_IDENTITY') == '1':
    with (root / 'probe-launches').open('a') as out:
        out.write('spawn\n')
    deadline = time.monotonic() + 10
    while not (root / 'probe-release').exists() and time.monotonic() < deadline:
        time.sleep(.01)
    if verb == 'agents':
        print('[]')
    else:
        print('{"claudeAiOauth":{"accessToken":"fixture-token"}}')
    sys.exit(0)
if verb == 'agents':
    if os.fork() == 0:
        time.sleep(1.5)
    os._exit(0)
if verb == 'find-generic-password':
    print('{"claudeAiOauth":{"accessToken":"fixture-token"}}')
    sys.exit(0)
if verb == 'slow':
    time.sleep(.4)
elif verb == 'large-stderr':
    os.write(2, b'e' * 2000000)
elif verb == 'failure':
    sys.stderr.write('fixture-error')
    sys.exit(7)
elif verb == 'timeout':
    (root / '.claude').mkdir(exist_ok=True)
    (root / '.claude' / 'settings.json').write_bytes((root / 'installed-fixture.json').read_bytes())
    (root / 'partial-state').write_text('written')
    time.sleep(10)
else:
    with (root / 'order').open('a') as out:
        out.write(verb + '-start\n')
    time.sleep(.15)
    with (root / 'order').open('a') as out:
        out.write(verb + '-end\n')
