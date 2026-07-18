import XCTest
@testable import AtollCore

final class AsciiArtTests: XCTestCase {

    // MARK: - progressBar

    func testProgressBarEmpty() {
        XCTAssertEqual(AsciiArt.progressBar(fraction: 0, cells: 7), "░░░░░░░")
    }

    func testProgressBarFull() {
        XCTAssertEqual(AsciiArt.progressBar(fraction: 1, cells: 7), "███████")
    }

    func testProgressBarPartialEighths() {
        // 0.27 * 7 * 8 = 15,12 → 15 huitièmes = 1 plein + 7/8 (▉)
        XCTAssertEqual(AsciiArt.progressBar(fraction: 0.27, cells: 7), "█▉░░░░░")
    }

    func testProgressBarHalfCell() {
        // 0.5 * 1 * 8 = 4 huitièmes → ▌
        XCTAssertEqual(AsciiArt.progressBar(fraction: 0.5, cells: 1), "▌")
    }

    func testProgressBarClampsOutOfRange() {
        XCTAssertEqual(AsciiArt.progressBar(fraction: -0.5, cells: 4), "░░░░")
        XCTAssertEqual(AsciiArt.progressBar(fraction: 1.5, cells: 4), "████")
    }

    func testProgressBarConstantWidth() {
        for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(AsciiArt.progressBar(fraction: fraction, cells: 10).count, 10,
                           "largeur incohérente pour fraction \(fraction)")
        }
    }

    func testProgressBarZeroCells() {
        XCTAssertEqual(AsciiArt.progressBar(fraction: 0.5, cells: 0), "")
    }

    func testProgressBarNonFiniteInputs() {
        XCTAssertEqual(AsciiArt.progressBar(fraction: .nan, cells: 4), "░░░░")
        XCTAssertEqual(AsciiArt.progressBar(fraction: .infinity, cells: 4), "░░░░")
        XCTAssertEqual(AsciiArt.progressBar(fraction: -.infinity, cells: 4), "░░░░")
    }

    // MARK: - spinner

    func testSpinnerFrameDeterministic() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(AsciiArt.spinnerFrame(at: date), "⠋")
        let next = Date(timeIntervalSinceReferenceDate: AsciiArt.spinnerInterval)
        XCTAssertEqual(AsciiArt.spinnerFrame(at: next), "⠙")
    }

    func testSpinnerCyclesThroughAllFrames() {
        var seen = Set<String>()
        for index in 0..<AsciiArt.spinnerFrames.count {
            let date = Date(timeIntervalSinceReferenceDate: Double(index) * AsciiArt.spinnerInterval)
            seen.insert(AsciiArt.spinnerFrame(at: date))
        }
        XCTAssertEqual(seen.count, AsciiArt.spinnerFrames.count)
    }

    // MARK: - sparkline

    func testSparkline() {
        XCTAssertEqual(AsciiArt.sparkline([0, 0.5, 1]), "▁▅█")
        XCTAssertEqual(AsciiArt.sparkline([]), "")
    }

    func testSparklineClampsAndSurvivesNonFinite() {
        XCTAssertEqual(AsciiArt.sparkline([-1, 2]), "▁█")
        XCTAssertEqual(AsciiArt.sparkline([.nan, .infinity]), "▁▁")
    }

    func testSpinnerFrameNegativeDate() {
        // Une date antérieure à la référence ne doit ni planter ni sortir des bornes.
        let past = Date(timeIntervalSinceReferenceDate: -12345.678)
        XCTAssertTrue(AsciiArt.spinnerFrames.contains(AsciiArt.spinnerFrame(at: past)))
    }

    // MARK: - badges

    func testStatusBadges() {
        XCTAssertEqual(AsciiArt.statusBadge(.working(tool: nil)), "[ WORKING ]")
        XCTAssertEqual(AsciiArt.statusBadge(.awaitingPermission(tool: "Bash")), "[ APPROVE? ]")
        XCTAssertEqual(AsciiArt.statusBadge(.awaitingInput), "[ INPUT? ]")
        XCTAssertEqual(AsciiArt.statusBadge(.done), "[ DONE ]")
    }

    // MARK: - règles

    func testSectionHeader() {
        XCTAssertEqual(AsciiArt.sectionHeader("SESSIONS", width: 16), "── SESSIONS ────")
        XCTAssertEqual(AsciiArt.sectionHeader("SESSIONS", width: 4), "── SESSIONS ")
    }

    func testRule() {
        XCTAssertEqual(AsciiArt.rule(3), "───")
        XCTAssertEqual(AsciiArt.rule(-1), "")
    }
}
