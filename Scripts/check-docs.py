#!/usr/bin/env python3
"""Confronte les affirmations vérifiables des documents au CODE.

Ce projet a un mode de défaillance mesuré, et récurrent : un document « à lire en
premier » ment en silence et inspire confiance. Trois audits successifs l'ont
retrouvé — comptes de tests faux, listes dites « exhaustives » qui ne l'étaient
pas, récit d'un chemin destructeur en réalité inatteignable, symboles renommés
cités sous leur ancien nom. La leçon écrite dans CLAUDE.md est : « confronter les
listes au code PAR SCRIPT, ne pas les relire ». Ce fichier EST ce script.

Il ne vérifie QUE ce qui est mécaniquement vérifiable. Une intention de
conception, un arbitrage, un « pourquoi » ne se testent pas ici — ils se datent
et se relisent à la main. C'est précisément pour ça qu'il faut les séparer du
reste : ce qui est vérifiable doit l'être automatiquement, pour que l'attention
humaine aille à ce qui ne l'est pas.

    Scripts/check-docs.py              # tout sauf le réseau, tests inclus
    Scripts/check-docs.py --no-tests   # rapide (saute `swift test`)
    Scripts/check-docs.py --network    # + les URL de l'appcast et du README

Sortie 0 = aucune dérive. Sortie 1 = au moins une ERREUR.
Les AVERTISSEMENTS ne font jamais échouer : ce sont des signaux à regarder, pas
des faits faux (sinon le script serait ignoré, ce qui est pire que rien).
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CODE_DIRS = ["App", "AtollCore/Sources", "Bridge", "Shared"]

errors: list[str] = []
warnings: list[str] = []
checked = 0


def fail(check: str, message: str) -> None:
    errors.append(f"[{check}] {message}")


def warn(check: str, message: str) -> None:
    warnings.append(f"[{check}] {message}")


def read(path: str) -> str:
    p = ROOT / path
    return p.read_text(encoding="utf-8") if p.exists() else ""


def code_text() -> str:
    """Tout le code source, concaténé — pour les recherches d'existence."""
    if not hasattr(code_text, "cache"):
        parts = []
        for directory in CODE_DIRS:
            for swift in (ROOT / directory).rglob("*.swift"):
                parts.append(swift.read_text(encoding="utf-8", errors="replace"))
        code_text.cache = "\n".join(parts)  # type: ignore[attr-defined]
    return code_text.cache  # type: ignore[attr-defined]


def paragraph_of(lines: list[str], index: int) -> str:
    """Le paragraphe (ou l'item de liste) qui contient `lines[index]`.

    Remonte jusqu'à une ligne vide ou jusqu'au début de l'item de liste courant.
    C'est l'unité qui porte le SENS : « retirés » s'écrit une fois, en tête, et
    vaut pour toute l'énumération qui suit.
    """
    start = index
    while start > 0 and lines[start - 1].strip():
        start -= 1
        if re.match(r"^\s*[-*]\s", lines[start]):
            break
    return "\n".join(lines[start:index + 1])


def heading_of(lines: list[str], index: int) -> str:
    """Le titre de section le plus proche AU-DESSUS de `lines[index]`.

    Une section « AUDIT DU 2026-07-27 » date tout ce qu'elle contient jusqu'au
    titre suivant : c'est ainsi qu'un document se lit. Ne regarder que le
    paragraphe faisait passer pour une affirmation au présent un relevé
    clairement rangé sous sa date.
    """
    for i in range(index, -1, -1):
        if re.match(r"^#{1,6}\s", lines[i]):
            return lines[i]
    return ""


def tracked_files() -> list[Path]:
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True)
    return [ROOT / line for line in out.stdout.splitlines() if line]


# ---------------------------------------------------------------- 1. les tests

def check_test_count(run_tests: bool) -> None:
    """Le compte de tests annoncé par les documents d'ÉTAT doit être le vrai.

    Les documents d'AUDIT sont exclus : ils datent un relevé, ils ne décrivent
    pas le présent. « 636 tests verts le 27 juillet » restera vrai pour toujours.
    """
    global checked
    if not run_tests:
        warn("tests", "sauté (--no-tests) : le compte annoncé n'a pas été vérifié")
        return
    proc = subprocess.run(
        ["swift", "test"], cwd=ROOT / "AtollCore", capture_output=True, text=True
    )
    counts = re.findall(r"Executed (\d+) tests", proc.stdout + proc.stderr)
    if not counts:
        fail("tests", "impossible de lire le nombre de tests exécutés (`swift test` a-t-il échoué ?)")
        return
    real = max(int(c) for c in counts)
    checked += 1

    for doc in ["CLAUDE.md", "docs/HANDOFF.md", "README.md"]:
        lines = read(doc).splitlines()
        for line_no, line in enumerate(lines, 1):
            for claimed in re.findall(r"(\d{3,4})\s+tests", line):
                if int(claimed) == real:
                    continue
                # Un relevé DATÉ est un fait historique — « 628 tests le
                # 27 juillet » restera vrai pour toujours. La date vit rarement
                # sur la même ligne que le chiffre : c'est le paragraphe qui
                # fait foi. Sans cette nuance, le script hurlerait à chaque
                # release sur des archives correctes, et on cesserait de le lire.
                dated = paragraph_of(lines, line_no - 1) + "\n" + heading_of(lines, line_no - 1)
                if re.search(r"20\d\d-\d\d-\d\d", dated):
                    continue
                fail(
                    "tests",
                    f"{doc}:{line_no} annonce « {claimed} tests » au présent, la suite en exécute {real}",
                )


# ------------------------------------------------------- 2. les triggers debug

def check_debug_triggers() -> None:
    """La liste dite « exhaustive » de CLAUDE.md, confrontée dans LES DEUX SENS.

    Sens oublié par le passé : un trigger AJOUTÉ au code et jamais documenté est
    invisible pour le prochain qui reprend — c'est ainsi que `seedPlugins`,
    `retroBig` et `pluginSearch` avaient disparu de la liste.
    """
    global checked
    delegate = read("App/AppDelegate.swift")
    # UNIQUEMENT les vraies inscriptions Darwin. `Notification.Name(
    # "…debug.openSettings")` porte le même préfixe mais n'est qu'un relais
    # interne : le prendre pour un trigger était un faux positif (vécu à la main
    # avant d'écrire ce script), et un faux positif fait abandonner l'outil.
    registered = set(re.findall(r'notify_register_dispatch\(\s*"[^"]*debug\.([a-zA-Z]+)"', delegate))
    if not registered:
        fail("triggers", "aucun trigger trouvé dans App/AppDelegate.swift — le motif a-t-il changé ?")
        return
    checked += 1

    claude = read("CLAUDE.md")
    section = re.search(
        r"Triggers debug \(.*?\n(.*?)(?=\n\*\*|\nDebug des interactions)", claude, re.S
    )
    if not section:
        fail("triggers", "section « Triggers debug » introuvable dans CLAUDE.md")
        return
    body = section.group(1)

    for trigger in sorted(registered):
        if not re.search(rf"`{trigger}`", body):
            fail("triggers", f"`{trigger}` est enregistré dans AppDelegate mais absent de la liste de CLAUDE.md")

    for line in body.splitlines():
        # Une ligne qui dit « retiré » documente une absence : elle est juste.
        if "retiré" in line:
            continue
        for token in re.findall(r"`([a-z][a-zA-Z]+)`", line):
            if token not in registered:
                fail("triggers", f"CLAUDE.md documente le trigger `{token}`, qui n'est enregistré nulle part")


# ------------------------------------------------------------- 3. les versions

def check_versions() -> None:
    """project.yml fait autorité ; README, CLAUDE.md et l'appcast doivent suivre."""
    global checked
    project = read("project.yml")
    marketing = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', project)
    build = re.search(r'CURRENT_PROJECT_VERSION:\s*"([^"]+)"', project)
    if not marketing or not build:
        fail("versions", "MARKETING_VERSION ou CURRENT_PROJECT_VERSION illisible dans project.yml")
        return
    version, build_number = marketing.group(1), build.group(1)
    checked += 1

    readme_versions = set(re.findall(r"Version courante\s*:\s*v?([0-9.]+?)\.?\s*\*", read("README.md")))
    if readme_versions and version not in readme_versions:
        fail("versions", f"README annonce {readme_versions}, project.yml dit {version}")

    claude_published = re.search(r"Version publiée\s*:\s*\*\*v?([0-9.]+)\*\*", read("CLAUDE.md"))
    if claude_published and claude_published.group(1) != version:
        fail("versions", f"CLAUDE.md annonce v{claude_published.group(1)}, project.yml dit {version}")

    appcast = read("docs/appcast.xml")
    newest = re.search(r"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>", appcast)
    if newest and newest.group(1) != version:
        fail("versions", f"la première entrée de l'appcast est {newest.group(1)}, project.yml dit {version}")

    # PIÈGE DE RELEASE payé en v0.14.0 : `generate_appcast` échoue APRÈS le build
    # et les deux notarisations — ~8 min perdues — si deux archives portent le
    # même CFBundleVersion. Le contrôle coûte une seconde ; CLAUDE.md demandait
    # jusqu'ici de le faire À LA MAIN.
    updates = ROOT / "dist" / "updates"
    if updates.is_dir():
        for archive in sorted(updates.glob("*.zip")):
            try:
                with zipfile.ZipFile(archive) as z:
                    # Le bundle de PREMIER NIVEAU, et lui seul : une archive
                    # Atoll contient aussi les Info.plist de Sparkle
                    # (Updater.app, Downloader.xpc, Installer.xpc), et prendre
                    # « le premier qui finit par Contents/Info.plist » lisait la
                    # version de Sparkle — le contrôle ne pouvait alors JAMAIS
                    # se déclencher.
                    info = next(
                        (n for n in z.namelist() if re.fullmatch(r"[^/]+\.app/Contents/Info\.plist", n)),
                        None,
                    )
                    if not info:
                        warn("versions", f"{archive.name} : bundle de premier niveau introuvable — non contrôlé")
                        continue
                    raw = z.read(info)
            except (zipfile.BadZipFile, OSError):
                warn("versions", f"{archive.name} illisible — non contrôlé")
                continue
            # `plistlib`, pas une regex : l'Info.plist d'un .app compilé est un
            # plist BINAIRE. Une lecture XML ne trouvait rien et le contrôle
            # passait toujours — un contrôle qui ne peut pas échouer est pire
            # qu'aucun contrôle, il rassure.
            try:
                plist = plistlib.loads(raw)
            except Exception:
                warn("versions", f"Info.plist de {archive.name} illisible — non contrôlé")
                continue
            archived_build = str(plist.get("CFBundleVersion", ""))
            archived_version = str(plist.get("CFBundleShortVersionString", ""))
            if archived_build != build_number:
                continue
            # Même build ET même version marketing = c'est la release DÉJÀ
            # publiée, pas une collision. La faute — celle qui coûte huit
            # minutes de build et deux notarisations avant d'éclater — c'est de
            # monter MARKETING_VERSION en oubliant CURRENT_PROJECT_VERSION :
            # même build, version différente.
            if archived_version != version:
                fail(
                    "versions",
                    f"CURRENT_PROJECT_VERSION {build_number} est déjà celui de {archive.name} "
                    f"(v{archived_version}) alors que project.yml annonce v{version} — "
                    "generate_appcast refusera l'archive en toute fin de release",
                )
    else:
        warn("versions", "dist/updates/ absent : impossible de vérifier l'unicité du CFBundleVersion")


# ------------------------------- 4. symboles et fichiers cités par les documents

def check_cited_symbols() -> None:
    """`Type.membre` cité entre accents graves : le membre existe-t-il ?

    Forme volontairement étroite. Un nom seul (`SessionStore`) est trop ambigu
    pour être vérifié sans bruit ; `IslandRowBudget.rows` est une affirmation
    précise, donc réfutable. C'est exactement la classe de dérive qui a fait
    citer `ExpandedView.stateRowBudget` des mois après son renommage.
    """
    global checked
    source = code_text()
    # Types que NOUS déclarons. Sans ce filtre, `Glass.tint` (SwiftUI) ou
    # `UNUserNotificationCenter.delegate` (système) seraient signalés comme
    # disparus alors qu'ils n'ont jamais été à nous.
    ours = set(re.findall(r"\b(?:struct|class|enum|actor|protocol)\s+([A-Z][A-Za-z0-9]*)", source))
    checked += 1
    for doc in ["CLAUDE.md", "docs/HANDOFF.md", "README.md"]:
        lines = read(doc).splitlines()
        for line_no, line in enumerate(lines, 1):
            # Un retrait s'annonce en tête de paragraphe, l'énumération des
            # symboles suivant sur plusieurs lignes : c'est le PARAGRAPHE entier
            # qu'il faut regarder. Une fenêtre de N lignes fixes laissait passer
            # la queue des listes longues — les neuf symboles morts de la
            # Phase 10 étaient signalés comme « disparus » alors que la ligne
            # d'ouverture dit justement qu'ils ont été retirés.
            if any(mark in paragraph_of(lines, line_no - 1)
                   for mark in ("⛔️", "retiré", "RETIRÉ", "supprimé", "SUPPRIMÉ", "N'EXISTE PLUS")):
                continue
            for type_name, member in re.findall(r"`([A-Z][A-Za-z0-9]+)\.([a-z][A-Za-z0-9]*)`", line):
                if type_name not in ours:
                    continue
                if not re.search(rf"\b{re.escape(member)}\b", source):
                    fail(doc.replace("docs/", ""), f"ligne {line_no} : `{type_name}.{member}` n'existe plus dans le code")


def check_cited_files() -> None:
    """Tout `X.swift` cité doit exister quelque part."""
    global checked
    known = {p.name for d in CODE_DIRS for p in (ROOT / d).rglob("*.swift")}
    checked += 1
    for doc in ["CLAUDE.md", "docs/HANDOFF.md", "README.md"]:
        for line_no, line in enumerate(read(doc).splitlines(), 1):
            if any(mark in line for mark in ("⛔️", "retiré", "RETIRÉ", "supprimé", "SUPPRIMÉ")):
                continue
            for cited in re.findall(r"`([A-Za-z0-9_/]+\.swift)`", line):
                if Path(cited).name not in known:
                    fail(doc.replace("docs/", ""), f"ligne {line_no} : le fichier `{cited}` n'existe pas")


# ------------------------------------------------------- 5. le README public

def check_readme_ascii() -> None:
    """Les blocs ASCII du README montrent l'interface : elle doit être la vraie.

    « Un README qui montre une UI inexistante est pire qu'un README ennuyeux »
    (règle éditoriale du projet). Le badge `[ INPUT? ]` a existé, puis a été
    retiré en Phase 14 — le README aurait pu le vendre encore longtemps.
    """
    global checked
    readme = read("README.md")
    ascii_art = read("AtollCore/Sources/AtollCore/AsciiArt.swift")
    card = read("App/InteractionCardView.swift")
    checked += 1

    badges = set(re.findall(r'return "(\[ [^"]+ \])"', ascii_art))
    for shown in set(re.findall(r"\[ [A-ZÀ-Ÿ?]+[A-ZÀ-Ÿ? ]* \]", readme)):
        if shown not in badges:
            fail("README", f"le bloc ASCII montre le badge « {shown} », qu'AsciiArt ne produit pas")

    buttons = set(re.findall(r'AsciiButton\(label:\s*"([^"]+)"', card))
    for shown in set(re.findall(r"[A-Z]{4,}\s+⌘[A-Z]", readme)):
        if shown not in buttons:
            fail("README", f"le bloc ASCII montre le bouton « {shown} », qui n'existe pas dans InteractionCardView")


def check_readme_links() -> None:
    """Aucune cible relative absente : une image cassée s'affiche sur la page d'accueil."""
    global checked
    checked += 1
    for target in re.findall(r"\]\(([^)#][^)]*)\)", read("README.md")):
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        if not (ROOT / target).exists():
            fail("README", f"lien ou image vers `{target}`, qui n'existe pas dans le dépôt")


# ------------------------------------------- 6. ce qui ne doit pas être public

def check_privacy() -> None:
    """Le dépôt est PUBLIC. Ni secret, ni chemin personnel dans les fichiers suivis."""
    global checked
    secret_patterns = [
        (r"sk-ant-api\w", "clé API Anthropic"),
        (r"\bghp_[A-Za-z0-9]{20,}", "token GitHub"),
        (r"\bgithub_pat_[A-Za-z0-9_]{20,}", "token GitHub"),
        (r"\bAKIA[0-9A-Z]{16}\b", "access key AWS"),
        (r"-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----", "clé privée"),
    ]
    # Le VRAI dossier personnel de la machine, pas un nom d'exemple : les
    # fixtures utilisent `/Users/moi`, `/Users/demo`, `/Users/alice`… et les
    # signaler noierait le seul cas qui compte.
    home_name = Path.home().name
    home = re.compile(rf"/Users/{re.escape(home_name)}\b")
    checked += 1
    for path in tracked_files():
        if not path.exists() or path.suffix in {".png", ".icns", ".zip"}:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        relative = path.relative_to(ROOT)
        for pattern, label in secret_patterns:
            for line_no, line in enumerate(text.splitlines(), 1):
                # Le détecteur de contenu suspect de RetrospectiveReport contient
                # ces motifs par CONSTRUCTION : c'est une sûreté, pas une fuite.
                if "RetrospectiveReport" in str(relative) or "suspicious" in line.lower():
                    continue
                if re.search(pattern, line):
                    fail("privé", f"{relative}:{line_no} — {label} apparent")
        if relative.parts[0] in {"docs", "README.md"} or str(relative) == "README.md":
            continue
        for line_no, line in enumerate(text.splitlines(), 1):
            if home.search(line):
                warn("privé", f"{relative}:{line_no} — chemin personnel en dur")


# ------------------------------------------------------------- 7. le code mort

def check_dead_code() -> None:
    """Symboles publics d'AtollCore que plus personne n'appelle.

    ERREUR pour ce qui n'est utilisé NULLE PART. AVERTISSEMENT pour ce qui n'est
    utilisé que par ses tests : ce n'est pas un fait faux, c'est un candidat au
    retrait — et le projet a déjà retiré sept API sur ce seul critère.
    """
    global checked
    sources = list((ROOT / "AtollCore/Sources").rglob("*.swift"))
    all_sources = "\n".join(p.read_text(encoding="utf-8", errors="replace") for p in sources)
    consumers = ""
    for directory in ["App", "Bridge", "Shared"]:
        for swift in (ROOT / directory).rglob("*.swift"):
            consumers += swift.read_text(encoding="utf-8", errors="replace")
    tests = ""
    for swift in (ROOT / "AtollCore/Tests").rglob("*.swift"):
        tests += swift.read_text(encoding="utf-8", errors="replace")
    checked += 1

    declarations = re.findall(
        r"^\s*public (?:static )?(?:func|var|let)\s+([a-zA-Z_][A-Za-z0-9_]*)", all_sources, re.M
    )
    for symbol in sorted(set(declarations)):
        uses_in_core = len(re.findall(rf"\b{re.escape(symbol)}\b", all_sources))
        used_outside = re.search(rf"\b{re.escape(symbol)}\b", consumers) is not None
        used_in_tests = re.search(rf"\b{re.escape(symbol)}\b", tests) is not None
        if uses_in_core <= 1 and not used_outside:
            if used_in_tests:
                warn("mort", f"`{symbol}` n'est utilisé QUE par ses tests — candidat au retrait")
            else:
                fail("mort", f"`{symbol}` est déclaré public et n'est utilisé nulle part")


def check_notifications() -> None:
    """Une notification postée sans observateur (ou l'inverse) est un fil coupé."""
    global checked
    app = ""
    for swift in (ROOT / "App").rglob("*.swift"):
        app += swift.read_text(encoding="utf-8", errors="replace")
    checked += 1
    for name in sorted(set(re.findall(r"static let (atoll[A-Za-z]+)\s*=\s*Notification\.Name", app))):
        posted = re.search(rf"post\(name:\s*\.{name}\b", app) is not None
        observed = (
            re.search(rf"(?:forName:|publisher\(for:)\s*\.{name}\b", app) is not None
            or re.search(rf"addObserver[^\n]*\.{name}\b", app) is not None
        )
        if posted and not observed:
            fail("notifs", f"`{name}` est postée mais jamais observée")
        if observed and not posted:
            fail("notifs", f"`{name}` est observée mais jamais postée")


# ----------------------------------------------------------------- 8. le réseau

def check_network() -> None:
    """Les URL que Sparkle et le README promettent doivent répondre."""
    global checked
    import urllib.error
    import urllib.request

    def status(url: str) -> int:
        request = urllib.request.Request(url, method="HEAD")
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code
        except Exception:
            return 0

    checked += 1
    for url in re.findall(r'url="([^"]+)"', read("docs/appcast.xml")):
        code = status(url)
        if code != 200:
            fail("réseau", f"l'appcast pointe vers {url} — réponse {code or 'injoignable'}")

    for url in sorted(set(re.findall(r"https?://[^\s)\"'>]+", read("README.md")))):
        code = status(url)
        if code != 200:
            fail("réseau", f"le README pointe vers {url} — réponse {code or 'injoignable'}")

    feed = re.search(r'SUFeedURL:\s*"([^"]+)"', read("project.yml"))
    if feed:
        try:
            with urllib.request.urlopen(feed.group(1), timeout=20) as response:
                served = response.read().decode("utf-8")
            if served.strip() != read("docs/appcast.xml").strip():
                fail("réseau", "l'appcast servi en ligne DIFFÈRE de docs/appcast.xml — les mises à jour ne verront pas la dernière version")
        except Exception as error:
            fail("réseau", f"flux Sparkle injoignable ({feed.group(1)}) : {error}")


# ---------------------------------------------------------------------- entrée

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-tests", action="store_true", help="saute `swift test` (rapide)")
    parser.add_argument("--network", action="store_true", help="vérifie aussi les URL publiques")
    parser.add_argument("--json", action="store_true", help="rapport machine")
    args = parser.parse_args()

    check_test_count(run_tests=not args.no_tests)
    check_debug_triggers()
    check_versions()
    check_cited_symbols()
    check_cited_files()
    check_readme_ascii()
    check_readme_links()
    check_privacy()
    check_dead_code()
    check_notifications()
    if args.network:
        check_network()

    if args.json:
        print(json.dumps({"errors": errors, "warnings": warnings, "checks": checked}, ensure_ascii=False, indent=2))
        return 1 if errors else 0

    print(f"── check-docs — {checked} familles de contrôles")
    if warnings:
        print(f"\n{len(warnings)} avertissement(s) — à regarder, sans échec :")
        for message in warnings:
            print(f"  · {message}")
    if errors:
        print(f"\n{len(errors)} ERREUR(S) — un document affirme quelque chose que le code contredit :")
        for message in errors:
            print(f"  ✗ {message}")
        print("\nUne dérive documentaire est un défaut : elle sera crue.")
        return 1
    print("\n✓ aucune dérive : tout ce qui est vérifiable concorde avec le code.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
