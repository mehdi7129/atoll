import Foundation
import AtollCore
@MainActor final class SessionStore {
 static let shared=SessionStore()
 func markAutoApproved(_ id: String) {}
 func applyFleetSnapshot(_ infos:[AgentSessionInfo], available:Bool) {}
}
@MainActor final class SoundCenter {
 static let shared=SoundCenter()
 enum Event { case decisionNeeded }
 func play(_ event: Event) {}
}
class BridgeServer {
 var canceled:[String]=[]
 var replies:[String]=[]
 func reply(_ id:String, decision:Data) { replies.append(id) }
 func cancelPending(_ id:String) { canceled.append(id) }
}
