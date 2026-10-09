
// Dans le même fichier temporaire pour appeler le vrai journal privé ; ni le
// compteur observable ni le callback SwiftUI ne sont manipulés par la fixture.
extension RetrospectiveRunner {
    func fixtureJournal(_ kind: String) {
        journal(AttemptRecord(sessionID: "recette-" + kind, decidedAt: Date(),
            decision: kind == "abstention" ? "skip(sessionTooShort)" : "run",
            outcome: kind == "success" ? "success(0n/0s)" : kind == "error" ? "failed(recette)" : nil,
            transcriptBytes: 100, quotaFraction: nil, quotaAgeSeconds: nil,
            failureReason: "RECETTE " + kind.uppercased()))
    }
}
