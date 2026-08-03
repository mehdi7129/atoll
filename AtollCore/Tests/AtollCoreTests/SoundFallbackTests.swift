import XCTest
@testable import AtollCore

/// Le filet sonore du helper : ce qui garantit qu'un son sonne même quand
/// l'app est fermée — la panne constatée le 2026-08-03 (deux jours de silence
/// total, hooks de l'utilisateur parqués ET app morte).
final class SoundFallbackTests: XCTestCase {

    // MARK: - Réglages partagés

    private func settings(enabled: Bool = true,
                          decision: String = "custom:need-human.mp3",
                          completed: String = "system:Glass",
                          volume: Double = 0.1) -> SoundFallback.Settings {
        SoundFallback.Settings(
            enabled: enabled,
            choices: [SoundEvent.decisionNeeded.rawValue: decision,
                      SoundEvent.taskCompleted.rawValue: completed],
            volumes: [SoundEvent.decisionNeeded.rawValue: volume,
                      SoundEvent.taskCompleted.rawValue: volume])
    }

    func testSettingsSurviveARoundTrip() throws {
        let original = settings()
        let decoded = SoundFallback.decode(try SoundFallback.encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// Le helper est dans le chemin d'un hook : un fichier absent, vide ou
    /// corrompu doit le rendre MUET, jamais le faire échouer.
    func testCorruptSettingsAreSilentNotFatal() {
        XCTAssertNil(SoundFallback.decode(nil))
        XCTAssertNil(SoundFallback.decode(Data()))
        XCTAssertNil(SoundFallback.decode(Data("{ pas du json".utf8)))
        XCTAssertNil(SoundFallback.decode(Data("[]".utf8)))
    }

    func testUnknownEventFallsBackToDefaults() {
        let empty = SoundFallback.Settings(enabled: true, choices: [:], volumes: [:])
        XCTAssertEqual(empty.choice(for: .taskCompleted), .silent)
        XCTAssertEqual(empty.volume(for: .taskCompleted), SoundEvent.defaultVolume)
    }

    func testVolumeIsClamped() {
        let loud = SoundFallback.Settings(enabled: true, choices: [:],
                                          volumes: [SoundEvent.taskCompleted.rawValue: 9])
        XCTAssertEqual(loud.volume(for: .taskCompleted), 1)
        let negative = SoundFallback.Settings(enabled: true, choices: [:],
                                              volumes: [SoundEvent.taskCompleted.rawValue: -3])
        XCTAssertEqual(negative.volume(for: .taskCompleted), 0)
    }

    // MARK: - Quel hook déclenche quel son

    /// Exactement les deux événements sur lesquels l'utilisateur avait posé ses
    /// propres `afplay`. Ni plus, ni moins.
    func testOnlyTheTwoUserEventsRing() {
        XCTAssertEqual(SoundFallback.event(forHookEvent: "Notification"), .decisionNeeded)
        XCTAssertEqual(SoundFallback.event(forHookEvent: "Stop"), .taskCompleted)
    }

    /// `PermissionRequest` sonnerait EN PLUS de `Notification` pour une même
    /// demande, et `SubagentStop` tinterait à chaque sous-agent. La table de
    /// l'app (`SoundCenter.event(forHookEvent:)`) les reconnaît parce qu'elle
    /// sert à REPRENDRE des hooks ; celle-ci sert à JOUER.
    func testNoisyEventsAreRefused() {
        for name in ["PermissionRequest", "SubagentStop", "PreToolUse", "SessionStart",
                     "UserPromptSubmit", "StopFailure", "", "stop", "NOTIFICATION"] {
            XCTAssertNil(SoundFallback.event(forHookEvent: name), "\(name) ne doit pas sonner")
        }
    }

    // MARK: - Résolution du fichier

    func testCustomSoundResolvesInsideAtollDirectory() {
        let sounds = URL(fileURLWithPath: "/tmp/atoll-test/sounds", isDirectory: true)
        let url = SoundFallback.fileURL(for: .custom("finish.mp3"),
                                        soundsDirectory: sounds,
                                        fileExists: { $0 == "/tmp/atoll-test/sounds/finish.mp3" })
        XCTAssertEqual(url?.path, "/tmp/atoll-test/sounds/finish.mp3")
    }

    func testMissingFileYieldsNilRatherThanASilentAfplay() {
        let url = SoundFallback.fileURL(for: .custom("disparu.mp3"),
                                        soundsDirectory: URL(fileURLWithPath: "/tmp/atoll-test/sounds"),
                                        fileExists: { _ in false })
        XCTAssertNil(url)
    }

    func testSilentPlaysNothing() {
        XCTAssertNil(SoundFallback.fileURL(for: .silent,
                                           soundsDirectory: URL(fileURLWithPath: "/tmp"),
                                           fileExists: { _ in true }))
    }

    /// Le helper n'a pas AppKit : il reconstruit le chemin d'un son système à la
    /// main, du plus spécifique au plus général.
    func testSystemSoundIsSearchedInOrder() {
        var consulted: [String] = []
        let url = SoundFallback.fileURL(
            for: .system("Glass"),
            soundsDirectory: URL(fileURLWithPath: "/tmp/atoll-test/sounds"),
            systemDirectories: ["/System/Library/Sounds", "/Library/Sounds"],
            userSoundsDirectory: URL(fileURLWithPath: "/Users/x/Library/Sounds"),
            fileExists: { path in
                consulted.append(path)
                return path == "/System/Library/Sounds/Glass.aiff"
            })
        XCTAssertEqual(url?.path, "/System/Library/Sounds/Glass.aiff")
        // Le dossier de l'utilisateur passe AVANT ceux du système.
        XCTAssertTrue(consulted.first?.hasPrefix("/Users/x/Library/Sounds/") ?? false,
                      "obtenu : \(consulted.prefix(3))")
    }

    /// Un réglage trafiqué ne doit pas pouvoir désigner un fichier arbitraire.
    /// `SoundChoice.decode` refuse déjà tout ce qui n'est pas un composant nu ;
    /// on le vérifie ici de bout en bout, jusqu'au chemin résolu.
    func testTraversalAttemptNeverResolves() {
        for raw in ["custom:../../../etc/passwd", "custom:/etc/passwd",
                    "system:../../../../System/Library/Sounds/Glass", "custom:.hidden"] {
            let choice = SoundChoice.decode(raw)
            XCTAssertEqual(choice, .silent, "\(raw) aurait dû retomber sur silent")
            XCTAssertNil(SoundFallback.fileURL(for: choice,
                                               soundsDirectory: URL(fileURLWithPath: "/tmp"),
                                               fileExists: { _ in true }))
        }
    }

    // MARK: - Anti-rafale entre processus

    func testStampPathIsPerEvent() {
        let directory = URL(fileURLWithPath: "/tmp/atoll-test/run", isDirectory: true)
        let a = SoundFallback.stampURL(for: .decisionNeeded, in: directory)
        let b = SoundFallback.stampURL(for: .taskCompleted, in: directory)
        XCTAssertNotEqual(a, b)
        // Deux événements qui se coupent l'un l'autre, c'est exactement ce que
        // l'app évite déjà avec un cache par (événement, son).
        XCTAssertTrue(a.lastPathComponent.contains("decisionNeeded"))
    }

    func testThrottleUsesTheSameWindowAsTheApp() {
        let now = Date()
        XCTAssertTrue(SoundFallback.shouldPlay(stampDate: nil, now: now))
        XCTAssertFalse(SoundFallback.shouldPlay(stampDate: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(SoundFallback.shouldPlay(
            stampDate: now.addingTimeInterval(-SoundThrottle.minimumInterval - 0.1), now: now))
    }

    /// Une horloge qui recule (veille, changement d'heure) ne doit pas rendre
    /// muet pour toujours — même règle que `SoundThrottle`.
    func testClockGoingBackwardsStillRings() {
        let now = Date()
        XCTAssertTrue(SoundFallback.shouldPlay(stampDate: now.addingTimeInterval(3600), now: now))
    }
}
