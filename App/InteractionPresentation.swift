import Observation
import Foundation
import AtollCore

@MainActor
@Observable
final class InteractionPresentation {
    static let shared = InteractionPresentation()
    private var presentation = RequestPresentation()
    private var graceTask: Task<Void, Never>?
    private var graceElapsed = true

    var items: [RequestPresentation.Item] {
        InteractionCenter.shared.pending.map {
            .init(provider: .claude, requestID: $0.id, receivedAt: $0.receivedAt)
        } + CodexInteractionCenter.shared.pending.map {
            .init(provider: .codex, requestID: $0.id, receivedAt: $0.receivedAt)
        }
    }

    var current: RequestPresentation.ID? { presentation.current(in: items) }
    var mayDecide: Bool { graceElapsed && presentation.mayDecide(in: items) }
    func refresh() {
        presentation.update(items)
        graceTask?.cancel()
        graceElapsed = presentation.mayDecide(in: items)
        guard !graceElapsed, current != nil else { return }
        graceTask = Task {
            try? await Task.sleep(for: .milliseconds(410))
            guard !Task.isCancelled else { return }
            graceElapsed = true
        }
    }
    func move(_ offset: Int) {
        graceTask?.cancel()
        presentation.move(offset, in: items)
        graceElapsed = true
    }
}
