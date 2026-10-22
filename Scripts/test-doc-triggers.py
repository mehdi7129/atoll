#!/usr/bin/env python3
"""Contrat et contre-épreuve du lecteur de triggers, sans build ni fichier personnel."""
from pathlib import Path

source_path = Path(__file__).with_name("check-docs.py")
source = source_path.read_text()
delegate = '\n'.join('notify_register_dispatch("dev.atoll.debug.' + name + '", 0)' for name in ["expand", "compact", "seedSkill"])
modern = "## Triggers debug\n\n- `expand`, `compact`, `seedSkill`.\n\n## Autre section\n`horsListe`\n"
legacy = "Triggers debug (historique)\n- `expand`, `compact`, `seedSkill`.\nDebug des interactions\n"


def errors(text, document):
    scope = {"__name__": "doc_trigger_fixture", "__file__": str(source_path)}
    exec(compile(text, str(source_path), "exec"), scope)
    scope["read"] = lambda path: delegate if path == "App/AppDelegate.swift" else document
    scope["check_debug_triggers"]()
    return scope["errors"]


assert errors(source, modern) == [], "Section actuelle non reconnue ou limite de section ignorée"
assert errors(source, legacy) == [], "Section historique non reconnue"
assert errors(source, modern.replace("`seedSkill`", "")), "Trigger non documenté accepté"
assert errors(source, modern.replace("`seedSkill`", "`ancienTrigger`")), "Trigger obsolète accepté"
needle = 'r"^## Triggers debug\\s*\\n(.*?)(?=^## |\\Z)"'
assert source.count(needle) == 1, "Couture de sabotage absente"
mutant = source.replace(needle, 'r"^## Ancien titre absent\\s*\\n(.*?)(?=^## |\\Z)"')
assert any("introuvable" in error for error in errors(mutant, modern)), "Ancien parseur non détecté"
print("PASS titres actuel/historique, contrôles bidirectionnels et sabotage Python compilé")
