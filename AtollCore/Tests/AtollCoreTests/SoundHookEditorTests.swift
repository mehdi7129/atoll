import XCTest
@testable import AtollCore

final class SoundHookEditorTests: XCTestCase {

    /// La configuration RÉELLE de l'utilisateur (relevée le 2026-07-27) : deux
    /// hooks `afplay`, chacun dans son propre groupe `matcher: ""`, cohabitant
    /// avec les hooks Atoll et ses hooks GSD.
    private let realSettings = """
    {
      "hooks": {
        "Notification": [
          { "hooks": [ { "command": "afplay -v 0.1 '/Users/m/.claude/song/need-human.mp3'", "type": "command" } ], "matcher": "" },
          { "hooks": [ { "async": true, "command": "\\"$HOME/.atoll/bin/atoll-bridge\\"", "timeout": 10, "type": "command" } ] }
        ],
        "PreToolUse": [
          { "hooks": [ { "command": "node \\"/Users/m/.claude/hooks/gsd-prompt-guard.js\\"", "type": "command" } ], "matcher": "" }
        ],
        "Stop": [
          { "hooks": [ { "command": "afplay -v 0.1 '/Users/m/.claude/song/finish.mp3'", "type": "command" } ], "matcher": "" },
          { "hooks": [ { "async": true, "command": "\\"$HOME/.atoll/bin/atoll-bridge\\"", "timeout": 10, "type": "command" } ] }
        ]
      },
      "statusLine": { "command": "custom" }
    }
    """.data(using: .utf8)!

    // MARK: - Détection

    func testDetectsAfplayCommands() {
        XCTAssertTrue(SoundHookEditor.isSoundCommand("afplay -v 0.1 '/x/finish.mp3'"))
        XCTAssertTrue(SoundHookEditor.isSoundCommand("afplay /System/Library/Sounds/Glass.aiff"))
        XCTAssertTrue(SoundHookEditor.isSoundCommand("say 'terminé'"))
        XCTAssertTrue(SoundHookEditor.isSoundCommand("osascript -e beep"))
    }

    /// Un faux positif RETIRERAIT un hook qui fait autre chose : bien pire
    /// qu'un son en trop. Ces commandes-là doivent rester intouchées.
    func testDoesNotDetectNonSoundHooks() {
        XCTAssertFalse(SoundHookEditor.isSoundCommand("node \"/Users/m/.claude/hooks/gsd-prompt-guard.js\""))
        XCTAssertFalse(SoundHookEditor.isSoundCommand("bun /Users/m/.claude/scripts/command-validator/src/cli.ts"))
        XCTAssertFalse(SoundHookEditor.isSoundCommand("\"$HOME/.atoll/bin/atoll-bridge\""))
        XCTAssertFalse(SoundHookEditor.isSoundCommand("essayer.sh --dry-run"))
        XCTAssertFalse(SoundHookEditor.isSoundCommand("python3 analyse.py"))
    }

    /// Un hook Atoll ne joue aucun son — même si son chemin contenait un mot
    /// piégeux, il ne doit jamais être parqué.
    func testNeverDetectsAtollHooks() {
        XCTAssertFalse(SoundHookEditor.isSoundCommand("\"$HOME/.atoll/bin/atoll-bridge\" --sound say"))
    }

    func testExtractsAudioPathsForReuse() {
        XCTAssertEqual(
            SoundHookEditor.audioPaths(in: "afplay -v 0.1 '/Users/m/.claude/song/finish.mp3'"),
            ["/Users/m/.claude/song/finish.mp3"])
        XCTAssertEqual(
            SoundHookEditor.audioPaths(in: "afplay \"/a/b/Mon Son.wav\""),
            ["/a/b/Mon Son.wav"])
        XCTAssertTrue(SoundHookEditor.audioPaths(in: "node script.js").isEmpty)
    }

    func testListsSoundHooksInStableOrder() {
        let hooks = SoundHookEditor.soundHooks(in: realSettings)
        XCTAssertEqual(hooks.map(\.event), ["Notification", "Stop"])
        XCTAssertEqual(hooks.map(\.matcher), ["", ""])
        XCTAssertTrue(hooks[0].command.contains("need-human.mp3"))
        XCTAssertTrue(hooks[1].command.contains("finish.mp3"))
    }

    // MARK: - Parking

    func testParkRemovesOnlySoundHooks() throws {
        let result = try SoundHookEditor.park(in: realSettings)
        let parked = try XCTUnwrap(result)
        XCTAssertEqual(parked.parked.count, 2)

        let after = try JSONSerialization.jsonObject(with: parked.updated) as! [String: Any]
        let hooks = after["hooks"] as! [String: Any]

        // Les hooks Atoll et GSD sont intacts.
        XCTAssertEqual((hooks["PreToolUse"] as! [[String: Any]]).count, 1)
        let stop = hooks["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 1)
        let remaining = (stop[0]["hooks"] as! [[String: Any]])[0]["command"] as! String
        XCTAssertTrue(remaining.contains("atoll-bridge"))

        // Le reste du fichier est préservé.
        XCTAssertNotNil(after["statusLine"])
    }

    func testParkReturnsNilWhenNoSoundHooks() throws {
        let clean = """
        {"hooks":{"Stop":[{"hooks":[{"command":"\\"$HOME/.atoll/bin/atoll-bridge\\"","type":"command"}]}]}}
        """.data(using: .utf8)!
        XCTAssertNil(try SoundHookEditor.park(in: clean))
    }

    func testParkRejectsUnparseableSettingsWithoutWriting() {
        XCTAssertThrowsError(try SoundHookEditor.park(in: "pas du json".data(using: .utf8)!))
        XCTAssertThrowsError(try SoundHookEditor.park(in: #"{"hooks": "oups"}"#.data(using: .utf8)!))
    }

    func testParkOnEmptySettingsIsNoOp() throws {
        XCTAssertNil(try SoundHookEditor.park(in: nil))
        XCTAssertNil(try SoundHookEditor.park(in: Data()))
    }

    // MARK: - Restitution (le critère qui compte)

    /// LE test du chantier : ce qu'Atoll retire, Atoll sait le remettre — même
    /// événement, même matcher, même position, mêmes champs.
    func testParkThenRestoreYieldsIdenticalSettings() throws {
        let before = try JSONSerialization.jsonObject(with: realSettings) as! [String: Any]
        let parked = try XCTUnwrap(try SoundHookEditor.park(in: realSettings))
        let restored = try SoundHookEditor.restore(into: parked.updated, parked: parked.parked)
        let after = try JSONSerialization.jsonObject(with: restored) as! [String: Any]

        XCTAssertEqual(NSDictionary(dictionary: before), NSDictionary(dictionary: after))
    }

    func testRestoreIsIdempotent() throws {
        let parked = try XCTUnwrap(try SoundHookEditor.park(in: realSettings))
        let once = try SoundHookEditor.restore(into: parked.updated, parked: parked.parked)
        let twice = try SoundHookEditor.restore(into: once, parked: parked.parked)
        XCTAssertEqual(NSDictionary(dictionary: try JSONSerialization.jsonObject(with: once) as! [String: Any]),
                       NSDictionary(dictionary: try JSONSerialization.jsonObject(with: twice) as! [String: Any]))
    }

    /// L'utilisateur a remis son hook à la main pendant le parking : ne pas le
    /// dupliquer à la restitution.
    func testRestoreDoesNotDuplicateManuallyReaddedHook() throws {
        let parked = try XCTUnwrap(try SoundHookEditor.park(in: realSettings))
        let restored = try SoundHookEditor.restore(into: realSettings, parked: parked.parked)
        let after = try JSONSerialization.jsonObject(with: restored) as! [String: Any]
        let stop = (after["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2)
    }

    /// Atoll désinstallé puis settings.json vidé entre-temps : la restitution
    /// recrée l'événement plutôt que d'abandonner le hook.
    func testRestoreIntoEmptySettingsRecreatesEvents() throws {
        let parked = try XCTUnwrap(try SoundHookEditor.park(in: realSettings))
        let restored = try SoundHookEditor.restore(into: nil, parked: parked.parked)
        let after = try JSONSerialization.jsonObject(with: restored) as! [String: Any]
        let hooks = after["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNotNil(hooks["Notification"])
    }

    func testMergeParkedAvoidsDuplicates() {
        let a = SoundHookEditor.ParkedHook(event: "Stop", matcher: "", index: 0,
                                           command: "afplay a.mp3",
                                           hookJSON: #"{"command":"afplay a.mp3","type":"command"}"#)
        let b = SoundHookEditor.ParkedHook(event: "Stop", matcher: "", index: 1,
                                           command: "afplay b.mp3",
                                           hookJSON: #"{"command":"afplay b.mp3","type":"command"}"#)
        XCTAssertEqual(SoundHookEditor.mergeParked(previous: [a], new: [a, b]).count, 2)
        XCTAssertEqual(SoundHookEditor.mergeParked(previous: [a], new: [a]).count, 1)
    }

    /// Le défaut (audit du 2026-07-27) : la clé de fusion ne portait que sur la
    /// COMMANDE. Une entrée re-posée avec un autre matcher ou d'autres options
    /// était donc retirée de settings.json ET jetée du parking — perdue.
    func testMergeParkedKeepsSameCommandWithDifferentMatcher() {
        let ancien = SoundHookEditor.ParkedHook(event: "Stop", matcher: "", index: 0,
                                                command: "afplay done.wav",
                                                hookJSON: #"{"command":"afplay done.wav","type":"command"}"#)
        let nouveau = SoundHookEditor.ParkedHook(event: "Stop", matcher: "*", index: 0,
                                                 command: "afplay done.wav",
                                                 hookJSON: #"{"command":"afplay done.wav","timeout":3,"type":"command"}"#)
        let fusion = SoundHookEditor.mergeParked(previous: [ancien], new: [nouveau])
        XCTAssertEqual(fusion.count, 2, "les deux entrées doivent rester restituables")
    }

    /// Un hook qui joue un son ET fait autre chose ne doit JAMAIS être parqué :
    /// la granularité du parking est l'entrée entière, on supprimerait le reste.
    func testCompoundCommandsAreNeverParked() {
        for command in [
            "afplay -v 0.1 ~/done.wav\ngit -C ~/notes commit -am autosave",  // saut de ligne
            "afplay ~/done.wav & node ~/notify.js",                          // & isolé
            "afplay ~/done.wav && ./deploy.sh",
            "./on-stop.sh; afplay ~/done.wav",
        ] {
            XCTAssertFalse(SoundHookEditor.isSoundCommand(command), "ne doit pas être parqué : \(command)")
        }
    }

    /// …mais le cas légitime « joue le son en tâche de fond » reste reconnu.
    func testTrailingAmpersandIsStillASoundCommand() {
        XCTAssertTrue(SoundHookEditor.isSoundCommand("afplay -v 0.1 ~/done.wav &"))
    }

    // MARK: - Fichier de parking

    func testParkedFileRoundTrips() throws {
        let parked = try XCTUnwrap(try SoundHookEditor.park(in: realSettings))
        let file = SoundHookEditor.ParkedSoundHooks(hooks: parked.parked,
                                                    parkedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try SoundHookEditor.encodeParked(file)
        XCTAssertEqual(SoundHookEditor.decodeParked(data), file)
    }

    func testDecodeParkedRejectsGarbage() {
        XCTAssertNil(SoundHookEditor.decodeParked("pas du json".data(using: .utf8)!))
    }

    // MARK: - Faux positifs (trouvés en revue adversariale, tous MESURÉS)

    /// La granularité du parking est l'entrée de hook ENTIÈRE : parquer une
    /// commande composée arrêterait aussi ce qu'elle fait d'autre.
    func testNeverParksCompoundCommands() {
        XCTAssertFalse(SoundHookEditor.isSoundCommand(
            "\"$CLAUDE_PROJECT_DIR/scripts/on-stop.sh\" && afplay -v 0.1 ~/sounds/done.wav"))
        XCTAssertFalse(SoundHookEditor.isSoundCommand("afplay a.mp3; rm -f /tmp/x"))
        XCTAssertFalse(SoundHookEditor.isSoundCommand("cat x | say"))
    }

    /// Un mot sonore dans un ARGUMENT n'est pas une commande sonore.
    func testDoesNotParkSoundWordsInsideArguments() {
        for command in [
            "curl -s https://example.com/beep-api",
            "node \"/Users/m/.claude/hooks/say-hello.js\"",
            "node /Users/m/.claude/hooks/gsd-say-status.js",
            "bun ~/.claude/scripts/voice/transcribe.ts --keep /tmp/last-prompt.m4a",
            "python3 ~/.claude/hooks/archive.py --pattern '*.wav'",
        ] {
            XCTAssertFalse(SoundHookEditor.isSoundCommand(command), command)
        }
    }

    func testStillDetectsRealSoundCommands() {
        XCTAssertTrue(SoundHookEditor.isSoundCommand("afplay -v 0.1 '/Users/m/song/finish.mp3'"))
        XCTAssertTrue(SoundHookEditor.isSoundCommand("/usr/bin/afplay x.aiff"))
        XCTAssertTrue(SoundHookEditor.isSoundCommand("say 'terminé'"))
        XCTAssertTrue(SoundHookEditor.isSoundCommand("osascript -e beep"))
        XCTAssertTrue(SoundHookEditor.isSoundCommand("mpv /System/Library/Sounds/Glass.aiff"))
    }

    func testExpandsHomeInAudioPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(SoundHookEditor.audioPaths(in: "afplay \"$HOME/song/finish.mp3\""),
                       ["\(home)/song/finish.mp3"])
        XCTAssertEqual(SoundHookEditor.audioPaths(in: "afplay ~/song/finish.mp3"),
                       ["\(home)/song/finish.mp3"])
    }

    // MARK: - Sûreté de la restitution (perte de données évitée)

    /// Un événement d'une forme inattendue ne doit JAMAIS être remplacé par nos
    /// seuls groupes : les hooks que l'utilisateur y a mis disparaîtraient.
    func testRestoreRefusesToOverwriteMalformedEvent() throws {
        let parked = try XCTUnwrap(try SoundHookEditor.park(in: realSettings))
        let corrupted = #"{"hooks":{"Stop":{"forme":"inattendue"}}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try SoundHookEditor.restore(into: corrupted, parked: parked.parked))
    }

    /// Deux entrées à la commande IDENTIQUE (matchers différents) : les deux
    /// doivent revenir, pas une seule.
    func testRestoresBothIdenticalCommands() throws {
        let settings = """
        {"hooks":{"PreToolUse":[
          {"matcher":"Bash","hooks":[{"command":"afplay /System/Library/Sounds/Tink.aiff","type":"command"}]},
          {"matcher":"Edit","hooks":[{"command":"afplay /System/Library/Sounds/Tink.aiff","type":"command"}]}
        ]}}
        """.data(using: .utf8)!
        let parked = try XCTUnwrap(try SoundHookEditor.park(in: settings))
        XCTAssertEqual(parked.parked.count, 2)
        let restored = try SoundHookEditor.restore(into: parked.updated, parked: parked.parked)
        let after = try JSONSerialization.jsonObject(with: restored) as! [String: Any]
        let groups = (after["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.compactMap { $0["matcher"] as? String }), ["Bash", "Edit"])
    }

    /// Groupe MIXTE : le hook sonore doit revenir DANS son groupe, pas dans un
    /// groupe jumeau créé à côté.
    func testRestoresIntoMixedGroupWithoutCreatingATwin() throws {
        let settings = """
        {"hooks":{"Stop":[{"matcher":"","hooks":[
          {"command":"afplay /System/Library/Sounds/Glass.aiff","type":"command"},
          {"command":"node gsd-stop.js","type":"command"}
        ]}]}}
        """.data(using: .utf8)!
        let before = try JSONSerialization.jsonObject(with: settings) as! [String: Any]
        let parked = try XCTUnwrap(try SoundHookEditor.park(in: settings))
        let restored = try SoundHookEditor.restore(into: parked.updated, parked: parked.parked)
        let after = try JSONSerialization.jsonObject(with: restored) as! [String: Any]
        XCTAssertEqual(NSDictionary(dictionary: before), NSDictionary(dictionary: after))
    }

    /// Un groupe entièrement sonore emporte ses clés inconnues : il doit revenir
    /// AVEC elles.
    func testRestorePreservesUnknownGroupKeys() throws {
        let settings = """
        {"hooks":{"Stop":[{"matcher":"","description":"mon son","hooks":[
          {"command":"afplay /System/Library/Sounds/Glass.aiff","type":"command"}
        ]}]}}
        """.data(using: .utf8)!
        let before = try JSONSerialization.jsonObject(with: settings) as! [String: Any]
        let parked = try XCTUnwrap(try SoundHookEditor.park(in: settings))
        let restored = try SoundHookEditor.restore(into: parked.updated, parked: parked.parked)
        let after = try JSONSerialization.jsonObject(with: restored) as! [String: Any]
        XCTAssertEqual(NSDictionary(dictionary: before), NSDictionary(dictionary: after))
    }

    /// Un groupe vide PRÉEXISTANT n'est pas à nous : ne pas l'effacer (on ne
    /// saurait pas le rendre).
    func testParkKeepsPreexistingEmptyGroups() throws {
        let settings = """
        {"hooks":{"Stop":[
          {"matcher":"garde-place","hooks":[]},
          {"matcher":"","hooks":[{"command":"afplay /System/Library/Sounds/Glass.aiff","type":"command"}]}
        ]}}
        """.data(using: .utf8)!
        let parked = try XCTUnwrap(try SoundHookEditor.park(in: settings))
        let after = try JSONSerialization.jsonObject(with: parked.updated) as! [String: Any]
        let groups = (after["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["matcher"] as? String, "garde-place")
    }
}
