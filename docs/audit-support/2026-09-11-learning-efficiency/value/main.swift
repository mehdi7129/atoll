import Foundation
// Racines isolées ; seuls les défauts de SkillCatalog utilisent ces constantes.
public enum BridgePaths {
 public static let homeDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
 public static let claudeSkillsDirectory = homeDirectory.appendingPathComponent("user-skills")
 public static let claudeSettingsURL = homeDirectory.appendingPathComponent("settings.json")
}
let root = BridgePaths.homeDirectory
let fm = FileManager.default
func makeSkill(_ relative: String) throws {
 let dir=root.appendingPathComponent(relative)
 try fm.createDirectory(at: dir, withIntermediateDirectories: true)
 try "---\nname: pipeline-release\ndescription: Publier une application après notarisation.\n---\nProcédure éprouvée.\n".write(to: dir.appendingPathComponent("SKILL.md"),atomically:true,encoding:.utf8)
}
try makeSkill("project/.claude/skills/pipeline-release")
let commandDir = root.appendingPathComponent("project/.claude/commands")
try fm.createDirectory(at: commandDir,withIntermediateDirectories:true)
try "---\ndescription: Commande de contrôle.\n---\nLire seulement.".write(to:commandDir.appendingPathComponent("known-command.md"),atomically:true,encoding:.utf8)
let catalog = SkillCatalog(skillsRoot:root.appendingPathComponent("user-skills"),commandsRoot:root.appendingPathComponent("user-commands"),pluginsCacheRoot:root.appendingPathComponent("plugins"),settingsURL:root.appendingPathComponent("settings.json"),projectDirectory:root.appendingPathComponent("project")).entries()
try makeSkill("learning/proposed/pipeline-release-fixture-one")
try makeSkill("learning/archive/rejected/pipeline-release-fixture-two")
let catalogAfterHistory = SkillCatalog(skillsRoot:root.appendingPathComponent("user-skills"),commandsRoot:root.appendingPathComponent("user-commands"),pluginsCacheRoot:root.appendingPathComponent("plugins"),settingsURL:root.appendingPathComponent("settings.json"),projectDirectory:root.appendingPathComponent("project")).entries()
let long = String(repeating:"Contexte de la procédure. ",count:100)+"PREUVE_FINALE: la commande nécessite --verified-final-flag."
let line = TranscriptLine(uuid:nil,sessionID:nil,timestamp:nil,cwd:nil,gitBranch:nil,fragments:[.init(role:.assistant,text:long)])
let digest=TranscriptDigest.make(lines:[line])
let result:[String:Any] = ["catalogIDs":catalog.map(\.id),"catalogUnchangedAfterPendingAndRejected":catalog == catalogAfterHistory,"projectSkillFound":catalog.contains{$0.id=="pipeline-release"},"projectCommandFound":catalog.contains{$0.id=="known-command"},"digestInputCharacters":long.count,"digestOutputCharacters":digest.characterCount,"digestEntriesKept":digest.entriesKept,"digestTruncatedFlag":digest.truncated,"digestFinalEvidencePresent":digest.text.contains("PREUVE_FINALE"),"digestTruncationMarkerPresent":digest.text.contains(" […]")]
print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
