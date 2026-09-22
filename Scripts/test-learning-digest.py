#!/usr/bin/env python3
"""Compare le condensé actuel à sa coupe historique, sur neuf fixtures hors ligne."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path)
parser.add_argument("--sabotage", choices=["head-only", "command-marker", "shortened-count", "dropped-count", "read-stop"])
args = parser.parse_args()
source = repo / "AtollCore/Sources/AtollCore/TranscriptDigest.swift"
original = source.read_text()
head_tail = "if role == .assistant || role == .summary {"
marker = 'let shortened = entry.wasShortened ? (entry.role == .tool ? " command=incomplete" : " content=shortened") : ""'
mutations = {
    "head-only": (head_tail, "if false {", "preuve finale perdue : final-correction"),
    "command-marker": (marker, 'let shortened = ""', "commande incomplète non signalée"),
    "shortened-count": ("keep[$0] && selected[$0].wasShortened", "selected[$0].wasShortened", "compteur raccourcis incorrect : pruned-and-read-limited"),
    "dropped-count": ("entriesDropped: selected.count - keptCount", "entriesDropped: 0", "compteur élagués incorrect : pruned-and-read-limited"),
    "read-stop": ("self.sourceReadStopped = sourceReadStopped", "self.sourceReadStopped = nil", "limite lecture perdue"),
}

def replace_once(text, needle, replacement):
    if text.count(needle) != 1:
        raise SystemExit("Couture de comparaison/sabotage absente ou ambiguë : " + needle)
    return text.replace(needle, replacement)

with tempfile.TemporaryDirectory(prefix="atoll-learning-digest-") as directory:
    root = Path(directory)
    def run(name, content, baseline=False):
        copied = root / (name + ".swift")
        copied.write_text(content)
        binary = root / name
        subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library",
                        str(repo / "AtollCore/Sources/AtollCore/TranscriptLine.swift"), str(copied),
                        str(repo / "Scripts/learning-tests/DigestBenchmarkMain.swift"), "-o", str(binary)],
                       check=True, timeout=60)
        return subprocess.run([str(binary)] + (["--baseline"] if baseline else []),
                              capture_output=True, text=True, timeout=20)

    if args.sabotage:
        needle, replacement, diagnostic = mutations[args.sabotage]
        result = run("sabotaged", replace_once(original, needle, replacement))
        if result.returncode == 0 or diagnostic not in result.stderr:
            raise SystemExit("Sabotage non détecté par le scénario attendu : " + result.stdout + result.stderr)
        print("PASS sabotage digest : " + diagnostic)
    else:
        # Baseline = même sélection/élagage, coupe historique par préfixe, sans
        # étiquettes nouvelles. Les budgets 150 000 / 2 000 restent identiques.
        baseline_source = replace_once(replace_once(original, head_tail, "if false {"), marker, 'let shortened = ""')
        baseline = run("head-only", baseline_source, baseline=True)
        current = run("current", original)
        if baseline.returncode or current.returncode:
            raise SystemExit(baseline.stderr + current.stderr)
        previous_rows, current_rows = json.loads(baseline.stdout), json.loads(current.stdout)
        previous_proofs = sum(row["preservedProofs"] for row in previous_rows)
        current_proofs = sum(row["preservedProofs"] for row in current_rows)
        if current_proofs <= previous_proofs:
            raise SystemExit("Le corpus comparatif ne distingue plus la conservation des preuves finales.")
        report = {
            "schemaVersion": 1,
            "fixtureCount": len(current_rows),
            "sourceSHA256": hashlib.sha256(original.encode()).hexdigest(),
            "scope": "Synthetic offline excerpt retention; no model generation or quality claim.",
            "tokenUsageMeasured": False,
            "reviewTimeMeasured": False,
            "baseline": previous_rows,
            "current": current_rows,
            "totals": {
                "expectedProofs": sum(row["expectedProofs"] for row in current_rows),
                "baselineProofs": previous_proofs, "currentProofs": current_proofs,
                "baselineCharacters": sum(row["characters"] for row in previous_rows),
                "currentCharacters": sum(row["characters"] for row in current_rows),
            },
        }
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"fixtures": report["fixtureCount"], **report["totals"]}, ensure_ascii=False))
