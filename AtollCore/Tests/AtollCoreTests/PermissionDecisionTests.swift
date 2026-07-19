import XCTest
@testable import AtollCore

final class PermissionDecisionTests: XCTestCase {

    private func decision(from data: Data) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
        return try XCTUnwrap(output["decision"] as? [String: Any])
    }

    func testAllow() throws {
        let d = try decision(from: PermissionDecision.allow())
        XCTAssertEqual(d["behavior"] as? String, "allow")
        XCTAssertNil(d["updatedInput"])
        XCTAssertNil(d["updatedPermissions"])
    }

    func testDeny() throws {
        let d = try decision(from: PermissionDecision.deny(message: "refusé depuis Atoll"))
        XCTAssertEqual(d["behavior"] as? String, "deny")
        XCTAssertEqual(d["message"] as? String, "refusé depuis Atoll")
        XCTAssertEqual(d["interrupt"] as? Bool, false)
    }

    func testApprovePlanPlain() throws {
        let d = try decision(from: PermissionDecision.approvePlan(acceptEdits: false))
        XCTAssertEqual(d["behavior"] as? String, "allow")
        XCTAssertNil(d["updatedPermissions"])
    }

    func testApprovePlanWithAcceptEdits() throws {
        let d = try decision(from: PermissionDecision.approvePlan(acceptEdits: true))
        XCTAssertEqual(d["behavior"] as? String, "allow")
        let permissions = try XCTUnwrap(d["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(permissions.first?["type"] as? String, "setMode")
        XCTAssertEqual(permissions.first?["mode"] as? String, "acceptEdits")
        XCTAssertEqual(permissions.first?["destination"] as? String, "session")
    }

    func testRejectPlanCarriesFeedback() throws {
        let d = try decision(from: PermissionDecision.rejectPlan(feedback: "trop risqué, découpe en 2 étapes"))
        XCTAssertEqual(d["behavior"] as? String, "deny")
        XCTAssertEqual(d["message"] as? String, "trop risqué, découpe en 2 étapes")
    }

    func testAnswerQuestionsPassesThroughOriginalInput() throws {
        let toolInput: [String: Any] = [
            "questions": [
                [
                    "question": "Quelle approche ?",
                    "header": "Approche",
                    "multiSelect": false,
                    "options": [["label": "SwiftUI"], ["label": "AppKit"]],
                ]
            ]
        ]
        let inputData = try JSONSerialization.data(withJSONObject: toolInput)
        let data = try XCTUnwrap(PermissionDecision.answerQuestions(
            toolInputData: inputData,
            answers: ["Quelle approche ?": "SwiftUI"]
        ))
        let d = try decision(from: data)
        XCTAssertEqual(d["behavior"] as? String, "allow")
        let updated = try XCTUnwrap(d["updatedInput"] as? [String: Any])
        XCTAssertNotNil(updated["questions"], "le passthrough de questions est obligatoire")
        let answers = try XCTUnwrap(updated["answers"] as? [String: String])
        XCTAssertEqual(answers["Quelle approche ?"], "SwiftUI")
    }

    func testAnswerQuestionsRefusesMalformedInput() {
        XCTAssertNil(PermissionDecision.answerQuestions(
            toolInputData: Data("pas du json".utf8),
            answers: ["q": "r"]
        ))
        // Sans clé questions : décision malformée → on préfère rendre la main.
        let empty = try! JSONSerialization.data(withJSONObject: ["autre": 1])
        XCTAssertNil(PermissionDecision.answerQuestions(toolInputData: empty, answers: ["q": "r"]))
    }

    func testParsedEventExtractsPermissionDetails() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "s-perm",
            "tool_name": "ExitPlanMode",
            "tool_input": ["plan": "# Plan\n1. faire\n2. vérifier"],
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash"]]]],
        ]
        let event = try XCTUnwrap(ParsedHookEvent(envelope: ["payload": payload]))
        XCTAssertEqual(event.kind, .permissionRequest)
        XCTAssertEqual(event.planText, "# Plan\n1. faire\n2. vérifier")
        XCTAssertNotNil(event.toolInputData)
        XCTAssertNotNil(event.suggestionsData)
        XCTAssertNil(event.questions)
    }

    func testParsedEventExtractsQuestions() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "s-q",
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [
                    [
                        "question": "Quelle palette ?",
                        "header": "Palette",
                        "multiSelect": true,
                        "options": [
                            ["label": "Mono", "description": "orange"],
                            ["label": "Phosphor"],
                        ],
                    ]
                ]
            ],
        ]
        let event = try XCTUnwrap(ParsedHookEvent(envelope: ["payload": payload]))
        let questions = try XCTUnwrap(event.questions)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].question, "Quelle palette ?")
        XCTAssertTrue(questions[0].multiSelect)
        XCTAssertEqual(questions[0].options.map(\.label), ["Mono", "Phosphor"])
        XCTAssertEqual(questions[0].options[0].description, "orange")
    }

    func testDefaultAnswersPicksFirstOption() {
        let questions = [
            ParsedHookEvent.AskQuestion(
                question: "Quelle approche ?", header: "App", multiSelect: false,
                options: [.init(label: "SwiftUI", description: nil), .init(label: "AppKit", description: nil)]
            ),
            ParsedHookEvent.AskQuestion(
                question: "Tests ?", header: "T", multiSelect: false,
                options: [.init(label: "Oui", description: nil), .init(label: "Non", description: nil)]
            ),
        ]
        let answers = PermissionDecision.defaultAnswers(for: questions)
        XCTAssertEqual(answers["Quelle approche ?"], "SwiftUI")
        XCTAssertEqual(answers["Tests ?"], "Oui")
    }

    func testDefaultAnswersSkipsOptionlessQuestions() {
        let questions = [
            ParsedHookEvent.AskQuestion(question: "Libre ?", header: nil, multiSelect: false, options: [])
        ]
        XCTAssertTrue(PermissionDecision.defaultAnswers(for: questions).isEmpty)
    }

    func testRockstarQuestionDecisionIsWellFormed() throws {
        // Le chemin rockstar pour une question doit produire un allow valide.
        let toolInput: [String: Any] = ["questions": [["question": "X", "options": [["label": "A"]]]]]
        let data = try JSONSerialization.data(withJSONObject: toolInput)
        let questions = [ParsedHookEvent.AskQuestion(question: "X", header: nil, multiSelect: false, options: [.init(label: "A", description: nil)])]
        let decisionData = try XCTUnwrap(PermissionDecision.answerQuestions(
            toolInputData: data, answers: PermissionDecision.defaultAnswers(for: questions)))
        let d = try decision(from: decisionData)
        XCTAssertEqual(d["behavior"] as? String, "allow")
        let updated = try XCTUnwrap(d["updatedInput"] as? [String: Any])
        XCTAssertEqual((updated["answers"] as? [String: String])?["X"], "A")
    }

    func testReducerMapsPermissionRequestToWaitingPermission() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "s",
            "tool_name": "Bash",
            "tool_input": ["command": "git push"],
        ]
        let event = try XCTUnwrap(ParsedHookEvent(envelope: ["payload": payload]))
        XCTAssertEqual(
            SessionReducer.reduce(.busy, event),
            .waitingPermission(tool: "Bash(git push)")
        )
    }
}
