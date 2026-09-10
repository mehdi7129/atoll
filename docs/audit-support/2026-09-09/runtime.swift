import Foundation
func event(_ kind: String, turn: String? = "t1", input: [String:Any]? = nil) -> CodexHookEvent {
 var payload: [String:Any] = ["hook_event_name":kind,"session_id":"test-session","cwd":"/tmp/project"]
 if let turn { payload["turn_id"] = turn }
 if let input { payload["tool_name"] = "exec_command"; payload["tool_input"] = input }
 return CodexHookEvent(envelope:["provider":"codex","payload":payload])!
}
let now=Date()
let found=CodexSessionDiscovery.discover(processes:[.init(pid:123,cwd:"/tmp/project")],rollouts:[.init(path:"old-rollout",sessionID:"historical",cwd:"/tmp/project",modifiedAt:now.addingTimeInterval(-3600))],known:[],now:now)
print("generic live process + closed rollout ->",found.map(\.sessionID))
var sessions=CodexSessions()
sessions.apply(event("SessionStart"),now:now)
sessions.apply(event("UserPromptSubmit"),now:now)
sessions.apply(event("SessionEnd"),now:now)
print("after SessionEnd ->",sessions.sessions(now:now).count)
let resurrect=sessions.applyEvent(event("PreToolUse",input:["cmd":"echo should-be-visible"]),now:now)
print("late async tool after SessionEnd -> accepted=",resurrect.accepted,"sessions=",sessions.sessions(now:now).count)
print("permission summary for exec_command cmd ->",event("PermissionRequest",input:["cmd":"echo should-be-visible"]).tool ?? "nil")
print("silent crashed session after 23h ->",sessions.sessions(now:now.addingTimeInterval(23*3600)).count)
var unnamed=CodexSessions()
unnamed.apply(event("UserPromptSubmit"),now:now)
unnamed.apply(event("Stop",turn:nil),now:now)
let repeatPrompt=unnamed.applyEvent(event("UserPromptSubmit"),now:now)
print("Stop without turn then late same-turn prompt -> accepted=",repeatPrompt.accepted,"active=",unnamed.sessions(now:now).first!.isActive)

let wanted = try CodexHookSettingsEditor.edit(nil,install:true)
try wanted.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
var historical = try JSONSerialization.jsonObject(with:wanted) as! [String:Any]
var hooks = historical["hooks"] as! [String:Any]
hooks["PermissionRequest"] = [["hooks":[["type":"command","command":CodexHookSettingsEditor.command,"async":true,"timeout":3]]]]
historical["hooks"] = hooks
let oldData=try JSONSerialization.data(withJSONObject:historical)
print("legacy async permission + timeout3 installed ->",CodexHookSettingsEditor.isInstalled(oldData))
