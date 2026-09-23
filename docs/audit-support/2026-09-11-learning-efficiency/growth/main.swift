import Foundation
import CryptoKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
try fm.createDirectory(at:root,withIntermediateDirectories:true)
let now = Date(timeIntervalSince1970: 1_789_000_060)
let prior = now.addingTimeInterval(-60)
let sessionID = "audit-same-material"
func record(_ type: String, _ payload: [String:Any]) -> Data {
 var data=try! JSONSerialization.data(withJSONObject:["type":type,"timestamp":"2026-09-11T10:00:00Z","payload":payload],options:[.sortedKeys])
 data.append(10)
 return data
}
var initial=Data()
for index in 1...3 {
 initial.append(record("response_item",["type":"message","role":"user","content":[["type":"input_text","text":"Demande utilisateur \(index) : vérifier la procédure de conversion."]]]))
}
for index in 1...100 {
 initial.append(record("response_item",["type":"message","role":"assistant","content":[["type":"output_text","text":"Résultat vérifié \(index). " + String(repeating:"Détail utile de la procédure. ",count:40)]]]))
}
let metadata=record("turn_context",["audit_fixture_metadata":String(repeating:"M",count:60_000)])
var later=initial
later.append(metadata)
try initial.write(to:root.appendingPathComponent("first.jsonl"))
try later.write(to:root.appendingPathComponent("second.jsonl"))
func digest(_ data:Data)->TranscriptDigest.Result {
 let lines=data.split(separator:10).compactMap {CodexTranscriptParser.parse(Data($0))}
 return TranscriptDigest.make(lines:lines)
}
let before=digest(initial)
let after=digest(later)
func facts(_ bytes:Int)->LearningGate.SessionFacts {
 .init(sessionID:sessionID,durationSeconds:1_200,transcriptSizeBytes:bytes,userPromptCount:3,isCurrentlyAlive:false)
}
let config=LearningGate.Config(enabled:true)
let quota=LearningGate.QuotaFacts(usedFraction:0.2,receivedAt:prior,resetsAt:now.addingTimeInterval(3_600))
let first=LearningGate.decide(session:facts(initial.count),quota:quota,config:config,history:.init(),now:prior)
let history=LearningGate.History(processed:[.init(sessionID:sessionID,transcriptBytes:initial.count,completedAt:prior)],runTimestamps:[prior])
let second=LearningGate.decide(session:facts(later.count),quota:quota,config:config,history:history,now:now)
let noGrowth=LearningGate.decide(session:facts(initial.count),quota:quota,config:config,history:history,now:now)
let capped=LearningGate.decide(session:facts(later.count),quota:quota,config:config,history:.init(processed:history.processed,runTimestamps:[prior,prior]),now:now)
func sha(_ text:String)->String { SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined() }
let results:[String:Any]=["firstBytes":initial.count,"secondBytes":later.count,"rawGrowthBytes":later.count-initial.count,"growthThresholdBytes":config.reprocessGrowthBytes,"firstDecision":String(describing:first),"secondDecision":String(describing:second),"sameBytesControlDecision":String(describing:noGrowth),"windowCapControlDecision":String(describing:capped),"digestIdentical":before.text==after.text,"firstDigestSHA256":sha(before.text),"secondDigestSHA256":sha(after.text),"digestCharacters":before.characterCount,"digestEntries":before.entriesKept,"digestTruncated":before.truncated,"firstParsedLines":before.linesRead,"secondParsedLines":after.linesRead,"newMetadataParsedAsNil":CodexTranscriptParser.parse(metadata)==nil,"sessionID":sessionID,"durationSeconds":1_200,"userPromptCount":3,"quotaUsedFraction":0.2,"priorRunsInWindow":1]
precondition(first == .run && second == .run && before.text == after.text)
let output=try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
try output.write(to:root.appendingPathComponent("results.json"))
print(String(data:output,encoding:.utf8)!)
