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

    /// Fichier ABSENT : rien à parquer, et surtout aucune erreur (machine neuve).
    func testParkOnMissingSettingsIsNoOp() throws {
        XCTAssertNil(try SoundHookEditor.park(in: nil))
    }

    /// Fichier PRÉSENT mais vide : ce test affirmait un no-op, et c'était le
    /// défaut lui-même. Un `settings.json` de 0 octet n'est pas une
    /// configuration vide, c'est une troncature attrapée en vol — trois
    /// écrivains se partagent ce fichier. Le traiter comme « rien à faire »
    /// laissait le chemin d'écriture reposer un fichier ne contenant que nos
    /// entrées, et la configuration de l'utilisateur disparaissait en silence.
    /// On refuse désormais, comme pour tout JSON illisible.
    func testParkOnBlankSettingsIsRefused() {
        XCTAssertThrowsError(try SoundHookEditor.park(in: Data())) {
            XCTAssertEqual($0 as? SoundHookEditor.EditorError, .unparseableSettings)
        }
        XCTAssertThrowsError(try SoundHookEditor.park(in: Data("  \n ".utf8)))
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

    /// …mais les cas légitimes restent reconnus. Un `&` FINAL met le son en
    /// tâche de fond, et une REDIRECTION en contient un sans rien enchaîner :
    /// la première version de la garde rejetait `2>&1 &`, idiome courant, et
    /// l'utilisateur ne pouvait plus confier ce hook (revue des corrections).
    func testBackgroundAndRedirectionsAreStillSoundCommands() {
        for command in [
            "afplay -v 0.1 ~/done.wav &",
            "afplay -v 0.1 $HOME/.claude/song/finish.mp3 >/dev/null 2>&1 &",
            "afplay ~/done.wav &>/dev/null",
            "afplay ~/done.wav\n",
            "afplay '~/mon son & co.wav'",
        ] {
            XCTAssertTrue(SoundHookEditor.isSoundCommand(command), "devrait être reconnu : \(command)")
        }
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

    /// Le marqueur d'engagement doit distinguer TROIS états, sinon la reprise
    /// après crash ne se fait jamais (revue des corrections, 2026-07-27) :
    /// clé absente = version antérieure (engagée), `null` = parking interrompu,
    /// date = parking terminé.
    func testCommittedAtDistinguishesInterruptedFromLegacy() throws {
        let hook = SoundHookEditor.ParkedHook(event: "Stop", matcher: "", index: 0,
                                              command: "afplay a.mp3",
                                              hookJSON: #"{"command":"afplay a.mp3","type":"command"}"#)
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)

        // 1. Parking EN COURS : `committedAt` nil doit survivre à l'aller-retour.
        let encours = SoundHookEditor.ParkedSoundHooks(hooks: [hook], parkedAt: stamp)
        let relu = SoundHookEditor.decodeParked(try SoundHookEditor.encodeParked(encours))
        XCTAssertNil(relu?.committedAt, "un parking interrompu doit se relire interrompu")

        // 2. Parking TERMINÉ.
        let fini = SoundHookEditor.ParkedSoundHooks(hooks: [hook], parkedAt: stamp, committedAt: stamp)
        XCTAssertNotNil(SoundHookEditor.decodeParked(try SoundHookEditor.encodeParked(fini))?.committedAt)

        // 3. Fichier d'une version ANTÉRIEURE (aucune clé) : considéré engagé,
        //    sinon Atoll re-parquerait au prochain lancement.
        let ancien = Data(#"{"hooks":[],"parkedAt":"2026-07-27T12:09:27Z"}"#.utf8)
        XCTAssertNotNil(SoundHookEditor.decodeParked(ancien)?.committedAt)
    }
    // MARK: - A07 : le groupe est l'unité de restitution

    private let sameSound: [String: Any] = [
        "type": "command", "command": "afplay /fixture/finish.wav", "timeout": 4,
        "future": ["volume": 0.3]
    ]

    private func settingsWithGroups(_ groups: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "hooks": ["PreToolUse": groups], "futureRoot": ["preserve": true]
        ], options: [.sortedKeys])
    }

    private func group(matcher: String? = "Bash", description: String? = nil,
                       entries: [[String: Any]]) -> [String: Any] {
        var result: [String: Any] = ["hooks": entries]
        if let matcher { result["matcher"] = matcher }
        if let description { result["description"] = description }
        return result
    }

    private func assertSameSettings(_ actual: Data, _ expected: Data,
                                    _ message: String = "", file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        XCTAssertEqual(try JSONSerialization.jsonObject(with: actual) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: expected) as? NSDictionary,
                       message, file: file, line: line)
    }

    /// Sans restitution manuelle, partielle (dans les deux sens) ou complète,
    /// chaque matcher récupère son exemplaire ; l'ordre du parking est sans effet.
    func testA07PartialManualRestorationKeepsOriginalMatchers() throws {
        for matchers in [["Bash", "Edit"], ["Edit", "Bash"]] {
            let groups = matchers.map { group(matcher: $0, entries: [sameSound]) }
            let original = try settingsWithGroups(groups)
            let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
            for mask in 0..<4 {
                let current = try settingsWithGroups(groups.enumerated().compactMap {
                    mask & (1 << $0.offset) == 0 ? nil : $0.element
                })
                for reverse in [false, true] {
                    let records = reverse ? Array(parking.parked.reversed()) : parking.parked
                    let restored = try SoundHookEditor.restore(into: current, parked: records)
                    try assertSameSettings(restored, original, "A07 matcher mask=\(mask), reverse=\(reverse)")
                    try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: records), original)
                }
            }
        }
    }

    func testA07SameMatcherKeepsUnknownGroupMetadata() throws {
        let groups = ["first", "second"].map { (name: String) in
            group(description: name, entries: [sameSound])
        }
        let original = try settingsWithGroups(groups)
        let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
        for mask in 0..<4 {
            let current = try settingsWithGroups(groups.enumerated().compactMap {
                mask & (1 << $0.offset) == 0 ? nil : $0.element
            })
            let restored = try SoundHookEditor.restore(into: current, parked: parking.parked)
            try assertSameSettings(restored, original, "A07 metadata mask=\(mask)")
            try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: parking.parked), original)
        }
    }

    func testA07PartialWholeGroupRestorationDoesNotDuplicatePresentSound() throws {
        let other: [String: Any] = ["type": "command", "command": "afplay /fixture/other.wav"]
        let original = try settingsWithGroups([group(description: "two sounds", entries: [sameSound, other])])
        let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
        for remaining in [[sameSound], [other], [sameSound, other], []] {
            let current = try settingsWithGroups([group(description: "two sounds", entries: remaining)])
            let restored = try SoundHookEditor.restore(into: current, parked: Array(parking.parked.reversed()))
            try assertSameSettings(restored, original, "A07 partial whole group")
            try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: parking.parked), original)
        }
    }

    func testA07KeepsIdenticalGroupsAndDuplicateEntriesWithinGroup() throws {
        let duplicate = group(entries: [sameSound, sameSound])
        let original = try settingsWithGroups([duplicate, duplicate])
        let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
        for currentGroups in [[], [duplicate], [duplicate, duplicate], [group(entries: [sameSound])]] {
            let current = try settingsWithGroups(currentGroups)
            let restored = try SoundHookEditor.restore(into: current, parked: parking.parked)
            try assertSameSettings(restored, original, "A07 legitimate duplicates")
            try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: parking.parked), original)
        }
    }

    func testA07MixedGroupsKeepMetadataAndThirdPartyOrder() throws {
        let groups = ["first", "second"].map { (name: String) in
            group(description: name, entries: [
                ["type": "command", "command": "node before-\(name).js"], sameSound,
                ["type": "command", "command": "node after-\(name).js"]
            ])
        }
        let original = try settingsWithGroups(groups)
        let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
        for mask in 0..<4 {
            let current = try settingsWithGroups(groups.enumerated().map { index, original in
                var value = original
                if mask & (1 << index) == 0 {
                    value["hooks"] = (original["hooks"] as! [[String: Any]]).filter {
                        $0["command"] as? String != sameSound["command"] as? String
                    }
                }
                return value
            })
            let restored = try SoundHookEditor.restore(into: current, parked: Array(parking.parked.reversed()))
            try assertSameSettings(restored, original, "A07 mixed mask=\(mask)")
            try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: parking.parked), original)
        }
    }

    func testA07MixedGroupsWithSameMetadataUseSurvivingThirdPartyHooks() throws {
        let third: [String: Any] = ["type": "command", "command": "node keep.js"]
        let groups = [group(entries: [sameSound]), group(entries: [sameSound, third])]
        let original = try settingsWithGroups(groups)
        let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
        for current in [parking.updated, try settingsWithGroups([groups[1]])] {
            let restored = try SoundHookEditor.restore(into: current, parked: parking.parked)
            try assertSameSettings(restored, original, "A07 shifted mixed group")
            try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: parking.parked), original)
        }
    }

    func testA07RemovedMixedGroupDoesNotResurrectThirdPartyHooks() throws {
        let original = try settingsWithGroups([group(description: "retained context", entries: [
            sameSound, ["type": "command", "command": "node manually-removed.js"]
        ])])
        let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
        let restored = try SoundHookEditor.restore(into: try settingsWithGroups([]), parked: parking.parked)
        try assertSameSettings(restored, try settingsWithGroups([
            group(description: "retained context", entries: [sameSound])
        ]), "A07 missing mixed context")
    }

    func testA07RestoreAfterAtollReinstallKeepsOnlyCurrentManagedHook() throws {
        let original = try settingsWithGroups([group(description: "my sound", entries: [
            sameSound, ["type": "command", "command": "/old/.atoll/bin/atoll-bridge"]
        ])])
        let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
        let installed = try HookSettingsEditor.install(into: parking.updated, command: "/new/.atoll/bin/atoll-bridge")
        let restored = try SoundHookEditor.restore(into: installed, parked: parking.parked)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: restored) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let commands = groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
        XCTAssertEqual(commands, ["afplay /fixture/finish.wav", "/new/.atoll/bin/atoll-bridge"])
        XCTAssertEqual(groups.first?["description"] as? String, "my sound")
        try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: parking.parked), restored)
    }

    func testA07LegacyParkingWithoutGroupContextStillRestores() throws {
        let data = Data(#"{"hooks":[{"event":"PreToolUse","matcher":"Bash","index":0,"command":"afplay /fixture/legacy.wav","hookJSON":"{\"type\":\"command\",\"command\":\"afplay /fixture/legacy.wav\"}"}],"parkedAt":"2026-07-27T12:09:27Z"}"#.utf8)
        let parking = try XCTUnwrap(SoundHookEditor.decodeParked(data))
        let current = try settingsWithGroups([group(entries: [["type": "command", "command": "node third.js"]])])
        let restored = try SoundHookEditor.restore(into: current, parked: parking.hooks)
        let expected = try settingsWithGroups([group(entries: [
            ["type": "command", "command": "afplay /fixture/legacy.wav"],
            ["type": "command", "command": "node third.js"]
        ])])
        try assertSameSettings(restored, expected)
        try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: parking.hooks), expected)
    }

    func testA07InvalidParkingFragmentRefusesSuccessfulRestoration() throws {
        for (hookJSON, groupJSON) in [("invalid", nil), ("{}", "invalid"), ("{}", "{}"), ("{}", #"{"hooks":42}"#)] as [(String, String?)] {
            let invalid = SoundHookEditor.ParkedHook(event: "PreToolUse", matcher: "Bash", index: 0,
                command: "afplay /fixture/finish.wav", hookJSON: hookJSON, groupJSON: groupJSON)
            XCTAssertThrowsError(try SoundHookEditor.restore(into: try settingsWithGroups([]), parked: [invalid])) {
                XCTAssertEqual($0 as? SoundHookEditor.EditorError, .unparseableParking)
            }
        }
    }

    func testA07GroupsSharingOnlySomeSoundsStaySeparate() throws {
        let b: [String: Any] = ["type": "command", "command": "afplay /fixture/b.wav"]
        let c: [String: Any] = ["type": "command", "command": "afplay /fixture/c.wav"]
        for entries in [[[sameSound, b], [sameSound, c]], [[sameSound, b, c], [sameSound, b]]] {
            let groups = entries.map { group(entries: $0) }
            let original = try settingsWithGroups(groups)
            let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
            for mask in 0..<4 {
                let current = try settingsWithGroups(groups.enumerated().compactMap {
                    mask & (1 << $0.offset) == 0 ? nil : $0.element
                })
                let restored = try SoundHookEditor.restore(into: current, parked: parking.parked)
                try assertSameSettings(restored, original, "A07 overlapping sounds mask=\(mask)")
                try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: parking.parked), original)
            }
        }
    }

    func testA07MergeParkingKeepsNewGroupContextAndMultiplicity() throws {
        // Le premier groupe a disparu des settings après parking : seul le
        // nouveau contexte est parqué cette fois, sans remettre l'ancien.
        let firstGroup = group(description: "first", entries: [sameSound])
        let secondGroup = group(description: "second", entries: [sameSound])
        let firstParking = try XCTUnwrap(try SoundHookEditor.park(in: try settingsWithGroups([firstGroup])))
        let secondParking = try XCTUnwrap(try SoundHookEditor.park(in: try settingsWithGroups([secondGroup])))
        let bothContexts = SoundHookEditor.mergeParked(previous: firstParking.parked, new: secondParking.parked)
        XCTAssertEqual(bothContexts.count, 2, "A07 merge context without old group")
        let bothRestored = try SoundHookEditor.restore(into: secondParking.updated, parked: bothContexts)
        try assertSameSettings(bothRestored, try settingsWithGroups([secondGroup, firstGroup]))
        try assertSameSettings(try SoundHookEditor.restore(into: bothRestored, parked: bothContexts), bothRestored)

        let third: [String: Any] = ["type": "command", "command": "node keep.js"]
        for groups in [
            [group(description: "first", entries: [sameSound]), group(description: "second", entries: [sameSound])],
            [group(entries: [sameSound]), group(entries: [sameSound])],
            [group(entries: [sameSound, third]), group(entries: [sameSound, ["type": "command", "command": "node other.js"]])]
        ] {
            let first = try XCTUnwrap(try SoundHookEditor.park(in: try settingsWithGroups([groups[0]])))
            let both = try XCTUnwrap(try SoundHookEditor.park(in: try settingsWithGroups(groups)))
            let merged = SoundHookEditor.mergeParked(previous: first.parked, new: both.parked)
            XCTAssertEqual(merged.count, 2, "A07 merge multiplicity/context")
            XCTAssertEqual(SoundHookEditor.mergeParked(previous: merged, new: both.parked), merged)
            let restored = try SoundHookEditor.restore(into: both.updated, parked: merged)
            try assertSameSettings(restored, try settingsWithGroups(groups), "A07 merge restores both groups")
        }
    }

    func testA07RepeatedParkingAfterPartialRestorationDoesNotDuplicate() throws {
        let other: [String: Any] = ["type": "command", "command": "afplay /fixture/other.wav"]
        for third in [[], [["type": "command", "command": "node keep.js"]]] {
            let original = try settingsWithGroups([group(entries: [sameSound, other] + third)])
            let first = try XCTUnwrap(try SoundHookEditor.park(in: original))
            let partial = try settingsWithGroups([group(entries: [sameSound] + third)])
            let second = try XCTUnwrap(try SoundHookEditor.park(in: partial))
            let merged = SoundHookEditor.mergeParked(previous: first.parked, new: second.parked)
            XCTAssertEqual(merged, first.parked, "A07 partial re-parking")
            try assertSameSettings(try SoundHookEditor.restore(into: second.updated, parked: merged), original)
        }
    }

    func testA07LegacyParkingMergeStillConsumesOnlyOneOccurrence() throws {
        let current = try settingsWithGroups([group(entries: [sameSound]), group(entries: [sameSound])])
        let parked = try XCTUnwrap(try SoundHookEditor.park(in: current))
        let first = parked.parked[0]
        let legacy = SoundHookEditor.ParkedHook(event: first.event, matcher: first.matcher, index: first.index,
                                               command: first.command, hookJSON: first.hookJSON)
        let merged = SoundHookEditor.mergeParked(previous: [legacy], new: parked.parked)
        XCTAssertEqual(merged.count, 2, "A07 legacy merge multiplicity")
        XCTAssertEqual(SoundHookEditor.mergeParked(previous: merged, new: parked.parked), merged)
        try assertSameSettings(try SoundHookEditor.restore(into: parked.updated, parked: merged), current)
    }

    func testA07MergeNewSoundWithinSameGroupKeepsOneGroup() throws {
        let other: [String: Any] = ["type": "command", "command": "afplay /fixture/other.wav"]
        let third: [String: Any] = ["type": "command", "command": "node keep.js"]
        for (initial, added, expected) in [
            ([sameSound], [sameSound, sameSound], [sameSound, sameSound]),
            ([sameSound], [sameSound, other], [sameSound, other]),
            ([sameSound, third], [other, third], [sameSound, other, third])
        ] {
            let first = try XCTUnwrap(try SoundHookEditor.park(in: try settingsWithGroups([group(entries: initial)])))
            let second = try XCTUnwrap(try SoundHookEditor.park(in: try settingsWithGroups([group(entries: added)])))
            let merged = SoundHookEditor.mergeParked(previous: first.parked, new: second.parked)
            let restored = try SoundHookEditor.restore(into: second.updated, parked: merged)
            let wanted = try settingsWithGroups([group(entries: expected)])
            try assertSameSettings(restored, wanted, "A07 merge within one group")
            try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: merged), wanted)
        }
    }

    func testA07SharedAnchorDoesNotAbsorbDifferentMixedGroup() throws {
        let common: [String: Any] = ["type": "command", "command": "node common.js"]
        let x: [String: Any] = ["type": "command", "command": "node x.js"]
        let y: [String: Any] = ["type": "command", "command": "node y.js"]
        let other: [String: Any] = ["type": "command", "command": "afplay /fixture/other.wav"]
        let original = try settingsWithGroups([
            group(entries: [sameSound, common, x]), group(entries: [other, common, y])
        ])
        let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
        let current = try settingsWithGroups([group(entries: [common, y])])
        let restored = try SoundHookEditor.restore(into: current, parked: parking.parked)
        let expected = try settingsWithGroups([
            group(entries: [sameSound]), group(entries: [other, common, y])
        ])
        try assertSameSettings(restored, expected, "A07 shared anchor")
        try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: parking.parked), expected)
    }

    func testA07PartialMixedGroupWithForeignSoundIsNotConsumed() throws {
        let third: [String: Any] = ["type": "command", "command": "node keep.js"]
        let b: [String: Any] = ["type": "command", "command": "afplay /fixture/b.wav"]
        let c: [String: Any] = ["type": "command", "command": "afplay /fixture/c.wav"]
        let original = try settingsWithGroups([
            group(entries: [sameSound, third]), group(entries: [sameSound, b, c, third])
        ])
        let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
        let current = try settingsWithGroups([group(entries: [sameSound, b, third])])
        let restored = try SoundHookEditor.restore(into: current, parked: parking.parked)
        let expected = try settingsWithGroups([
            group(entries: [sameSound]), group(entries: [sameSound, b, c, third])
        ])
        try assertSameSettings(restored, expected, "A07 foreign sound in mixed group")
        try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: parking.parked), expected)
    }

    func testA07ExactMixedGroupIsReservedBeforeSoundSubset() throws {
        let third: [String: Any] = ["type": "command", "command": "node keep.js"]
        let other: [String: Any] = ["type": "command", "command": "afplay /fixture/other.wav"]
        let groups = [group(entries: [sameSound, other, third]), group(entries: [sameSound, third])]
        let original = try settingsWithGroups(groups)
        let parking = try XCTUnwrap(try SoundHookEditor.park(in: original))
        let current = try settingsWithGroups([groups[1]])
        let restored = try SoundHookEditor.restore(into: current, parked: parking.parked)
        let expected = try settingsWithGroups([group(entries: [sameSound, other]), groups[1]])
        try assertSameSettings(restored, expected, "A07 reserve exact mixed group")
        try assertSameSettings(try SoundHookEditor.restore(into: restored, parked: parking.parked), expected)
    }

}
