import Foundation

// La curation est réelle ; seule la disponibilité du consommateur voisin est
// contrôlée ici. Les autres collaborateurs viennent des stubs runtime communs.
@MainActor final class RetrospectiveRunner {
    static let shared = RetrospectiveRunner()
    enum Phase { case idle, running }
    var phase: Phase = .idle
}
