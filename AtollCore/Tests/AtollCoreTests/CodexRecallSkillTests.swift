import XCTest
@testable import AtollCore

final class CodexRecallSkillTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codex recall \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var home: URL { root.appendingPathComponent("home") }
    private var directory: URL { CodexRecallSkill.directory(home: home) }
    private var skill: URL { directory.appendingPathComponent("SKILL.md") }
    private var receipt: URL { directory.appendingPathComponent(".atoll-recall.json") }
    private var helper: URL { root.appendingPathComponent("Atoll's copy.app/Contents/MacOS/atoll-bridge") }

    func testCodexOnlyAbsoluteHelperIdempotenceAndAppMove() throws {
        try CodexRecallSkill.install(home: home, helperURL: helper)
        let first = try Data(contentsOf: skill)
        let date = Date(timeIntervalSince1970: 123)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: skill.path)
        try CodexRecallSkill.install(home: home, helperURL: helper)
        XCTAssertEqual(try Data(contentsOf: skill), first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: skill.path)[.modificationDate] as? Date, date)
        let text = try String(contentsOf: skill, encoding: .utf8)
        XCTAssertTrue(text.contains(FleetLaunch.shellQuote(helper.path)))
        XCTAssertFalse(text.contains(".claude/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude").path))
        let moved = root.appendingPathComponent("Moved.app/Contents/MacOS/atoll-bridge")
        try CodexRecallSkill.install(home: home, helperURL: moved)
        XCTAssertTrue(try String(contentsOf: skill, encoding: .utf8).contains(moved.path))
    }

    func testForeignAndManuallyModifiedSkillAreNeverOverwrittenOrRemoved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("personal skill".utf8).write(to: skill)
        XCTAssertThrowsError(try CodexRecallSkill.install(home: home, helperURL: helper))
        try CodexRecallSkill.uninstall(home: home)
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), "personal skill")
        try FileManager.default.removeItem(at: directory)
        try CodexRecallSkill.install(home: home, helperURL: helper)
        try Data("edited after install".utf8).write(to: skill)
        XCTAssertThrowsError(try CodexRecallSkill.install(home: home, helperURL: helper))
        try CodexRecallSkill.uninstall(home: home)
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), "edited after install")
    }

    func testInterruptedReceiptUpdateCanResumeAndUninstallKeepsResources() throws {
        try CodexRecallSkill.install(home: home, helperURL: helper)
        let old = try String(contentsOf: skill, encoding: .utf8)
        let moved = root.appendingPathComponent("moved/bridge")
        let next = CodexRecallSkill.markdown(helperURL: moved)
        let staged = try JSONSerialization.data(withJSONObject: ["hashes": [old, next].map(InstalledSkillsManifest.sha256)])
        try staged.write(to: receipt, options: .atomic) // crash avant remplacement du texte
        try CodexRecallSkill.install(home: home, helperURL: moved)
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), next)
        try Data("personal notes".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try CodexRecallSkill.uninstall(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8), "personal notes")
    }

    func testSymlinksAndOversizedContentsFailClosed() throws {
        try CodexRecallSkill.install(home: home, helperURL: helper)
        let outside = root.appendingPathComponent("outside.md")
        try FileManager.default.moveItem(at: skill, to: outside)
        try FileManager.default.createSymbolicLink(at: skill, withDestinationURL: outside)
        XCTAssertThrowsError(try CodexRecallSkill.install(home: home, helperURL: helper))
        try CodexRecallSkill.uninstall(home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue((try skill.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
        try FileManager.default.removeItem(at: skill)
        let large = Data(repeating: 65, count: 131_073)
        try large.write(to: skill)
        XCTAssertThrowsError(try CodexRecallSkill.install(home: home, helperURL: helper))
        try CodexRecallSkill.uninstall(home: home)
        XCTAssertEqual(try Data(contentsOf: skill), large)
    }
}
