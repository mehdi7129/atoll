#!/usr/bin/env python3
"""Cadence et empreinte de curation : service réel, faux CLI, racines temporaires."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sabotage", choices=["cancellation", "unchanged", "post-write", "archive-uniqueness"])
parser.add_argument("--output", type=Path)
parser.add_argument("--build-system", choices=["native", "swiftbuild"],
                    help="Réutiliser le moteur de la recette Core, si déjà compilée.")
args = parser.parse_args()
work = Path(tempfile.mkdtemp(prefix="atoll-curation-regression-"))
print(f"Fixtures et compilation : {work}", flush=True)
build_command = ["swift", "build", "--package-path", str(REPO / "AtollCore")]
if args.build_system:
    build_command += ["--build-system", args.build_system]
subprocess.run(build_command, check=True)
build = Path(subprocess.check_output(build_command + ["--show-bin-path"], text=True).strip())
objects = sorted((build / "AtollCore.build").glob("*.o"))
module_path = build / "Modules"
if not objects or not module_path.is_dir():
    # Swift 6.3+ emploie SwiftBuild par défaut ; garder le harness compatible
    # avec ses produits et avec ceux du moteur SwiftPM précédent.
    build = next(path for path in [build, REPO / "AtollCore/.build/out/Products/Debug"]
                 if (path / "libAtollCore.a").is_file())
    module_path = build
    objects = [build / "libAtollCore.a"]

# Contrat de branchement : on extrait l'appel effectif des deux méthodes réelles,
# puis on exerce cette expression sur le vrai service. Pas de fenêtre ni d'app.
routes = []
for name, path, method, expected in [
    ("shutdown", "App/AppDelegate.swift", "applicationWillTerminate", "cancel"),
    ("changeHome", "App/CodexService.swift", "changeHome", "cancelIfCodex"),
]:
    text = (REPO / path).read_text()
    method_body = text.split("func " + method + "(", 1)[1].split("\n    func ", 1)[0]
    calls = re.findall(r"NotesCurationService\.shared\.([A-Za-z]+)\(\)", method_body)
    if calls != [expected]:
        raise SystemExit(f"Branchement curation modifié dans {path}:{method} : {calls}")
    routes.append(f"static func {name}() {{ NotesCurationService.shared.{calls[0]}() }}")
caller = work / "CallerRoutes.swift"
caller.write_text("@MainActor enum CurationCallerRoutes {\n" + "\n".join(routes) + "\n}\n")

service = REPO / "App/NotesCurationService.swift"
expected_failure = None
if args.sabotage:
    needle, replacement, expected_failure = {
        "cancellation": ('recordOutcome("analyse annulée", touched: false)', "",
                         "annulation non persistée avant retour CLI"),
        "unchanged": ("if !manual, lastSuccessfulCorpus == CurationCorpusFingerprint(notes: notes)",
                      "if false, lastSuccessfulCorpus == CurationCorpusFingerprint(notes: notes)",
                      "corpus inchangé a lancé un CLI"),
        "post-write": ("lastSuccessfulCorpus = CurationCorpusFingerprint(notes: Self.readNotes())",
                       "lastSuccessfulCorpus = CurationCorpusFingerprint(notes: previous)",
                       "empreinte stockée avant écriture réussie"),
        "archive-uniqueness": ("if mkdir(candidate.path, 0o700) == 0 { return candidate }",
                               "if mkdir(candidate.path, 0o700) == 0 || errno == EEXIST { return candidate }",
                               "archive de la même seconde réutilisée"),
    }[args.sabotage]
    text = service.read_text()
    if text.count(needle) != 1:
        raise SystemExit("Couture de sabotage ambiguë ou absente : " + args.sabotage)
    service = work / service.name
    service.write_text(text.replace(needle, replacement))

binary = work / "curation-tests"
subprocess.run(["swiftc", "-swift-version", "5", "-D", "DEBUG", "-parse-as-library",
                "-I", str(module_path), "-lsqlite3", str(service),
                str(REPO / "App/AnalysisExecution.swift"),
                str(REPO / "Scripts/runtime-tests/Stubs.swift"),
                str(REPO / "Scripts/curation-tests/RetrospectiveStub.swift"),
                str(REPO / "Scripts/curation-tests/Main.swift"), str(caller),
                *map(str, objects),
                "-o", str(binary)], check=True)
cases = [("archive-collision", "archive-collision")]
for route in ["shutdown", "disable", "home"]:
    for stage in ["before", "after"]:
        name = f"cancel-{route}-{stage}"
        cases += [(name, name), ("restart", name)]
cases += [(name, name) for name in ["legacy-fresh", "malformed-fingerprint", "opt-out"]]
for scenario in ["unchanged", "manual", "changed", "policy-change"]:
    cases += [("baseline", scenario), (scenario, scenario)]
cases += [(name, name) for name in ["storage-failure", "repair-staging"]]
results = []
for scenario, folder in cases:
    fixture = work / folder
    fixture.mkdir(exist_ok=True)
    env = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(fixture), ZDOTDIR=str(fixture))
    result = subprocess.run([str(binary), scenario], env=env, text=True, capture_output=True, timeout=30)
    if result.returncode:
        if expected_failure and expected_failure in result.stderr:
            print("PASS sabotage détecté : " + expected_failure)
            break
        raise SystemExit(result.stdout + result.stderr)
    case = json.loads(result.stdout)
    results.append(case)
    print("PASS " + folder + "/" + scenario, flush=True)
else:
    if args.sabotage:
        raise SystemExit("Sabotage non détecté : " + args.sabotage)
summary = {"realGenerativeCLICalls": 0, "casesPassed": len(results),
           "sabotageDetected": args.sabotage, "results": results,
           "scope": "Service et budget réels. Routes fermeture/changement home extraites des appelants ; pas de lancement GUI. Redémarrage réel du harness, faux quota frais et CLI local."}
output = args.output or work / "results.json"
output.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
print(f"Résultats : {output}")
