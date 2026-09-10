import Observation
import AtollCore

@MainActor
@Observable
final class InteractionPresentation {
    static let shared = InteractionPresentation()
    private var presentation = RequestPresentation()

    var items: [RequestPresentation.Item] {
        InteractionCenter.shared.pending.map {
            .init(provider: .claude, requestID: $0.id, receivedAt: $0.receivedAt)
        } + CodexInteractionCenter.shared.pending.map {
            .init(provider: .codex, requestID: $0.id, receivedAt: $0.receivedAt)
        }
    }

    var current: RequestPresentation.ID? { presentation.current(in: items) }
    func refresh() { presentation.update(items) }
    func move(_ offset: Int) { presentation.move(offset, in: items) }
}
