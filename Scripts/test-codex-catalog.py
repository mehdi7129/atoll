#!/usr/bin/env python3
"""Vrais catalogues et hooks/list, home/projet jetables, aucun appel modèle."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
codex = shutil.which("codex")
if not codex:
    raise SystemExit("codex absent : recette native non exécutée")
print(subprocess.check_output([codex, "--version"], text=True).strip())
subprocess.run(["swift", "build", "--package-path", str(repo / "AtollCore")], check=True)
build = Path(subprocess.check_output(["swift", "build", "--package-path", str(repo / "AtollCore"), "--show-bin-path"], text=True).strip())
with tempfile.TemporaryDirectory(prefix="atoll-native-catalog-") as directory:
    root = Path(directory)
    home = root / "codex home"
    skill = home / "skills/atoll-contract-fixture"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("---\nname: atoll-contract-fixture\ndescription: Test local du catalogue Atoll.\n---\nDonnée de test, aucune action.\n")
    project = root / "project with spaces"
    project.mkdir()
    alias = root / "project alias"
    alias.symlink_to(project, target_is_directory=True)
    source = root / "main.swift"
    source.write_text(r'''
import Foundation
import AtollCore
@main struct Main {
    static func main() throws {
        let args = CommandLine.arguments
        let home = URL(fileURLWithPath: args[2])
        try CodexHookSettingsEditor.edit(nil, install: true).write(to: home.appendingPathComponent("hooks.json"))
        let hooks = CodexReadClient.read(.hooks(cwd: args[3]), executable: URL(fileURLWithPath: args[1]), home: home)
        guard case .available(let hookData) = hooks, let diagnostic = CodexHookDiagnostics(data: hookData),
              diagnostic.managedCount == CodexHookEvent.Kind.allCases.count,
              diagnostic.obsoleteCount == 0, diagnostic.errorCount == 0,
              diagnostic.untrustedCount == diagnostic.managedCount else {
            if case .available(let raw) = hooks { print("hooks/list:", String(decoding: raw, as: UTF8.self)) }
            print("contrat hooks/list différent des définitions installées"); exit(1)
        }
        print("PASS hooks/list : \(diagnostic.managedCount) définitions Atoll reconnues, aucune confiance accordée.")
        let result = CodexReadClient.read(.skills(cwd: args[3]), executable: URL(fileURLWithPath: args[1]),
                                         home: URL(fileURLWithPath: args[2]))
        guard case .available(let data) = result else {
            if case .unavailable(let reason) = result { print("RPC unavailable: \(reason)") }
            exit(1)
        }
        guard let catalog = CodexSkillCatalog.parse(data, cwd: args[3]) else {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            print("catalog shape:", object?.keys.sorted() ?? [])
            if let listings = object?["data"] as? [[String: Any]] {
                print("listings:", listings.map { [$0["cwd"] ?? "missing", $0.keys.sorted()] })
            }
            exit(1)
        }
        guard let fixture = catalog.entries.first(where: { $0.name == "atoll-contract-fixture" }),
              fixture.path.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: args[2]).resolvingSymlinksInPath().path + "/skills/"), fixture.isAvailable else {
            print("fixture mismatch:", catalog.entries.filter { $0.name == "atoll-contract-fixture" }.map { [$0.path.path, $0.origin, String($0.isAvailable)] })
            print("catalog:", catalog.entries.count, "entries; errors:", catalog.errors)
            exit(1)
        }
        print("PASS skills/list : home explicite, chemin avec espaces/symlink, scope natif, skill activé ; aucun thread créé.")
        let plugins = CodexReadClient.read(.plugins(cwd: args[3]), executable: URL(fileURLWithPath: args[1]),
                                          home: URL(fileURLWithPath: args[2]))
        guard case .available(let raw) = plugins,
              let catalog = try? JSONDecoder().decode(CodexPluginCatalog.self, from: raw),
              catalog.marketplaceLoadErrors?.isEmpty != false else {
            print("plugin/list local unavailable"); exit(1)
        }
        print("PASS plugin/list : marketplaces locales, aucune mutation ni génération.")
    }
}
''')
    binary = root / "catalog-test"
    command = ["swiftc", "-parse-as-library", "-I", str(build / "Modules"), "-lsqlite3", str(source)]
    command += [str(path) for path in sorted((build / "AtollCore.build").glob("*.o"))]
    subprocess.run(command + ["-o", str(binary)], check=True)
    subprocess.run([str(binary), codex, str(home), str(alias)],
                   env=dict(os.environ, ATOLL_RETROSPECTIVE="1"), timeout=30, check=True)
