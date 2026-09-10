import XCTest
@testable import AtollCore

final class CodexPermissionRequestTests: XCTestCase {
    func testFullPayloadSurvivesSummaryTruncation() throws {
        let command = String(repeating: "echo ok; ", count: 60) + "rm important-file"
        let payload: [String: Any] = ["tool_name": "Bash", "cwd": "/path with spaces",
                                      "tool_input": ["command": command], "reason": "native reason"]
        let request = try XCTUnwrap(CodexPermissionRequest(payload: payload))
        XCTAssertFalse(request.summary.contains("important-file"))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.details.utf8)) as? [String: Any])
        XCTAssertEqual((decoded["tool_input"] as? [String: String])?["command"], command)
        XCTAssertEqual(decoded["reason"] as? String, "native reason")
        XCTAssertEqual(request.cwd, "/path with spaces")
    }

    func testPatchAndMCPInputsArePreservedWithoutTranslation() throws {
        for (name, input) in [("apply_patch", ["patch": "*** Begin Patch\n*** End Patch"]),
                              ("mcp__test__tool", ["argument": "value"])] {
            let request = try XCTUnwrap(CodexPermissionRequest(payload: ["tool_name": name, "cwd": "/p", "tool_input": input]))
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.details.utf8)) as? [String: Any])
            XCTAssertEqual(decoded["tool_input"] as? [String: String], input)
        }
    }

    func testUnrenderableAndOversizedRequestsReturnToNative() {
        XCTAssertNil(CodexPermissionRequest(payload: ["tool_name": "Bash", "cwd": "/p"]))
        XCTAssertNil(CodexPermissionRequest(payload: ["tool_name": "Bash", "tool_input": ["command": "ls"]]))
        XCTAssertNil(CodexPermissionRequest(payload: ["tool_name": "Bash", "cwd": "/p", "tool_input":
            ["command": String(repeating: "x", count: CodexPermissionRequest.maximumBytes + 1)]]))
    }
}
