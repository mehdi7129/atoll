#!/usr/bin/env python3
"""Régressions et sabotages locaux du catalogue, de l'antériorité et des livraisons.

Les sources modifiées restent dans un dossier temporaire. Aucun CLI génératif,
aucune app et aucune configuration personnelle ne sont utilisés. macOS/Xcode.
"""
from pathlib import Path
import argparse
import json
import plistlib
import subprocess
import tempfile


GROUPS = {
    "catalog": (["SkillCatalog"], "SkillCatalogTests"),
    "novelty": (["LearningNovelty", "LearnedSkillStore"], "LearningNoveltyTests"),
    "delivery": (["RetrospectiveDelivery"], "RetrospectiveDeliveryTests"),
    "retrospective-report": (["RetrospectiveReport"], "RetrospectiveReportTests"),
    "retrospective-prompt": (["RetrospectivePrompt", "CodexExecPlan"], "RetrospectivePromptTests"),
}
# Chaque mutation doit échouer dans son test témoin, et compiler auparavant.
MUTATIONS = {
    "invalid-skill-trace": ("retrospective-report", "RetrospectiveReport", [
        ('if rejected.count < Limit.skills { rejected.append("invalid-proposal-\\(index + 1)") }',
         '()')],
        "testRealCodexLongSlugRejectionIsVisibleWithoutRewritingItsValidProcedure"),
    "project-scope": ("catalog", "SkillCatalog", [
        ("userSkills() + projectSkills() + commands()", "userSkills() + commands()")],
        "testProject"),
    "proposal-identity": ("novelty", "LearningNovelty", [
        ("let body = LearningSkillProposalFile.body(of: markdown)",
         "let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)")],
        "testPendingAndRejectedExactSkillsAreKnownButDifferentProcedureSurvives"),
    "note-dedup": ("novelty", "LearningNovelty", [
        ('history.fingerprints.insert(fingerprint(body: trimmed, category: fields["category"] ?? "",\n'
         '                project: fields["project"]))',
         '_ = fingerprint(body: trimmed, category: fields["category"] ?? "",\n'
         '                project: fields["project"])')],
        "testNoteIdentityIgnoresSlugButPreservesProjectCategoryAndCodeWhitespace"),
    "incomplete-history": ("novelty", "LearningNovelty", [
        ("                incomplete = true", "                ()")],
        "testUnavailableHistoryRootIsPartialButMissingRootIsNormal"),
    "delivery-archives": ("delivery", "RetrospectiveDelivery", [
        ("let archived = !present && noteAlreadyArchived(note, deliveryID: value.id, notesDirectory: notesDirectory)",
         "let archived = false"),
        ('for category in ["approved", "rejected"] {', 'for category in [String]() {')],
        "testInterruptedCheckpointRecognizesRejectedSkillAndCuratedNote"),
    "delivery-intent": ("delivery", "RetrospectiveDelivery", [
        ("guard note.started == false else", "guard true else"),
        ("guard skill.started == false || partial else", "guard true else")],
        "testMissingProofAfterArchivePurgeStaysPendingWithoutRecreation"),
    "delivery-provenance": ("delivery", "RetrospectiveDelivery", [
        ('return object["delivery_id"] as? String == deliveryID.uuidString\n'
         '                    && object["delivery_artifact"] as? String == skill.dirname\n'
         '                    && ["proposed", "approved", "rejected"].contains(object["status"] as? String ?? "")',
         'return ["proposed", "approved", "rejected"].contains(object["status"] as? String ?? "")')],
        "testAnotherDeliveryWithIdenticalContentsDoesNotCountAsOurProof"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sabotage", choices=MUTATIONS)
    parser.add_argument("--all", action="store_true", help="baseline puis tous les sabotages")
    parser.add_argument("--build-dir", type=Path, help="réutiliser un build Core Debug, sans rebuild")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    if args.build_dir:
        build = args.build_dir.resolve()
    else:
        command = ["swift", "build", "--package-path", str(repo / "AtollCore"), "--build-system", "native"]
        subprocess.run([*command, "--jobs", "4"], check=True)
        build = Path(subprocess.check_output([*command, "--show-bin-path"], text=True).strip())
    modules = build / "Modules" if (build / "Modules").is_dir() else build
    library = [str(build / "libAtollCore.a")] if (build / "libAtollCore.a").exists() else [
        str(path) for path in sorted((build / "AtollCore.build").glob("*.o"))]
    if not library:
        raise SystemExit("Build Core Debug introuvable : " + str(build))
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    platform = developer / "Platforms/MacOSX.platform/Developer"
    frameworks = platform / "Library/Frameworks"
    support = platform / "usr/lib"
    root = Path(tempfile.mkdtemp(prefix="atoll-learning-core-"))
    print("Preuves :", root, flush=True)
    results = []

    def run(name, group, mutation=None):
        directory = root / name
        directory.mkdir()
        sources, test = GROUPS[group]
        files = []
        for source in sources:
            text = (repo / "AtollCore/Sources/AtollCore" / (source + ".swift")).read_text()
            if mutation and source == mutation[1]:
                for needle, replacement in mutation[2]:
                    if text.count(needle) != 1:
                        raise SystemExit("Couture de sabotage absente ou ambiguë : " + name)
                    text = text.replace(needle, replacement)
            target = directory / (source + ".swift")
            target.write_text("@testable import AtollCore\n" + text)
            files.append(str(target))
        target = directory / (test + ".swift")
        target.write_text((repo / "AtollCore/Tests/AtollCoreTests" / target.name).read_text())
        files.append(str(target))
        bundle = directory / "LearningCoreTests.xctest"
        (bundle / "Contents/MacOS").mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "dev.atoll.learning-core-tests",
            "CFBundleExecutable": "LearningCoreTests", "CFBundlePackageType": "BNDL"}))
        command = ["swiftc", "-I", str(modules), "-I", str(support), "-L", str(support),
                   "-lXCTestSwiftSupport", "-lsqlite3", "-F", str(frameworks), "-framework", "XCTest",
                   "-Xlinker", "-rpath", "-Xlinker", str(support),
                   "-Xlinker", "-rpath", "-Xlinker", str(frameworks), *files, *library,
                   "-emit-library", "-module-name", "LearningCoreTests", "-o",
                   str(bundle / "Contents/MacOS/LearningCoreTests")]
        (directory / "compile-command.json").write_text(json.dumps(command, indent=2))
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=90)
        (directory / "compile.log").write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise SystemExit("Échec de compilation, jamais compté comme sabotage : " + str(directory))
        tested = subprocess.run(["xcrun", "xctest", str(bundle)], capture_output=True, text=True, timeout=90)
        log = tested.stdout + tested.stderr
        (directory / "run.log").write_text(log)
        expected = mutation[3] if mutation else None
        detected = bool(expected and any("error:" in line and expected in line for line in log.splitlines()))
        passed = tested.returncode == 0 if not mutation else tested.returncode != 0 and detected
        results.append({"name": name, "passed": passed, "exit_code": tested.returncode})
        (root / "results.json").write_text(json.dumps(results, indent=2))
        if not passed:
            raise SystemExit("Résultat inattendu : " + str(directory / "run.log"))
        print("PASS", name, flush=True)

    selected = list(MUTATIONS) if args.all else ([args.sabotage] if args.sabotage else [])
    groups = list(GROUPS) if args.all or not selected else list(dict.fromkeys(MUTATIONS[name][0] for name in selected))
    for group in groups:
        run("baseline-" + group, group)
    for name in selected:
        run(name, MUTATIONS[name][0], MUTATIONS[name])


if __name__ == "__main__":
    main()
