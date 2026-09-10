import Foundation
let records: [[String: Any]] = [
 ["type": "response_item", "payload": ["type": "function_call", "name": "read_file", "arguments": "source.swift", "call_id": "ok-read"]],
 ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "ok-read", "output": "let error = nil // successfully read source file"]],
 ["type": "response_item", "payload": ["type": "function_call", "name": "run", "arguments": "false", "call_id": "failed-cmd"]],
 ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "failed-cmd", "output": "{\"exit_code\":1,\"output\":\"\"}"]]
]
let lines = try records.compactMap { CodexTranscriptParser.parse(try JSONSerialization.data(withJSONObject: $0)) }
for entry in TranscriptDigest.entries(from: lines) { print(entry.toolUseID ?? "-", entry.role.rawValue) }

let envelope: [String: Any] = ["type":"response_item", "payload":["type":"message", "role":"user", "content":[["type":"input_text", "text":"# AGENTS.md instructions for /fixture\n<INSTRUCTIONS>Fixture de politique du dépôt.</INSTRUCTIONS>"]]]]
let parsed = CodexTranscriptParser.parse(try JSONSerialization.data(withJSONObject: envelope))
print("AGENTS envelope roles ->", parsed?.fragments.map { $0.role.rawValue } ?? [])
