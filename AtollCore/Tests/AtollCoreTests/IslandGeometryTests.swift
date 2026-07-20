import XCTest
@testable import AtollCore

final class IslandGeometryTests: XCTestCase {

    // Écran type MacBook Pro 14" (notch), coordonnées AppKit.
    let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let notch = CGSize(width: 200, height: 32)

    func testWindowRectIsTopCentered() {
        let rect = IslandGeometry.windowRect(screenFrame: screenFrame)
        XCTAssertEqual(rect.midX, screenFrame.midX, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, screenFrame.maxY, accuracy: 0.001,
                       "la fenêtre doit être collée au bord supérieur")
        XCTAssertEqual(rect.size, IslandGeometry.windowSize)
    }

    func testWindowRectOnSecondaryScreenUsesGlobalCoordinates() {
        let secondary = CGRect(x: 1512, y: 200, width: 2560, height: 1440)
        let rect = IslandGeometry.windowRect(screenFrame: secondary)
        XCTAssertEqual(rect.midX, secondary.midX, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, secondary.maxY, accuracy: 0.001)
    }

    func testCompactSizeIdleHugsTheNotch() {
        let size = IslandGeometry.compactSize(notch: notch, menuBarHeight: 37, hasActivity: false)
        XCTAssertEqual(size, notch, "sans activité l'îlot doit disparaître derrière le notch")
    }

    func testCompactSizeActiveAddsWings() {
        let size = IslandGeometry.compactSize(notch: notch, menuBarHeight: 37, hasActivity: true)
        XCTAssertEqual(size.width, notch.width + IslandGeometry.wingWidth * 2)
        XCTAssertEqual(size.height, notch.height)
    }

    func testCompactSizeWithoutNotchIsPill() {
        let size = IslandGeometry.compactSize(notch: nil, menuBarHeight: 24, hasActivity: true)
        XCTAssertEqual(size.width, IslandGeometry.pillWidth)
        XCTAssertEqual(size.height, IslandGeometry.minimumPillHeight)

        let tallMenuBar = IslandGeometry.compactSize(notch: nil, menuBarHeight: 37, hasActivity: false)
        XCTAssertEqual(tallMenuBar.height, 37, "la pilule suit la hauteur de la barre de menus")
    }

    func testExpandedSizeIsNeverNarrowerThanCompact() {
        let wideNotch = CGSize(width: 600, height: 32)
        let expanded = IslandGeometry.expandedIslandSize(notch: wideNotch, menuBarHeight: 37)
        let compact = IslandGeometry.compactSize(notch: wideNotch, menuBarHeight: 37, hasActivity: true)
        XCTAssertGreaterThanOrEqual(expanded.width, compact.width)
    }

    func testExpandedFitsInsideWindow() {
        let expanded = IslandGeometry.expandedIslandSize(notch: notch, menuBarHeight: 37)
        XCTAssertLessThanOrEqual(expanded.width, IslandGeometry.windowSize.width)
        XCTAssertLessThanOrEqual(expanded.height, IslandGeometry.windowSize.height)

        let pillExpanded = IslandGeometry.expandedIslandSize(notch: nil, menuBarHeight: 24)
        XCTAssertLessThanOrEqual(pillExpanded.width, IslandGeometry.windowSize.width)
        XCTAssertLessThanOrEqual(pillExpanded.height, IslandGeometry.windowSize.height)
    }

    func testCompactWidthScalesWings() {
        let small = IslandGeometry.compactSize(notch: notch, menuBarHeight: 37, hasActivity: true, width: .small)
        let medium = IslandGeometry.compactSize(notch: notch, menuBarHeight: 37, hasActivity: true, width: .medium)
        let large = IslandGeometry.compactSize(notch: notch, menuBarHeight: 37, hasActivity: true, width: .large)
        // La largeur croît avec la taille ; la hauteur (le notch) ne change pas.
        XCTAssertLessThan(small.width, medium.width)
        XCTAssertLessThan(medium.width, large.width)
        XCTAssertEqual(small.height, notch.height)
        XCTAssertEqual(large.height, notch.height)
        // Chaque côté = une aile de la taille demandée.
        XCTAssertEqual(large.width, notch.width + IslandWidth.large.wingWidth * 2)
    }

    func testCompactWidthScalesPill() {
        XCTAssertEqual(
            IslandGeometry.compactSize(notch: nil, menuBarHeight: 24, hasActivity: true, width: .small).width,
            IslandWidth.small.pillWidth)
        XCTAssertEqual(
            IslandGeometry.compactSize(notch: nil, menuBarHeight: 24, hasActivity: true, width: .large).width,
            IslandWidth.large.pillWidth)
    }

    func testAllWidthsFitInsideWindow() {
        // Même en « large », l'îlot (compact et étendu) tient dans la fenêtre fixe.
        for width in IslandWidth.allCases {
            let compact = IslandGeometry.compactSize(notch: notch, menuBarHeight: 37, hasActivity: true, width: width)
            XCTAssertLessThanOrEqual(compact.width, IslandGeometry.windowSize.width)
            let expanded = IslandGeometry.expandedIslandSize(notch: notch, menuBarHeight: 37, width: width)
            XCTAssertLessThanOrEqual(expanded.width, IslandGeometry.windowSize.width)
            // Le panneau étendu reste inchangé (la taille ne joue que sur le compact).
            XCTAssertEqual(expanded.width, IslandGeometry.expandedSize.width)
        }
    }
}
