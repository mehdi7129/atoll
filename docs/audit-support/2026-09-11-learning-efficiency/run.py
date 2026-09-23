#!/usr/bin/env python3
"""Reproduire les constats de l'audit sur les sources réelles, sans analyse IA.

Les assertions décrivent le comportement observé à la base de l'audit, y compris
ses défauts. Après correction produit, les remplacer par les tests de régression
du lot concerné ; un changement de résultat n'est pas forcément une régression.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
CORE = "AtollCore/Sources/AtollCore/"
VALUE_FILES = [CORE + name + ".swift" for name in
               ["TranscriptLine", "TranscriptDigest", "SkillCatalog"]]
GROWTH_FILES = [CORE + name + ".swift" for name in
                ["TranscriptLine", "TranscriptDigest", "CodexTranscriptParser", "LearningGate"]]
RUNTIME_FILES = ["App/RetrospectiveRunner.swift", "App/NotesCurationService.swift",
                 "App/CodexInteractionCenter.swift", "App/AnalysisExecution.swift",
                 "App/PluginInventory.swift", "Scripts/runtime-tests/Stubs.swift"]


def capture(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs)


def core_probe(work, name, files):
    binary = work / name
    subprocess.run(["swiftc", *[str(REPO / f) for f in files],
                    str(HERE / name / "main.swift"), "-o", str(binary)], check=True)
    fixtures = work / (name + "-fixtures")
    fixtures.mkdir()
    return json.loads(capture([str(binary), str(fixtures)], timeout=30))


def compile_runtime(work, build, name, main_file):
    binary = work / name
    subprocess.run(["swiftc", "-swift-version", "5", "-D", "DEBUG", "-parse-as-library",
                    "-I", str(build / "Modules"), "-lsqlite3",
                    *[str(REPO / f) for f in RUNTIME_FILES], str(HERE / main_file),
                    *[str(p) for p in sorted((build / "AtollCore.build").glob("*.o"))],
                    "-o", str(binary)], check=True)
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="JSON synthétique ; défaut : dossier temporaire")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="atoll-learning-efficiency-"))
    print(f"Fixtures et binaires isolés : {work}", flush=True)

    value = core_probe(work, "value", VALUE_FILES)
    assert value["projectCommandFound"] and not value["projectSkillFound"]
    assert value["catalogUnchangedAfterPendingAndRejected"]
    assert not value["digestFinalEvidencePresent"] and not value["digestTruncatedFlag"]
    assert value["digestTruncationMarkerPresent"]

    growth = core_probe(work, "growth", GROWTH_FILES)
    assert growth["rawGrowthBytes"] >= growth["growthThresholdBytes"]
    assert growth["digestIdentical"] and growth["secondDecision"] == "run"
    assert "alreadyProcessed" in growth["sameBytesControlDecision"]
    assert "windowCapReached" in growth["windowCapControlDecision"]

    subprocess.run(["swift", "build", "--package-path", str(REPO / "AtollCore")], check=True)
    build = Path(capture(["swift", "build", "--package-path", str(REPO / "AtollCore"),
                          "--show-bin-path"]).strip())
    binary = compile_runtime(work, build, "curation", "CurationMain.swift")
    runtime = {}
    for scenario, folder in [("cancel", "cancel"), ("baseline", "unchanged"), ("unchanged", "unchanged")]:
        fixtures = work / ("curation-" + folder)
        fixtures.mkdir(exist_ok=True)
        env = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(fixtures), ZDOTDIR=str(fixtures))
        log = capture([str(binary), scenario], env=env, timeout=30)
        (work / (scenario + ".log")).write_text(log)
        runtime[scenario] = json.loads((fixtures / ("result-" + scenario + ".json")).read_text())
    assert runtime["cancel"]["newSpawns"] == 2
    assert runtime["cancel"]["stateUnchangedAfterCancel"]
    assert runtime["cancel"]["corpusUnchangedAfterCancel"]
    assert runtime["baseline"]["hashesAfter"] == runtime["unchanged"]["hashesBefore"]
    assert runtime["unchanged"]["newSpawns"] == 1

    binary = compile_runtime(work, build, "write", "WriteMain.swift")
    writes = {}
    for scenario in ["nominal", "blocked"]:
        fixtures = work / ("write-" + scenario)
        fixtures.mkdir()
        env = dict(os.environ, ATOLL_RUNTIME_TEST_ROOT=str(fixtures), ZDOTDIR=str(fixtures))
        log = capture([str(binary), scenario], env=env, timeout=30)
        (work / ("write-" + scenario + ".log")).write_text(log)
        writes[scenario] = json.loads((fixtures / "result.json").read_text())
    assert writes["nominal"]["noteSinkCalls"] == 1 and writes["blocked"]["noteSinkCalls"] == 0
    assert writes["blocked"]["actualNoteFiles"] == 0 and writes["blocked"]["actualProposalDirectories"] == 0
    assert writes["blocked"]["outcome"] == "success(1n/1s)"

    source_files = sorted(set(VALUE_FILES + GROWTH_FILES + RUNTIME_FILES))
    summary = {
        "baselineCommit": capture(["git", "rev-parse", "HEAD"], cwd=REPO).strip(),
        "realGenerativeCLICalls": 0,
        "value": value,
        "growth": growth,
        "writes": writes,
        "curation": {
            "cancelledDueCurationSpawns": runtime["cancel"]["newSpawns"],
            "cadenceStateUnchangedAfterCancellation": runtime["cancel"]["stateUnchangedAfterCancel"],
            "corpusUnchangedAfterCancellation": runtime["cancel"]["corpusUnchangedAfterCancel"],
            "unchangedCorpusExtraSpawn": runtime["unchanged"]["newSpawns"],
            "corpusHashesAfterBaseline": runtime["baseline"]["hashesAfter"],
            "corpusHashesBeforeNextDueRun": runtime["unchanged"]["hashesBefore"],
        },
        "sourceSHA256": {f: hashlib.sha256((REPO / f).read_bytes()).hexdigest() for f in source_files},
    }
    output = args.output or work / "results.json"
    output.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print(f"Constats reproduits ; synthèse : {output}")


if __name__ == "__main__":
    main()
