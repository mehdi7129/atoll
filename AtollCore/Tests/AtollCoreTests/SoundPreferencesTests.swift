import XCTest
@testable import AtollCore

final class SoundPreferencesTests: XCTestCase {

    // MARK: - Encodage/décodage du choix

    func testRoundTripsEveryChoice() {
        for choice in [SoundChoice.silent, .system("Glass"), .custom("finish.mp3")] {
            XCTAssertEqual(SoundChoice.decode(choice.storageValue), choice)
        }
    }

    func testDecodesUnknownValuesAsSilent() {
        for raw in [nil, "", "n'importe quoi", "system", "custom:", "SYSTEM:Glass"] {
            XCTAssertEqual(SoundChoice.decode(raw), .silent, "raw=\(raw ?? "nil")")
        }
    }

    /// La valeur vient d'UserDefaults et sert à CONSTRUIRE UN CHEMIN : un
    /// réglage trafiqué ne doit jamais pouvoir désigner un fichier arbitraire.
    func testRejectsPathTraversalAndSeparators() {
        for hostile in ["custom:../../../etc/passwd",
                        "custom:/etc/passwd",
                        "system:../../../System/Library/Sounds/Glass",
                        "custom:.hidden.mp3",
                        "custom:a\\b.mp3"] {
            XCTAssertEqual(SoundChoice.decode(hostile), .silent, "hostile=\(hostile)")
        }
    }

    func testSafeComponentRules() {
        XCTAssertTrue(SoundChoice.isSafeComponent("finish.mp3"))
        XCTAssertFalse(SoundChoice.isSafeComponent(""))
        XCTAssertFalse(SoundChoice.isSafeComponent("."))
        XCTAssertFalse(SoundChoice.isSafeComponent(".."))
        XCTAssertFalse(SoundChoice.isSafeComponent(String(repeating: "a", count: 300)))
    }

    // MARK: - Import

    func testValidateAcceptsSupportedFormats() {
        XCTAssertNoThrow(try SoundImport.validate(fileExtension: "MP3", byteCount: 1024))
        XCTAssertNoThrow(try SoundImport.validate(fileExtension: "aiff", byteCount: 1024))
    }

    func testValidateRejectsFormatSizeAndEmptiness() {
        XCTAssertThrowsError(try SoundImport.validate(fileExtension: "txt", byteCount: 10))
        XCTAssertThrowsError(try SoundImport.validate(fileExtension: "mp3", byteCount: 0))
        XCTAssertThrowsError(try SoundImport.validate(fileExtension: "mp3",
                                                      byteCount: SoundImport.maxBytes + 1))
    }

    func testDestinationNameSanitizes() {
        XCTAssertEqual(SoundImport.destinationName(for: "/a/b/need-human.mp3"), "need-human.mp3")
        XCTAssertEqual(SoundImport.destinationName(for: "Mon Son !.wav"), "Mon-Son.wav")
        XCTAssertEqual(SoundImport.destinationName(for: "../../evil.mp3"), "evil.mp3")
    }

    func testDestinationNameRejectsUnsupportedOrEmpty() {
        XCTAssertNil(SoundImport.destinationName(for: "notes.txt"))
        XCTAssertNil(SoundImport.destinationName(for: "---.mp3"))
    }

    // MARK: - Sons système

    func testSystemSoundNamesFilterAndSort() {
        let names = SystemSounds.names(fromFileNames: [
            "Glass.aiff", "Basso.aiff", "README.txt", "Tink.aiff", ".hidden.aiff",
        ])
        XCTAssertEqual(names, ["Basso", "Glass", "Tink"])
    }

    func testSystemSoundNamesDeduplicate() {
        XCTAssertEqual(SystemSounds.names(fromFileNames: ["Glass.aiff", "Glass.wav"]), ["Glass"])
    }

    // MARK: - Anti-rafale

    func testThrottleBlocksBurstsButAllowsSpacedSounds() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SoundThrottle.shouldPlay(lastPlayedAt: nil, now: now))
        XCTAssertFalse(SoundThrottle.shouldPlay(lastPlayedAt: now.addingTimeInterval(-0.5), now: now))
        XCTAssertTrue(SoundThrottle.shouldPlay(lastPlayedAt: now.addingTimeInterval(-5), now: now))
    }

    /// Horloge qui recule (veille, changement d'heure) : mieux vaut jouer un son
    /// de trop que rester muet jusqu'à ce que l'horloge rattrape.
    func testThrottleAllowsWhenClockGoesBackwards() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SoundThrottle.shouldPlay(lastPlayedAt: now.addingTimeInterval(500), now: now))
    }

    func testEventKeysAreDistinct() {
        let keys = Set(SoundEvent.allCases.flatMap { [$0.choiceKey, $0.volumeKey] })
        XCTAssertEqual(keys.count, SoundEvent.allCases.count * 2)
    }
}
