import XCTest
@testable import AtollCore

final class CodexHookInstallationTests: XCTestCase {
    private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atoll-install-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testFirstInstallReinstallBackupAndUninstall() throws {
        try inTemporaryDirectory { root in
            let settings = root.appendingPathComponent("hooks.json")
            let bin = root.appendingPathComponent("bin")
            let original = Data(#"{"description":"personal","hooks":{}}"#.utf8)
            try original.write(to: settings)
            for _ in 0..<2 {
                try CodexHookInstallation.apply(settingsURL: settings, binDirectory: bin,
                                                helperURL: root.appendingPathComponent("Atoll's test.app/helper"), install: true)
            }
            XCTAssertEqual(try Data(contentsOf: settings.appendingPathExtension("atoll-backup")), original)
            XCTAssertTrue(CodexHookSettingsEditor.isInstalled(try Data(contentsOf: settings)))
            let wrapper = bin.appendingPathComponent("atoll-codex-bridge")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wrapper.path))
            XCTAssertTrue(try String(contentsOf: wrapper).contains("Atoll'\\''s test.app"))
            let attributes = try FileManager.default.attributesOfItem(atPath: settings.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try CodexHookInstallation.apply(settingsURL: settings, binDirectory: bin, helperURL: root, install: false)
            XCTAssertFalse(CodexHookSettingsEditor.isInstalled(try Data(contentsOf: settings)))
            XCTAssertEqual(try Data(contentsOf: settings.appendingPathExtension("atoll-backup")), original)
            // Wrapper deliberately survives so already-running sessions fail open.
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wrapper.path))
        }
    }

    func testMalformedConfigDoesNotCreateWrapperOrBackup() throws {
        try inTemporaryDirectory { root in
            let settings = root.appendingPathComponent("hooks.json")
            let original = Data("broken json".utf8)
            try original.write(to: settings)
            XCTAssertThrowsError(try CodexHookInstallation.apply(settingsURL: settings,
                binDirectory: root.appendingPathComponent("bin"), helperURL: root, install: true))
            XCTAssertEqual(try Data(contentsOf: settings), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bin").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: settings.appendingPathExtension("atoll-backup").path))
        }
    }

    func testSymlinkIsPreservedAndMissingUninstallIsNoop() throws {
        try inTemporaryDirectory { root in
            let missing = root.appendingPathComponent("missing/hooks.json")
            try CodexHookInstallation.apply(settingsURL: missing, binDirectory: root, helperURL: root, install: false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
            let target = root.appendingPathComponent("dotfiles.json")
            try Data("{}".utf8).write(to: target)
            let link = root.appendingPathComponent("hooks.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            try CodexHookInstallation.apply(settingsURL: link, binDirectory: root.appendingPathComponent("bin"), helperURL: root, install: true)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
            XCTAssertTrue(CodexHookSettingsEditor.isInstalled(try Data(contentsOf: target)))
        }
    }
}
