import Foundation
import AtollCore
@main struct Probe {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let fm=FileManager.default
  let learning=root.appendingPathComponent("learning");let skills=root.appendingPathComponent("skills")
  let proposal=learning.appendingPathComponent("proposed/durable")
  try fm.createDirectory(at:proposal,withIntermediateDirectories:true)
  let meta="""
  {"v":1,"slug":"durable","title":"Durable","description":"desc","rationale":"r","source_session":"fixture","created_at":"2026-10-08T00:00:00Z","status":"proposed","flags":[]}
  """
  try Data(meta.utf8).write(to:proposal.appendingPathComponent("meta.json"))
  try Data("# skill original".utf8).write(to:proposal.appendingPathComponent("SKILL.md"))
  let store=LearnedSkillStore(learningRoot:learning,skillsRoot:skills)
  _=try store.approve(store.discoverProposals()[0])
  let before=try Data(contentsOf:store.manifestURL)
  try fm.setAttributes([.posixPermissions:0o000],ofItemAtPath:skills.path)
  defer { try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:skills.path) }
  let rootVisible=fm.fileExists(atPath:skills.path)
  let childVisible=fm.fileExists(atPath:skills.appendingPathComponent("atoll-durable").path)
  let report=store.reconcile()
  try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:skills.path)
  let after=try Data(contentsOf:store.manifestURL)
  let result:[String:Any]=["rootPresentBefore":rootVisible,"childVisibleBefore":childVisible,"removed":report.removedFromManifest,"manifestPreserved":before==after,"fileStillExists":fm.fileExists(atPath:skills.appendingPathComponent("atoll-durable/SKILL.md").path),"managedAfter":store.installedSkills().map(\.slug),"unmanagedAfter":store.reconcile().unmanaged]
  print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
