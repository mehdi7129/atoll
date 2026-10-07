#!/usr/bin/env python3
"""Exerce le poller quota réel, extrait sans réécriture, avec un lecteur contrôlé.

Aucune app, aucun Codex et aucune préférence persistée. Le lecteur synchrone
simule un enfant qui met du temps à sortir après annulation. Les sabotages sont
appliqués uniquement à la copie Swift temporaire et doivent échouer à l'exécution.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sabotage", choices=["overlap", "stop-reference", "before-fetch", "stale", "child-cancel"])
args = parser.parse_args()
source = (repo / "App/CodexService.swift").read_text()


def method(signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    # Les méthodes retenues n'ont pas d'accolade seule dans leurs littéraux.
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


methods = "\n".join(method(signature) for signature in [
    "    func stop()", "    func syncQuotaSettings()",
    "    private func fetch(generation current: UUID)",
    "    private func resolveExecutable()",
])
mutations = {
    "overlap": ("            await previousPoll?.value", "", "lecteurs simultanés"),
    "stop-reference": ("        pollTask?.cancel()", "        pollTask?.cancel()\n        pollTask = nil", "référence perdue après stop"),
    "before-fetch": ("        guard !Task.isCancelled, generation == current else { return }\n        guard let executable", "        guard let executable", "fetch déjà annulé a lancé un lecteur"),
    "stale": ("        guard !Task.isCancelled, generation == current else { return }\n        isLoading = false", "        isLoading = false", "ancien quota publié pendant changement de réglage"),
    "child-cancel": ("            worker.cancel()", "", "annulation enfant non propagée"),
}
expected = None
if args.sabotage:
    needle, replacement, expected = mutations[args.sabotage]
    if methods.count(needle) != 1:
        raise SystemExit("Couture de sabotage absente ou ambiguë : " + args.sabotage)
    methods = methods.replace(needle, replacement)

harness = r'''
import Foundation

struct CodexQuota: Sendable { let id: String }
@MainActor enum CodexPaths {
    static var configurationError: String?
    static var homeURL = URL(fileURLWithPath: "/fixture/home-a")
}
@MainActor enum CodexExecutable {
    static var selected: URL? = URL(fileURLWithPath: "/fixture/codex-a")
    static var resolutions = 0
    static func resolveCheap() -> URL? { resolutions += 1; return selected }
}

// Ne remplace que le transport, pas l'ordonnancement du service.
final class ReaderProbe: @unchecked Sendable {
    struct Call { let home: URL; let executable: URL }
    struct Snapshot { let calls: [Call]; let active: Int; let maxActive: Int; let cancelled: Int }
    let lock = NSLock()
    var calls: [Call] = []
    var active = 0, maxActive = 0, cancellations = Set<Int>(), released = Set<Int>()
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(calls: calls, active: active, maxActive: maxActive, cancelled: cancellations.count)
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        precondition(active == 0)
        calls = []; maxActive = 0; cancellations = []; released = []
    }
    func release(_ index: Int) { lock.lock(); released.insert(index); lock.unlock() }
    func read(executable: URL, home: URL, cancelled: @Sendable () -> Bool) -> CodexAccountClient.Outcome {
        lock.lock()
        let index = calls.count
        calls.append(Call(home: home, executable: executable))
        active += 1; maxActive = max(active, maxActive)
        lock.unlock()
        while true {
            let wasCancelled = cancelled()
            lock.lock()
            if wasCancelled { cancellations.insert(index) }
            let done = released.contains(index)
            if done { active -= 1 }
            lock.unlock()
            if done { return .available(CodexQuota(id: home.lastPathComponent)) }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}
enum CodexAccountClient {
    enum Outcome: Sendable { case available(CodexQuota), unavailable(String) }
    static let probe = ReaderProbe()
    static func read(executable: URL, home: URL, cancelled: @Sendable () -> Bool) -> Outcome {
        probe.read(executable: executable, home: home, cancelled: cancelled)
    }
}

@MainActor final class CodexService {
    static let quotaEnabledKey = "codexQuotaEnabled"
    private(set) var quota: CodexQuota?
    private(set) var status = ""
    private(set) var isLoading = false
    private var pollTask: Task<Void, Never>?
    private var generation = UUID()
    // Collaborateurs sans rapport avec le quota, touchés par stop().
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var scanTicket = UUID(), scanGeneration = UUID(), metadataTicket = UUID()
    private var metadataTask: Task<Void, Never>?
    private var metadataSignatures: [String: String] = [:]
__METHODS__
    func fetchForTest() async { await fetch(generation: generation) }
    func settled() async { await pollTask?.value }
}

@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}
@MainActor func eventually(_ message: String, _ predicate: () -> Bool) async {
    let deadline = Date().addingTimeInterval(1)
    while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    check(predicate(), message)
}
@MainActor func enable(_ enabled: Bool) {
    // Le domaine d'arguments est volatil : aucun plist utilisateur n'est écrit.
    UserDefaults.standard.setVolatileDomain([CodexService.quotaEnabledKey: enabled], forName: UserDefaults.argumentDomain)
}
@MainActor func pause() async { try? await Task.sleep(for: .milliseconds(80)) }

@main struct Main {
    @MainActor static func main() async {
        let probe = CodexAccountClient.probe
        enable(false)
        let disabled = CodexService()
        disabled.syncQuotaSettings()
        await pause()
        check(probe.snapshot().calls.isEmpty, "lecture désactivée a lancé un lecteur")
        enable(true)
        disabled.syncQuotaSettings()
        enable(false)
        disabled.syncQuotaSettings()
        await disabled.settled()
        check(probe.snapshot().calls.isEmpty, "off avant exécution a lancé un lecteur")
        print("PASS disabled + on/off avant démarrage : zéro lecteur")

        // Appeler la vraie entrée fetch depuis une Task déjà annulée vérifie la
        // garde locale, indépendamment de celle de la boucle appelante.
        let resolutions = CodexExecutable.resolutions
        let cancelledFetch = Task { await disabled.fetchForTest() }
        cancelledFetch.cancel()
        await pause()
        check(probe.snapshot().calls.isEmpty, "fetch déjà annulé a lancé un lecteur")
        await cancelledFetch.value
        check(CodexExecutable.resolutions == resolutions, "résolution après annulation")
        print("PASS fetch déjà annulé : zéro résolution et zéro lecteur")

        enable(true)
        let serial = CodexService()
        serial.syncQuotaSettings()
        await eventually("premier lecteur absent") { probe.snapshot().calls.count == 1 }
        CodexPaths.homeURL = URL(fileURLWithPath: "/fixture/home-b")
        CodexExecutable.selected = URL(fileURLWithPath: "/fixture/codex-b")
        serial.syncQuotaSettings()
        CodexPaths.homeURL = URL(fileURLWithPath: "/fixture/home-c")
        CodexExecutable.selected = URL(fileURLWithPath: "/fixture/codex-c")
        serial.syncQuotaSettings()
        await eventually("annulation enfant non propagée") { probe.snapshot().cancelled == 1 }
        await pause()
        check(probe.snapshot().maxActive == 1 && probe.snapshot().calls.count == 1, "lecteurs simultanés")
        probe.release(0)
        await eventually("dernier réglage jamais lu") { probe.snapshot().calls.count == 2 }
        let latest = probe.snapshot().calls[1]
        check(latest.home == CodexPaths.homeURL && latest.executable == CodexExecutable.selected, "lecture d'un réglage intermédiaire")
        check(serial.quota == nil, "ancien quota publié pendant changement de réglage")
        probe.release(1)
        await eventually("quota courant non publié") { serial.quota?.id == "home-c" }
        check(!serial.isLoading, "isLoading reste actif après réponse")
        serial.stop()
        await serial.settled()
        check(probe.snapshot().maxActive == 1, "lecteurs simultanés après reprise")
        print("PASS home + executable rapides : un lecteur maximum, seul dernier réglage publié")

        probe.reset()
        let stopped = CodexService()
        stopped.syncQuotaSettings()
        await eventually("lecteur stop absent") { probe.snapshot().calls.count == 1 }
        stopped.stop()
        stopped.syncQuotaSettings()
        await pause()
        check(probe.snapshot().calls.count == 1, "référence perdue après stop")
        probe.release(0)
        await eventually("lecture après stop non reprise") { probe.snapshot().calls.count == 2 }
        enable(false)
        stopped.syncQuotaSettings()
        await eventually("enfant final non annulé") { probe.snapshot().cancelled == 2 }
        probe.release(1)
        await stopped.settled()
        check(stopped.quota == nil && !stopped.isLoading, "ancien quota publié après désactivation")
        check(stopped.status == "lecture désactivée dans Réglages → Codex", "ancien statut publié après désactivation")
        check(probe.snapshot().active == 0, "enfant actif après désactivation")
        print("PASS stop/reprise sérialisés + désactivation : ancienne réponse ignorée, enfant sorti")

        probe.reset()
        enable(true)
        let queued = CodexService()
        queued.syncQuotaSettings()
        await eventually("lecteur file absent") { probe.snapshot().calls.count == 1 }
        for _ in 0..<5 { queued.syncQuotaSettings() }
        enable(false)
        queued.syncQuotaSettings()
        probe.release(0)
        await queued.settled()
        check(probe.snapshot().calls.count == 1, "un lecteur en file a démarré après off")
        check(queued.quota == nil, "ancien quota publié après désactivation")
        print("PASS cinq relances annulées en file : aucun spawn après off")
        print("PASS 8 scénarios quota, sans Codex ni préférence persistée")
    }
}
'''.replace("__METHODS__", methods)

with tempfile.TemporaryDirectory(prefix="atoll-quota-poller-") as directory:
    root = Path(directory)
    swift = root / "Poller.swift"
    binary = root / "poller-tests"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], timeout=15, text=True, capture_output=True)
    print(result.stdout, end="")
    if expected:
        if result.returncode == 0 or expected not in result.stderr:
            raise SystemExit("Sabotage non détecté par le scénario attendu : " + result.stderr)
        print("PASS sabotage compilé détecté : " + expected)
    elif result.returncode:
        raise SystemExit(result.stderr)
