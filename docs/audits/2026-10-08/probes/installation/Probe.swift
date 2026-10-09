import Foundation
import AtollCore
@main struct Probe {
 static func data(_ x:Any) throws -> Data { try JSONSerialization.data(withJSONObject:x,options:[.sortedKeys]) }
 static func object(_ x:Data) throws->[String:Any] { try JSONSerialization.jsonObject(with:x) as! [String:Any] }
 static func main() throws {
  let sound:[String:Any]=["type":"command","command":"afplay /System/Library/Sounds/Tink.aiff"]
  let a:[String:Any]=["matcher":"Bash","hooks":[sound]]
  let b:[String:Any]=["matcher":"Edit","hooks":[sound]]
  let initial=try data(["hooks":["PreToolUse":[a,b]]])
  let parked=try SoundHookEditor.park(in:initial)!
  let nominal=try object(SoundHookEditor.restore(into:parked.updated,parked:parked.parked))
  let nominalGroups=(nominal["hooks"] as! [String:Any])["PreToolUse"] as! [[String:Any]]
  print("SOUND_CONTROL restored_matchers=\(nominalGroups.compactMap {$0["matcher"] as? String})")
  let partiallyRestored=try data(["hooks":["PreToolUse":[b]]])
  let restored=try object(SoundHookEditor.restore(into:partiallyRestored,parked:parked.parked))
  let groups=(restored["hooks"] as! [String:Any])["PreToolUse"] as! [[String:Any]]
  print("SOUND restored_matchers=\(groups.compactMap {$0["matcher"] as? String})")
  let command="\"$HOME/.atoll/bin/atoll-bridge\""
  let mixed=try data(["hooks":["Stop":[["hooks":[["type":"command","command":command],["type":"command","command":"echo external"]]]]]])
  let installed=try object(HookSettingsEditor.install(into:mixed,command:command))
  let stop=(installed["hooks"] as! [String:Any])["Stop"] as! [[String:Any]]
  let commands=stop.flatMap {($0["hooks"] as? [[String:Any]] ?? []).compactMap {$0["command"] as? String}}
  print("MIXED commands=\(commands) atoll_count=\(commands.filter {$0==command}.count)")
  let malformed=try data(["hooks":["external-format"],"model":"kept"])
  do { let changed=try object(HookSettingsEditor.install(into:malformed,command:command)); print("MALFORMED hooks_replaced=\(changed["hooks"] is [String:Any])") } catch { print("MALFORMED rejected=\(error)") }
 }
}
