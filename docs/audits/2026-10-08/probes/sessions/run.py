#!/usr/bin/env python3
"""Audit hors ligne: vraies classes Atoll, collaborateurs factices, aucun compte."""
from pathlib import Path
import subprocess,sys,tempfile,shutil
repo=Path(sys.argv[1]).resolve(); source=Path(__file__).resolve().parent
# --skip-build réutilise le Core déjà compilé, sans build concurrent.
if "--skip-build" not in sys.argv[2:]:
 subprocess.run(["swift","build","--build-system","native","--package-path",str(repo/"AtollCore")],check=True)
build=Path(subprocess.check_output(["swift","build","--build-system","native","--package-path",str(repo/"AtollCore"),"--show-bin-path"],text=True).strip())
with tempfile.TemporaryDirectory(prefix="atoll-sessions-audit-") as tmp:
 root=Path(tmp)
 fleet=root/"FleetPoller.swift"
 fleet.write_text((repo/"App/FleetPoller.swift").read_text()+"\nextension FleetPoller { static func auditRead(_ path: String) async -> Data? { await runAgentsJSON(claudePath: path) } }\n")
 fake=root/"fake-claude";shutil.copy2(source/"fake-claude",fake)
 cmd=["swiftc","-swift-version","5","-parse-as-library","-I",str(build/"Modules"),"-lsqlite3",str(repo/"App/InteractionCenter.swift"),str(fleet),str(source/"Stub.swift"),str(source/"Main.swift")]+[str(p) for p in sorted((build/"AtollCore.build").glob("*.o"))]+["-o",str(root/"audit")]
 subprocess.run(cmd,check=True)
 subprocess.run([str(root/"audit"),str(fake)],check=True,timeout=20)
