import Foundation

/// File commune d'affichage ; les centres de décision restent séparés.
public struct RequestPresentation: Sendable {
    public struct ID: Hashable, Sendable {
        public let provider: AgentProvider
        public let requestID: String
        public init(provider: AgentProvider, requestID: String) {
            self.provider = provider
            self.requestID = requestID
        }
    }
    public struct Item: Equatable, Sendable {
        public let id: ID
        public let receivedAt: Date
        public init(provider: AgentProvider, requestID: String, receivedAt: Date) {
            id = ID(provider: provider, requestID: requestID)
            self.receivedAt = receivedAt
        }
    }
    public private(set) var pinned: ID?
    private var decisionAfter = Date.distantPast
    public init() {}

    public func ordered(_ items: [Item]) -> [Item] {
        items.sorted {
            if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
            if $0.id.provider != $1.id.provider { return $0.id.provider.rawValue < $1.id.provider.rawValue }
            return $0.id.requestID < $1.id.requestID
        }
    }

    public func current(in items: [Item]) -> ID? {
        if let pinned, items.contains(where: { $0.id == pinned }) { return pinned }
        return ordered(items).first?.id
    }

    public mutating func update(_ items: [Item], now: Date = Date()) {
        let next = current(in: items)
        if let pinned, pinned != next, next != nil { decisionAfter = now.addingTimeInterval(0.4) }
        self.pinned = next
    }

    /// La résolution externe d'une carte ne doit pas transmettre une frappe
    /// déjà engagée à sa remplaçante. Le clic volontaire de navigation annule
    /// cette courte grâce, mais une arrivée en file ne change pas la cible.
    public func mayDecide(in items: [Item], now: Date = Date()) -> Bool {
        pinned != nil && pinned == current(in: items) && now >= decisionAfter
    }

    /// Navigation volontaire seulement ; aucune requête n'est résolue ici.
    public mutating func move(_ offset: Int, in items: [Item]) {
        decisionAfter = .distantPast
        let order = ordered(items)
        guard !order.isEmpty else { pinned = nil; return }
        let index = order.firstIndex(where: { $0.id == current(in: items) }) ?? 0
        pinned = order[((index + offset) % order.count + order.count) % order.count].id
    }
}
