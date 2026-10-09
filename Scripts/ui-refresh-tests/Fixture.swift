import AppKit
import AtollCore
import Foundation

// Injecté uniquement dans la copie source jetable du harness. L'app demeure
// un aperçu : pas de bridge, scheduler, indexeur ou CLI authentifié démarré.
@MainActor enum UIRefreshFixture {
    static var root: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATOLL_UI_REFRESH_ROOT"]!) }
    static var reads = 0
    static var completedReads = 0
    static var delayed: CheckedContinuation<CodexCatalogState.Results, Never>?
    static var delayedContext: CodexCatalogState.Context?
    static var lastCommand = ""

    static func prepare() {
        precondition(CodexPreview.enabled)
        precondition(Bundle.main.bundleIdentifier?.hasPrefix("dev.mehdiguiard.atoll.previewtest.") == true)
        precondition(BridgePaths.homeDirectory.resolvingSymlinksInPath() == root.appendingPathComponent("home").resolvingSymlinksInPath())
        precondition(CodexPaths.homeURL == root.appendingPathComponent("home-a"))
        UserDefaults.standard.set(true, forKey: LearningSettings.enabledKey)
        UserDefaults.standard.set(false, forKey: CodexService.quotaEnabledKey)
        UserDefaults.standard.set(false, forKey: LearningSettings.curationScheduledKey)
        do {
            try FileManager.default.createDirectory(at: BridgePaths.learningNotesDirectory, withIntermediateDirectories: true)
            try Data("---\ntitle: NOTE INITIALE\n---\nNote déjà enregistrée.\n".utf8)
                .write(to: BridgePaths.learningNotesDirectory.appendingPathComponent("initiale.md"))
            try status("prepared")
        } catch { fatalError("Préparation privée refusée : \(error)") }
    }

    static func start() {
        Task { @MainActor in
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: root.appendingPathComponent("command.json")),
                   let command = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let id = command["id"], id != lastCommand, let action = command["action"] {
                    lastCommand = id
                    do { try perform(action); try status(id) }
                    catch { try? status(id, error: error.localizedDescription) }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    static func perform(_ action: String) throws {
        switch action {
        case "success", "abstention", "error":
            RetrospectiveRunner.shared.fixtureJournal(action)
        case "recover":
            let destination = try SkillDestination.capture(origin: .claude)
            let report = RetrospectiveReport(sessionSummary: "Reprise privée", nothingLearned: false,
                notes: [.init(slug: "reprise-visible", category: "pitfall", content: "NOTE REPRISE VISIBLE", confidence: "high")],
                skills: [], costUSD: nil, flags: [:])
            let delivery = RetrospectiveDelivery(report: report, analysisID: UUID(), sessionID: "recette-reprise",
                origin: .claude, destination: .claude, proposals: destination.store.proposedDirectory,
                notesDirectory: BridgePaths.learningNotesDirectory, project: root.path, transcriptBytes: 100,
                materialFingerprint: "recette-ui", decidedAt: Date())
            try RetrospectiveDelivery.Store(learningRoot: BridgePaths.learningDirectory).save(delivery)
            RetrospectiveRunner.shared.recoverPendingDeliveries()
        case "delay":
            try Data().write(to: root.appendingPathComponent("delay-catalog"))
        case "home-a", "home-b":
            NotificationCenter.default.post(name: Notification.Name("AtollUIFixtureHome"), object: root.appendingPathComponent(action).path)
        case "scroll-top", "scroll-bottom":
            func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap(find).first
            }
            guard let content = NSApp.windows.first(where: { $0.title == "Atoll — recette isolée" })?.contentView,
                  let scroll = find(content), let document = scroll.documentView else {
                throw NSError(domain: "UIRefresh", code: 1, userInfo: [NSLocalizedDescriptionKey: "ScrollView de recette introuvable"])
            }
            let end = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let atEnd = (action == "scroll-bottom") == document.isFlipped
            scroll.contentView.scroll(to: NSPoint(x: 0, y: atEnd ? end : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        case "release":
            try? FileManager.default.removeItem(at: root.appendingPathComponent("delay-catalog"))
            if let continuation = delayed, let context = delayedContext {
                delayed = nil; delayedContext = nil
                continuation.resume(returning: results(context, suffix: "TARDIF"))
            }
        default: fatalError("Commande privée inconnue")
        }
    }

    static func status(_ id: String, error: String? = nil) throws {
        let value: [String: Any] = ["id": id, "reads": reads, "error": error ?? "",
            "journalRevision": RetrospectiveRunner.shared.journalRevision,
            "notesRevision": RetrospectiveRunner.shared.notesRevision,
            "home": BridgePaths.homeDirectory.path, "codexHome": CodexPaths.homeURL.path,
            "pendingRead": delayed != nil, "completedReads": completedReads]
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            .write(to: root.appendingPathComponent("status.json"), options: .atomic)
    }

    static func catalog() -> CodexCatalogState {
        CodexCatalogState(resolve: { _ in "fixture-sans-cli" }, read: { context, _ in
            await UIRefreshFixture.read(context)
        })
    }

    static func catalogTaskEnded() {
        completedReads += 1
        try? status(lastCommand)
    }

    static func read(_ context: CodexCatalogState.Context) async -> CodexCatalogState.Results {
        reads += 1
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("delay-catalog").path) {
            return await withCheckedContinuation { continuation in
                delayed = continuation; delayedContext = context
                try? status(lastCommand)
            }
        }
        try? status(lastCommand)
        return results(context)
    }

    static func results(_ context: CodexCatalogState.Context, suffix: String = "") -> CodexCatalogState.Results {
        let title = "CATALOGUE " + (context.home.lastPathComponent == "home-a" ? "ALPHA" : "BETA") + suffix
        let skills: [String: Any] = ["data": [["cwd": context.projectPath, "skills": [[
            "name": title, "description": "Fixture de contexte", "path": context.home.appendingPathComponent("SKILL.md").path,
            "scope": "USER", "enabled": true]], "errors": []]]]
        return (.available(try! JSONSerialization.data(withJSONObject: skills)),
                .available(Data("{\"marketplaces\":[]}".utf8)))
    }
}
