#!/usr/bin/env python3
"""Agrégats locaux en lecture seule ; aucun contenu, chemin personnel ou ID exporté."""
import argparse
import collections
import datetime as dt
import json
import pathlib
import re
import statistics


def read_json(path):
    return json.loads(path.read_text()) if path.is_file() else None


def distribution(values):
    return {"count": len(values), "min": min(values),
            "median": statistics.median(values), "max": max(values)} if values else {"count": 0}


def date(value):
    return (dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
            + dt.timedelta(seconds=value)).isoformat()


def skill_stock(roots):
    statuses = collections.Counter()
    pending = 0
    for root in roots:
        pending += sum(1 for p in (root / "proposed").glob("**/meta.json") if p.is_file())
        for path in (root / "archive").glob("**/meta.json"):
            status = read_json(path).get("status")
            statuses[status if status in {"approved", "rejected", "proposed", "archived"} else "other"] += 1
    return {"scopes": len(roots), "pendingMetadataFiles": pending,
            "archiveStatuses": dict(sorted(statuses.items()))}


def observe(root):
    state = read_json(root / "retrospectives.json") or {}
    attempts = state.get("attempts", [])
    candidates = [a for a in attempts if a.get("decision", "").startswith("run")]
    success = [a for a in candidates if a.get("outcome", "").startswith("success")]
    costs = [a["costUSD"] for a in candidates if isinstance(a.get("costUSD"), (int, float))]
    dates = [a["decidedAt"] for a in attempts if isinstance(a.get("decidedAt"), (int, float))]
    # Seuls des labels connus sont publiés : une future erreur contenant un chemin
    # ou une sortie de modèle ne peut pas se retrouver dans le rapport par défaut.
    reasons = {"sessionTooShort", "tooFewUserPrompts", "quotaStale", "sessionResumed",
               "transcriptMissing", "quotaAboveThreshold", "configuration", "alreadyProcessed",
               "disabled", "windowCapReached", "quotaUnknown"}

    def decision(value):
        if value in {"run", "run(debug)"}:
            return value
        match = re.fullmatch(r"skip\((\w+)\)", value)
        return value if match and match[1] in reasons else "other"

    def outcome(value):
        if value is None:
            return "missing"
        if value.startswith("success"):
            return "success"
        if value.startswith("failed"):
            return "failed"
        return "other"

    curation = read_json(root / "curation.json") or {}
    oversized = re.fullmatch(r"corpus trop volumineux \((\d+) caractères\) — curation refusée",
                             curation.get("lastOutcome", ""))
    # LearnedSkillStore conserve Claude à la racine et isole chaque home Codex.
    # Le nombre de scopes est publié, jamais leur nom ni leur empreinte de chemin.
    codex_roots = [p for p in (root / "skills-v2").glob("codex-*") if p.is_dir()]
    return {
        "observedAtUTC": dt.datetime.now(dt.timezone.utc).isoformat(),
        "scope": "Retained local sample; not a billing ledger or current-generator benchmark",
        "analysisJobsV2Present": (root / "analysis-jobs-v2.json").is_file(),
        "attemptCount": len(attempts),
        "retainedDateRangeUTC": [date(min(dates)), date(max(dates))] if dates else [],
        "decisions": dict(sorted(collections.Counter(decision(a.get("decision", "")) for a in attempts).items())),
        "runCandidates": len(candidates),
        "candidateOutcomes": dict(sorted(collections.Counter(outcome(a.get("outcome")) for a in candidates).items())),
        "candidateProviders": dict(sorted(collections.Counter(
            a.get("provider") if a.get("provider") in {"codex", "claude"} else "unspecified"
            for a in candidates).items())),
        "reportedCostUSD": {"samples": len(costs), "sum": round(sum(costs), 6),
                            "max": max(costs) if costs else None,
                            "meaning": "CLI-reported indicator; not invoice, subscription debit or complete spend"},
        "reportedNotes": sum(a.get("notesWritten", 0) for a in success),
        "reportedSkills": sum(a.get("skillsProposed", 0) for a in success),
        "candidateDigestCharacters": distribution([a["digestCharacters"] for a in candidates if "digestCharacters" in a]),
        "candidateTranscriptBytes": distribution([a["transcriptBytes"] for a in candidates if "transcriptBytes" in a]),
        "candidateTokenUsageFieldsPresent": any(
            any(key in a for key in ["inputTokens", "outputTokens", "cachedInputTokens", "usage", "tokenUsage"])
            for a in candidates),
        "noteFiles": sum(1 for p in (root / "notes").glob("*.md") if p.is_file()),
        "skillStocks": {"claude": skill_stock([root]), "codex": skill_stock(codex_roots)},
        "lastCuration": {"lastRunAtUTC": date(curation["lastRunAt"]) if "lastRunAt" in curation else None,
                         "outcomeCategory": "oversized-corpus" if oversized else "other-or-missing",
                         "reportedCorpusCharacters": int(oversized[1]) if oversized else None},
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--learning-dir", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if not args.learning_dir.is_dir():
        parser.error("Le dossier d'apprentissage n'existe pas.")
    print(json.dumps(observe(args.learning_dir), indent=2, ensure_ascii=False))
