import Foundation
import AtollCore
@main struct Main {
 @MainActor static func main() async {
  UserDefaults.standard.setVolatileDomain(["autonomyLevel":"manual"], forName:UserDefaults.argumentDomain)
  func permission(_ cmd:String)->ParsedHookEvent { ParsedHookEvent(envelope:["payload":["hook_event_name":"PermissionRequest","session_id":"same-session","tool_name":"Bash","tool_input":["command":cmd]]])! }
  let center=InteractionCenter(); let bridge=BridgeServer(); center.server=bridge
  center.register(event:permission("command A"),requestID:"A")
  center.register(event:permission("command B"),requestID:"B")
  center.allow("A")
  let before=center.pending.map(\.id)
  center.cancelForSession("same-session",tool:"Bash")
  print("PERMISSION pending-before-post-A=\(before) pending-after-post-A=\(center.pending.map(\.id)) canceled=\(bridge.canceled)")
  let completion=ParsedHookEvent(envelope:["payload":["hook_event_name":"PostToolUse","session_id":"same-session","tool_name":"Bash","tool_input":["command":"command A"]]])!
  let phase=SessionReducer.reduce(.waitingPermission(tool:"Bash(command B)"),completion)
  print("COUNTERCHECK replies=\(bridge.replies) phase=\(phase)")
  let start=ProcessInfo.processInfo.systemUptime
  let data=await FleetPoller.auditRead(CommandLine.arguments[1])
  print("FLEET duration=\(ProcessInfo.processInfo.systemUptime-start) result=\(data.map { String(decoding:$0,as:UTF8.self) } ?? "nil")")
 }
}
