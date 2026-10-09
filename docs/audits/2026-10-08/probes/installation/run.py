#!/usr/bin/env python3
"""Pure AtollCore fixtures. No personal settings or external CLI."""
from pathlib import Path
import subprocess,sys,tempfile
repo=Path(sys.argv[1]).resolve(); source=Path(__file__).resolve().parent
# --skip-build réutilise le Core déjà compilé, sans build concurrent.
if "--skip-build" not in sys.argv[2:]:
 subprocess.run(["swift","build","--build-system","native","--package-path",str(repo/"AtollCore")],check=True)
build=Path(subprocess.check_output(["swift","build","--build-system","native","--package-path",str(repo/"AtollCore"),"--show-bin-path"],text=True).strip())
with tempfile.TemporaryDirectory(prefix="atoll-install-audit-") as tmp:
 binary=Path(tmp)/"probe"
 cmd=["swiftc","-swift-version","5","-parse-as-library","-I",str(build/"Modules"),"-lsqlite3",str(source/"Probe.swift")]+[str(p) for p in sorted((build/"AtollCore.build").glob("*.o"))]+["-o",str(binary)]
 subprocess.run(cmd,check=True)
 subprocess.run([str(binary)],check=True,timeout=15)
