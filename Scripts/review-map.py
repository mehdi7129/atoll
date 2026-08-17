#!/usr/bin/env python3
"""Où est le risque : ce qui n'a jamais été relu, et ce qui a dérivé depuis.

L'audit du 2026-08-14 a trouvé neuf défauts SÉRIEUX dans trois fichiers dont le
document d'audit précédent disait, mot pour mot, qu'ils n'avaient « pas été relus
ligne à ligne ». L'information était écrite ; elle n'était simplement pas
exploitable — noyée dans un paragraphe, sans date, sans comparaison possible avec
le reste du dépôt.

Ce script la rend exploitable. Il croise trois choses qu'on sait établir sans
juger le code :

  1. la date de la dernière relecture DOCUMENTÉE (docs/reviews.json) ;
  2. ce qui a changé DEPUIS cette date (git) — un fichier relu il y a trois
     semaines mais réécrit depuis est plus risqué qu'un fichier relu il y a trois
     mois et jamais touché ;
  3. le nombre de fichiers qui DÉPENDENT de lui (graphe des types déclarés) — se
     tromper dans un fichier dont douze autres dépendent ne coûte pas la même
     chose que se tromper dans une feuille.

Ce n'est PAS une mesure de qualité, et ça ne remplace aucune lecture : c'est un
ordre de passage. La carte ne peut que SOUS-ESTIMER la couverture (voir la règle
d'inscription dans docs/reviews.json), ce qui est le bon sens de l'erreur.

    Scripts/review-map.py            # la carte, classée par risque
    Scripts/review-map.py --all      # tous les fichiers, pas seulement les 25 premiers
    Scripts/review-map.py --graph    # qui dépend de qui (le graphe seul)
    Scripts/review-map.py --json     # pour en faire autre chose
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import date, datetime
from fnmatch import fnmatch
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CODE_DIRS = ["App", "AtollCore/Sources", "Bridge", "Shared"]
TODAY = date.today()


def source_files() -> list[Path]:
    files: list[Path] = []
    for directory in CODE_DIRS:
        files.extend(sorted((ROOT / directory).rglob("*.swift")))
    return files


def relative(path: Path) -> str:
    return str(path.relative_to(ROOT))


def short(name: str) -> str:
    """`AtollCore/Sources/AtollCore/X.swift` → `AtollCore/X.swift`, pour la lecture."""
    return name.replace("AtollCore/Sources/AtollCore/", "AtollCore/")


# --------------------------------------------------------------- les relectures

def load_reviews() -> list[dict]:
    data = json.loads((ROOT / "docs" / "reviews.json").read_text(encoding="utf-8"))
    return sorted(data["reviews"], key=lambda r: r["date"])


def last_review(path: str, reviews: list[dict], depth: str) -> dict | None:
    """La relecture la plus RÉCENTE, à la profondeur demandée, couvrant ce fichier."""
    matching = [
        review for review in reviews
        if review["depth"] == depth
        and any(fnmatch(path, pattern) or fnmatch(Path(path).name, pattern) for pattern in review["files"])
    ]
    return matching[-1] if matching else None


# ------------------------------------------------------------------- la dérive

def churn_since(dates: set[str]) -> dict[str, dict[str, int]]:
    """Lignes ajoutées + supprimées par fichier, depuis chaque date de relecture.

    Un appel `git log` par DATE distincte, pas par fichier : le dépôt a 143
    fichiers source et trois dates de relecture.

    ⚠️ `--since=2026-08-14` SEUL est un piège : git le lit comme « le 14 août À
    L'HEURE QU'IL EST », donc la mesure change au fil de la journée. MESURÉ le
    2026-08-17 : la même carte, sur un dépôt inchangé, annonçait **3 fichiers
    dérivés à 18h20 et 35 le lendemain à 10h58** — un facteur douze, produit par
    l'horloge et non par le code. On ancre donc à MINUIT.
    Le choix de minuit (plutôt que l'heure réelle de la relecture, inconnue)
    compte les commits du jour de la relecture qui l'ont peut-être précédée :
    il SURESTIME la dérive. C'est le bon sens de l'erreur, le même que celui du
    registre — mieux vaut relire un fichier pour rien que le croire à jour.

    CE QUI RESTE DÉPENDANT, et qu'il ne faut pas prétendre avoir réglé : minuit
    est minuit DANS LE FUSEAU LOCAL. Mesuré en forçant `TZ` : 35 fichiers en
    Europe/Paris, 18 en Pacific/Midway. La dérive est donc une notion de
    calendrier local, comme les dates du registre elles-mêmes — comparer deux
    relevés faits sur deux machines de fuseaux différents n'a pas de sens.
    """
    result: dict[str, dict[str, int]] = {}
    for when in dates:
        out = subprocess.run(
            ["git", "log", f"--since={when}T00:00:00", "--numstat", "--format="],
            cwd=ROOT, capture_output=True, text=True,
        ).stdout
        per_file: dict[str, int] = {}
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) != 3:
                continue
            added, deleted, path = parts
            if not path.endswith(".swift"):
                continue
            if added == "-" or deleted == "-":   # fichier binaire
                continue
            per_file[path] = per_file.get(path, 0) + int(added) + int(deleted)
        result[when] = per_file
    return result


# -------------------------------------------------------------------- le graphe

def dependency_graph(files: list[Path]) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    """Qui utilise les types déclarés par qui.

    Swift n'a pas d'en-têtes : la seule relation lisible sans compiler est
    « ce fichier nomme un type déclaré par cet autre ». C'est grossier — un nom
    cité dans un commentaire compte — mais suffisant pour un ORDRE DE PASSAGE,
    et ça ne prétend rien de plus.
    """
    # PREMIER NIVEAU seulement : `^` sans indentation. Les types IMBRIQUÉS
    # s'appellent `Phase`, `State`, `Job`, `PersistedState` — des noms si
    # génériques que les compter donnait 30 dépendants à des fichiers qui n'en
    # ont aucun. Un graphe faux oriente le travail vers les mauvais fichiers,
    # c'est-à-dire exactement le contraire de ce qu'on lui demande.
    top_level = re.compile(
        r"^(?:(?:public|internal|private|fileprivate|final|open)\s+)*"
        r"(?:struct|class|enum|actor|protocol)\s+([A-Z][A-Za-z0-9]*)",
        re.M,
    )
    declared: dict[str, set[str]] = {}
    contents: dict[str, str] = {}
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        contents[relative(path)] = text
        declared[relative(path)] = set(top_level.findall(text))

    def used_names(text: str) -> set[str]:
        """Noms employés COMME DU CODE, pas cités dans une phrase.

        `MemoryIndex.search`, `: MemoryIndex`, `[MemoryIndex]`, `MemoryIndex(`,
        `-> MemoryIndex`… Un simple mot capitalisé attrapait les mentions en
        commentaire — nombreuses dans ce dépôt, où les commentaires nomment
        volontiers les autres modules.
        """
        found: set[str] = set()
        for pattern in (
            r"\b([A-Z][A-Za-z0-9]*)\s*\(",      # construction / appel
            r"\b([A-Z][A-Za-z0-9]*)\.",          # accès à un membre
            r":\s*\[?([A-Z][A-Za-z0-9]*)",       # annotation de type
            r"->\s*\[?([A-Z][A-Za-z0-9]*)",      # type de retour
            r"\b(?:as|is)\s+([A-Z][A-Za-z0-9]*)",
            r"\bextension\s+([A-Z][A-Za-z0-9]*)",
        ):
            found.update(re.findall(pattern, text))
        return found

    uses: dict[str, set[str]] = {name: set() for name in contents}
    used_by: dict[str, set[str]] = {name: set() for name in contents}
    for consumer, text in contents.items():
        words = used_names(text)
        for provider, names in declared.items():
            if provider == consumer or not names:
                continue
            if names & words:
                uses[consumer].add(provider)
                used_by[provider].add(consumer)
    return uses, used_by


# ---------------------------------------------------------------------- la carte

def build_rows(reviews: list[dict]) -> list[dict]:
    files = source_files()
    _, used_by = dependency_graph(files)
    churn = churn_since({review["date"] for review in reviews})

    rows = []
    for path in files:
        name = relative(path)
        lines = len(path.read_text(encoding="utf-8", errors="replace").splitlines())
        read = last_review(name, reviews, "line-by-line")
        swept = last_review(name, reviews, "sweep")
        reference = read or swept
        since = churn[reference["date"]].get(name, 0) if reference else lines
        age = (TODAY - datetime.strptime(reference["date"], "%Y-%m-%d").date()).days if reference else None

        # Poids assumés, et discutables — c'est un ordre de passage, pas une note.
        # Jamais lu ligne à ligne : tout le fichier est à découvrir, donc son
        # volume compte en entier. Déjà lu : seule la dérive compte.
        unread = lines if not read else min(since, lines)
        risk = unread * (1 + len(used_by[name]) / 10)

        rows.append({
            "file": name,
            "lines": lines,
            "read_date": read["date"] if read else None,
            "swept_date": swept["date"] if swept else None,
            "days": age,
            "churn": since,
            "dependents": len(used_by[name]),
            "risk": round(risk),
        })
    return sorted(rows, key=lambda r: -r["risk"])


def print_map(rows: list[dict], show_all: bool) -> None:
    never = [r for r in rows if not r["read_date"]]
    total = sum(r["lines"] for r in rows)
    unread = sum(r["lines"] for r in never)
    drifted = [r for r in rows if r["read_date"] and r["churn"] > 0]

    print(f"── Carte des relectures — {len(rows)} fichiers, {total} lignes")
    print(f"   jamais relus ligne à ligne : {len(never)} fichiers, {unread} lignes ({100*unread//max(total,1)} %)")
    print(f"   relus puis modifiés depuis : {len(drifted)} fichiers")
    print()
    print(f"{'fichier':<44}{'lignes':>7}  {'dernière lecture':<22}{'dérive':>8}{'dép.':>6}")
    print("─" * 89)
    for row in (rows if show_all else rows[:25]):
        if row["read_date"]:
            when = f"{row['read_date']} (il y a {row['days']} j)"
        elif row["swept_date"]:
            when = f"balayée le {row['swept_date']}"
        else:
            when = "JAMAIS"
        churn = f"+{row['churn']}" if row["churn"] else "—"
        print(f"{short(row['file']):<44}{row['lines']:>7}  {when:<22}{churn:>8}{row['dependents']:>6}")
    if not show_all and len(rows) > 25:
        print(f"… {len(rows) - 25} autres (--all)")
    print()
    print("« relu le » = dernière lecture LIGNE À LIGNE documentée ; « balayé » = seulement")
    print("couvert par une passe par sous-système. « dérive » = lignes changées depuis.")
    print("« dép. » = fichiers qui nomment un type déclaré ici.")


def print_graph(rows: list[dict]) -> None:
    files = source_files()
    uses, used_by = dependency_graph(files)
    ranked = sorted(used_by.items(), key=lambda kv: -len(kv[1]))
    print("── Les plus dépendus (toucher ces fichiers porte le plus loin)\n")
    for name, consumers in ranked[:15]:
        if not consumers:
            continue
        print(f"{len(consumers):>3} ← {name}")
        print(f"      {', '.join(sorted(Path(c).name for c in consumers)[:8])}"
              + (" …" if len(consumers) > 8 else ""))
    isolated = [name for name, consumers in used_by.items() if not consumers and not uses[name]]
    if isolated:
        print(f"\nSans lien détecté ({len(isolated)}) : {', '.join(Path(i).name for i in isolated)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--all", action="store_true", help="tous les fichiers")
    parser.add_argument("--graph", action="store_true", help="le graphe de dépendances seul")
    parser.add_argument("--json", action="store_true", help="sortie machine")
    args = parser.parse_args()

    rows = build_rows(load_reviews())
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    elif args.graph:
        print_graph(rows)
    else:
        print_map(rows, show_all=args.all)
    return 0


if __name__ == "__main__":
    sys.exit(main())
