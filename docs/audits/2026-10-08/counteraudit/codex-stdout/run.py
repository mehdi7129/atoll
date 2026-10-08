#!/usr/bin/env python3
"""CodexBridge réel, socket simulé. Aucune socket/configuration réelle touchée.
Le contrôle réutilise replyToStdout de Bridge/main.swift dans une copie temporaire.
"""
from pathlib import Path
import json, os, subprocess, sys, tempfile
repo=Path(sys.argv[1]).resolve(); source=Path(__file__).resolve().parent
build=Path(sys.argv[2]).resolve(); observations=[]
with tempfile.TemporaryDirectory(prefix="atoll-stdout-probe-") as temp:
    root=Path(temp)
    baseline=(repo/"Bridge/CodexBridge.swift").read_text()
    hook_main=(repo/"Bridge/main.swift").read_text()
    writer=hook_main[hook_main.index("@discardableResult\nfunc replyToStdout"):hook_main.index("/// Mode statusline :")]
    needle="FileHandle.standardOutput.write(json)"
    assert baseline.count(needle)==1
    for label,implementation in [("baseline",baseline),("existing-writer-control",baseline.replace(needle,"_ = replyToStdout(json)")+"\n"+writer)]:
        swift=root/(label+".swift"); swift.write_text(implementation)
        binary=root/(label+"-probe")
        command=["swiftc","-swift-version","5","-parse-as-library","-I",str(build/"Modules"),"-lsqlite3",str(swift),str(source/"CodexStdoutProbe.swift")]
        command += [str(p) for p in sorted((build/"AtollCore.build").glob("*.o"))]
        subprocess.run(command+["-o",str(binary)],check=True,timeout=90)
        env=dict(os.environ,CFFIXED_USER_HOME=str(root),CODEX_HOME=str(root/"codex"))
        env.pop("ATOLL_RETROSPECTIVE",None)
        payload=json.dumps({"hook_event_name":"PermissionRequest","session_id":"fixture","cwd":"/fixture","tool_name":"Bash","tool_input":{"command":"echo fixture"}}).encode()
        control=subprocess.run([str(binary)],input=payload,capture_output=True,env=env,timeout=5)
        observations.append({"implementation":label,"case":"reader-open","exit":control.returncode,"stdout":control.stdout.decode(),"stderr_empty":not control.stderr})
        read_fd,write_fd=os.pipe(); os.close(read_fd)
        try:
            process=subprocess.Popen([str(binary)],stdin=subprocess.PIPE,stdout=write_fd,stderr=subprocess.PIPE,env=env)
        finally:
            os.close(write_fd)
        _,error=process.communicate(payload,timeout=5)
        observations.append({"implementation":label,"case":"reader-closed","exit":process.returncode,"broken_pipe":b"Broken pipe" in error,"filehandle_exception":b"NSFileHandleOperationException" in error})
print(json.dumps(observations,indent=2))
assert [row["exit"] for row in observations]==[0,-6,0,0]
assert json.loads(observations[0]["stdout"])==json.loads(observations[2]["stdout"]), "JSON nominal inchangé"
assert json.loads(observations[0]["stdout"])["hookSpecificOutput"]["decision"]=={"behavior":"allow"}
assert observations[1]["broken_pipe"] and observations[1]["filehandle_exception"]
assert observations[0]["stderr_empty"] and observations[2]["stderr_empty"]
assert not observations[3]["broken_pipe"] and not observations[3]["filehandle_exception"]
