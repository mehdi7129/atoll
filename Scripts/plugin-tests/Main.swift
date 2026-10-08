import Foundation
import AtollCore

struct Failure: Error { let message: String }

actor CatalogGate {
    private var pending: [Int: CheckedContinuation<CodexCatalogState.Results, Never>] = [:]
    private(set) var calls = 0
    func read() async -> CodexCatalogState.Results {
        let index = calls; calls += 1
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func complete(_ index: Int, _ results: CodexCatalogState.Results) { pending.removeValue(forKey: index)?.resume(returning: results) }
}

@main
struct Main {
    @MainActor static var checks = 0
    @MainActor static var metrics: [String: Any] = [:]
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_PLUGIN_TEST_ROOT"]!)

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(message: message) }
    }
    @MainActor static func wait(_ message: String, timeout: TimeInterval = 12,
                                until: () async -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !(await until()) {
            if ContinuousClock.now >= limit { throw Failure(message: "Attente dépassée : " + message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func write(_ config: [String: Any], _ folder: URL) throws {
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: folder.appendingPathComponent("config.json"), options: .atomic)
    }
    static func installed(_ count: Int, version: String = "1", path: String = "/fixture/source") -> [[String: Any]] {
        (0..<count).map { ["id": "p\($0)@market", "version": version, "scope": "user", "enabled": true,
                           "installPath": path + "/p\($0)"] }
    }
    static func fixture(_ name: String, config: [String: Any]) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("fake-cli")
        try FileManager.default.copyItem(at: root.appendingPathComponent("fake-cli-template"), to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        try write(config, folder)
        return folder
    }
    static func events(_ folder: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("events.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    static func starts(_ folder: URL, kind: String) -> [[String: Any]] {
        events(folder).filter { ($0["kind"] as? String) == kind && ($0["phase"] as? String) == "start" }
    }
    @MainActor static func refresh(_ inventory: PluginInventory) async throws {
        let before = inventory.lastRefreshedAt
        inventory.refresh()
        try await wait("refresh") { inventory.lastRefreshedAt != before || inventory.lastError != nil }
        try check(inventory.lastError == nil, "Inventaire nominal indisponible")
    }

    @MainActor static func concurrency() async throws {
        var durations: [Double] = []
        for limit in [1, 2] {
            let folder = try fixture("queue-\(limit)", config: ["installed": installed(30), "fail": ["p7"],
                "fallback": ["p8@market"], "detailsDelay": 0.06])
            let inventory = PluginInventory(claudePath: folder.appendingPathComponent("fake-cli").path,
                                            detailConcurrencyLimit: limit)
            try await refresh(inventory)
            for _ in 0..<3 { _ = inventory.snapshot; _ = inventory.tokenCosts }
            try check(starts(folder, kind: "details").isEmpty, "A13-render-spawn")
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<3 { for index in 0..<30 { inventory.loadTokenCost(for: "p\(index)@market") } }
            try await wait("30 coûts", timeout: 45) {
                let details = events(folder).filter { ($0["kind"] as? String) == "details" }
                return details.filter { ($0["phase"] as? String) == "end" }.count >= 32 && inventory.tokenCosts.count == 29
            }
            durations.append(ProcessInfo.processInfo.systemUptime - start)
            var active: Set<Int> = []; var peak = 0; var perID: [String: Int] = [:]
            for event in events(folder) where (event["kind"] as? String) == "details" {
                let pid = event["pid"] as! Int
                let id = (event["id"] as! String).components(separatedBy: "@")[0]
                if event["phase"] as? String == "start" {
                    active.insert(pid); peak = max(peak, active.count); perID[id, default: 0] += 1
                    try check(perID[id] == 1, "A13-one-per-id")
                } else { active.remove(pid); perID[id, default: 0] -= 1 }
            }
            try check(peak <= limit, "A13-bounded-concurrency")
            try check(starts(folder, kind: "details").count == 32, "A13-deduplicated-requests")
            try check(inventory.tokenCosts["p7@market"] == nil && inventory.tokenCosts["p8@market"] == 100,
                      "A13-independent-failure-fallback")
            let count = starts(folder, kind: "details").count
            try await refresh(inventory)
            try check(inventory.tokenCosts.count == 29 && starts(folder, kind: "details").count == count,
                      "A14-unchanged-cache")
            metrics["queue\(limit)"] = ["peak": peak, "commands": count, "seconds": durations.last!]
        }
        print("PASS A13 : 30 plugins, bornes 1/2, doublons, échec local et fallback.")

        let folder = try fixture("queue-cancel", config: ["installed": installed(30), "detailsDelay": 0.5])
        let inventory = PluginInventory(claudePath: folder.appendingPathComponent("fake-cli").path)
        try await refresh(inventory)
        for index in 0..<30 { inventory.loadTokenCost(for: "p\(index)@market") }
        try await wait("deux coûts en vol") { starts(folder, kind: "details").count >= 2 }
        inventory.cancel()
        try await Task.sleep(for: .milliseconds(300))
        try check(starts(folder, kind: "details").count == 2 && inventory.tokenCosts.isEmpty, "A13-cancel-queue")
    }

    @MainActor static func cancellation() async throws {
        for global in [false, true] {
            let folder = try fixture("cancel-\(global)", config: ["installed": installed(1),
                "availableDelay": 0.5, "mutationDelay": 0.6])
            let inventory = PluginInventory(claudePath: folder.appendingPathComponent("fake-cli").path)
            let search = Task { await inventory.search(need: "plugins fixture") }
            try await wait("recherche en vol") { !starts(folder, kind: "list").isEmpty }
            let mutation = Task { await inventory.install(pluginID: "p0@market") }
            try await wait("mutation en vol") { !starts(folder, kind: "install").isEmpty }
            if global { inventory.cancel() } else { inventory.cancelSearch() }
            let searchResult = await search.value
            let mutationResult = await mutation.value
            try check(searchResult == "Recherche annulée." && inventory.searchMatches.isEmpty, "A12-search-cancelled")
            let finished = FileManager.default.fileExists(atPath: folder.appendingPathComponent("mutation-finished").path)
            try check(global ? !finished : finished, "A12-scope-preserves-mutation")
            try check(global ? mutationResult != nil : mutationResult == nil, "A12-mutation-verdict")
        }
        print("PASS A12 : annuler recherche conserve mutation ; fermeture arrête les deux.")
    }

    @MainActor static func cache() async throws {
        var config: [String: Any] = ["installed": installed(2), "tokens": ["p0": 111, "p1": 50], "detailsDelay": 0.3]
        let folder = try fixture("cache", config: config)
        let inventory = PluginInventory(claudePath: folder.appendingPathComponent("fake-cli").path)
        try await refresh(inventory)
        inventory.loadTokenCost(for: "p0@market")
        try await wait("ancien coût") { starts(folder, kind: "details").count == 1 }
        config["installed"] = installed(2, version: "2")
        config["tokens"] = ["p0": 222, "p1": 50]
        config["detailsDelay"] = 0.3
        try write(config, folder)
        try await refresh(inventory)
        inventory.loadTokenCost(for: "p0@market")
        try await wait("nouveau coût") { starts(folder, kind: "details").count == 2 }
        try check(inventory.tokenCosts["p0@market"] == nil, "A14-reject-late-version")
        try await wait("coût version2") { inventory.tokenCosts["p0@market"] != nil }
        try check(inventory.tokenCosts["p0@market"] == 222, "A14-current-version")
        inventory.loadTokenCost(for: "p1@market")
        try await wait("coût stable") { inventory.tokenCosts["p1@market"] != nil }

        var changed = installed(2, version: "2")
        changed[0]["installPath"] = "/fixture/other-source"
        config["installed"] = changed
        try write(config, folder)
        try await refresh(inventory)
        try check(inventory.tokenCosts["p0@market"] == nil, "A14-source-invalidates")
        try check(inventory.tokenCosts["p1@market"] == 50, "A14-targeted-invalidation")
        inventory.loadTokenCost(for: "p0@market")
        try await wait("coût source2") { inventory.tokenCosts["p0@market"] != nil }
        config["installed"] = [changed[1]]
        try write(config, folder)
        try await refresh(inventory)
        try check(inventory.tokenCosts["p0@market"] == nil && inventory.tokenCosts["p1@market"] == 50,
                  "A14-disappearance-invalidates")
        print("PASS A14 : version, source, disparition, réponse tardive et cache stable.")
    }

    static func catalogResult(_ context: CodexCatalogState.Context, name: String) throws -> CodexCatalogState.Results {
        let skills: [String: Any] = ["data": [["cwd": context.projectPath, "errors": [], "skills": [[
            "name": name, "description": "fixture", "path": "/fixture/\(name)/SKILL.md", "scope": "user", "enabled": true
        ]]]]]
        return (.available(try JSONSerialization.data(withJSONObject: skills)),
                .available(Data("{\"marketplaces\":[]}".utf8)))
    }
    @MainActor static func catalog() async throws {
        let a = CodexCatalogState.Context(projectPath: "/project-a", executableOverride: "/bin-a", home: URL(fileURLWithPath: "/home-a"))
        let alternatives = [
            CodexCatalogState.Context(projectPath: "/project-b", executableOverride: a.executableOverride, home: a.home),
            CodexCatalogState.Context(projectPath: a.projectPath, executableOverride: "/bin-b", home: a.home),
            CodexCatalogState.Context(projectPath: a.projectPath, executableOverride: a.executableOverride, home: URL(fileURLWithPath: "/home-b"))
        ]
        let loadedGate = CatalogGate()
        let loaded = CodexCatalogState(resolve: { $0 }, read: { _, _ in await loadedGate.read() })
        loaded.refresh(context: a)
        try await wait("catalogue chargé avant changement de home") { await loadedGate.calls == 1 }
        await loadedGate.complete(0, try catalogResult(a, name: "skill-a"))
        try await wait("catalogue chargé") { !loaded.reading }
        loaded.updateContext(alternatives[2])
        try check(loaded.skills.isEmpty && loaded.plugins == nil, "A20-loaded-home-clears")
        for (index, b) in alternatives.enumerated() {
            for lateError in [false, true] {
                let gate = CatalogGate()
                let state = CodexCatalogState(resolve: { $0 }, read: { _, _ in await gate.read() })
                state.refresh(context: a)
                try await wait("catalogue A") { await gate.calls == 1 }
                state.updateContext(b)
                try check(!state.reading && state.skills.isEmpty, "A20-context-clears")
                state.refresh(context: b)
                try await wait("catalogue B") { await gate.calls == 2 }
                await gate.complete(0, lateError ? (.unavailable("erreur A"), .unavailable("erreur A")) : try catalogResult(a, name: "skill-a"))
                try await Task.sleep(for: .milliseconds(30))
                try check(state.reading && state.skills.isEmpty && state.issues.isEmpty, "A20-reject-stale-result-\(index)")
                await gate.complete(1, try catalogResult(b, name: "skill-b"))
                try await wait("résultat B") { !state.reading }
                try check(state.skills.first?.name == "skill-b" && state.issues.isEmpty, "A20-current-result")
                state.updateContext(b)
                try check(state.skills.first?.name == "skill-b", "A20-stable-context")
                state.updateContext(a)
                try check(state.skills.isEmpty && state.plugins == nil, "A20-loaded-context-clears-\(index)")
                let calls = await gate.calls
                try check(calls == 2, "A20-no-automatic-read")
            }
        }
        print("PASS A20 : projet, binaire, home ; succès/erreur tardifs et catalogue déjà chargé.")
    }

    @MainActor static func inheritedPipe() async throws {
        let folder = try fixture("pipe", config: ["installed": installed(1), "inheritedPipe": true])
        let inventory = PluginInventory(claudePath: folder.appendingPathComponent("fake-cli").path)
        let start = ProcessInfo.processInfo.systemUptime
        inventory.refresh()
        try await wait("pipe hérité") { inventory.lastError != nil || inventory.snapshot != nil }
        let duration = ProcessInfo.processInfo.systemUptime - start
        try check(duration < 1.2, "A09-plugin-inherited-pipe-bounded")
        try check(inventory.snapshot == nil && inventory.lastError != nil, "A09-incomplete-output-rejected")
        metrics["inheritedPipeSeconds"] = duration
        print("PASS A09 plugins : parent sorti, descendant garde les pipes, retour borné.")
    }

    @MainActor static func main() async {
        do {
            let selected = CommandLine.arguments.dropFirst().first ?? "all"
            if ["all", "queue"].contains(selected) { try await concurrency() }
            if ["all", "cancel"].contains(selected) { try await cancellation() }
            if ["all", "cache"].contains(selected) { try await cache() }
            if ["all", "catalog"].contains(selected) { try await catalog() }
            if ["all", "pipe"].contains(selected) { try await inheritedPipe() }
            metrics["checks"] = checks
            print(String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            let message = (error as? Failure)?.message ?? String(describing: error)
            FileHandle.standardError.write(Data(("FAIL " + message + "\n").utf8))
            exit(1)
        }
    }
}
