#!/usr/bin/env python3
"""A09/A11 : baseline réelle puis mutants compilés dans un package privé minimal."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
repo=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
args.output.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='atoll-process-mutants-') as temporary:
    package=Path(temporary)/'AtollCore'
    inputs=['Package.swift','Sources/AtollCore/BoundedProcessRunner.swift','Sources/AtollCore/ProcessIdentity.swift',
            'Tests/AtollCoreTests/BoundedProcessRunnerTests.swift']
    for relative in inputs:
        target=package/relative
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(repo/'AtollCore'/relative,target)
    report={'source_sha256':{p:hashlib.sha256((package/p).read_bytes()).hexdigest() for p in inputs},'mutations':[]}
    def run(name,selected):
        result=subprocess.run(['swift','test','--package-path',str(package),'--build-system','native','--jobs','4','--filter',selected],
            capture_output=True,text=True,timeout=90)
        log=result.stdout+result.stderr
        (args.output/(name+'.log')).write_text(log)
        return result.returncode,log
    code,log=run('baseline','BoundedProcessRunnerTests')
    assert code==0 and 'Executed 6 tests, with 0 failures' in log,log[-4000:]
    report['baseline_tests']=6
    originals={p:(package/p).read_text() for p in inputs if p.endswith('.swift')}
    mutations=[
        ('inherited-eof','Sources/AtollCore/BoundedProcessRunner.swift',
         'exitedAt.advanced(by: .milliseconds(200))','exitedAt.advanced(by: .seconds(20))',
         'testParentExitCannotLeaveDrainWaitingOnSilentDescendant','A09 inherited pipe exceeded post-exit bound'),
        ('unbounded-output','Sources/AtollCore/BoundedProcessRunner.swift',
         'buffer.prefix(min(count, max(0, cap - collected[index].count)))','buffer.prefix(count)',
         'testParallelLargeStreamsAreDrainedWithStrictCaps','XCTAssertEqual failed'),
        ('recycled-pid','Sources/AtollCore/ProcessIdentity.swift',
         'guard read(pid) == self else { return false }','guard true else { return false }',
         'testEachSignalRechecksIdentityIncludingEscalation','A11 recycled PID signalled'),
    ]
    for name,file,needle,replacement,test,assertion in mutations:
        for path,original in originals.items():(package/path).write_text(original)
        text=originals[file]
        assert text.count(needle)==1
        (package/file).write_text(text.replace(needle,replacement))
        code,log=run(name,'BoundedProcessRunnerTests/'+test)
        passed=(code!=0 and 'Build complete!' in log and assertion in log
                and re.search(r'Executed 1 test, with [1-9][0-9]* failures?',log) is not None)
        report['mutations'].append({'name':name,'test':test,'compiled_and_detected':passed})
        report['passed']=len(report['mutations'])==len(mutations) and all(x['compiled_and_detected'] for x in report['mutations'])
        (args.output/'results.json').write_text(json.dumps(report,indent=2)+'\n')
        assert passed,log[-4000:]
    print('PASS A09/A11 baseline6, 3 compiled causal mutants')
