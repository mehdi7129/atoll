import SwiftUI
import AtollCore

/// Carte d'autorisation **Codex**. Vue dédiée, comme le centre qui la nourrit.
///
/// Elle ressemble à celle de Claude, et c'est voulu — passer d'un agent à
/// l'autre doit être transparent. Mais elle ne partage pas son code : la carte
/// Claude porte des cas que Codex n'a pas (plans, questions à options) et une
/// auto-approbation Rockstar qui ne doit jamais s'appliquer ici.
///
/// TROIS DIFFÉRENCES ASSUMÉES avec la carte Claude, chacune imposée par le
/// contrat du hook Codex :
/// 1. **Aucun « toujours autoriser »** : le hook ne promet qu'une décision pour
///    la demande courante, jamais une modification durable de la politique.
///    Proposer un tel bouton mentirait sur ce qu'Atoll peut faire.
/// 2. **Un bouton « DÉCIDER DANS CODEX »**, qui rend la main proprement. C'est
///    la seule façon de faire apparaître l'invite native : tant que cette carte
///    est là, Codex la retient.
/// 3. **« Autorisé » ne veut pas dire « exécuté »** : si un autre hook refuse,
///    le refus l'emporte. La carte disparaît sans rien affirmer de plus.
struct CodexInteractionCardView: View {
    let request: CodexInteractionCenter.Pending
    let colors: ThemeColors

    private var center: CodexInteractionCenter { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("!")
                    .fontWeight(.bold)
                    .foregroundStyle(colors.warn)
                // Le badge fournisseur EN TÊTE : sur un îlot qui montre les deux
                // agents, savoir lequel demande est la première information.
                Text("CODEX")
                    .fontWeight(.bold)
                    .foregroundStyle(colors.accent)
                Text("· \(request.projectName)")
                    .foregroundStyle(colors.dim)
                    .lineLimit(1)
                Spacer()
                Text(AsciiArt.rule(12))
                    .foregroundStyle(colors.dim)
            }
            .font(AtollFont.mono(11))

            Text(request.tool)
                .font(AtollFont.mono(11))
                .foregroundStyle(colors.fg)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text(request.permission.cwd)
                .font(AtollFont.mono(9))
                .foregroundStyle(colors.dim)
                .lineLimit(1)
                .help(request.permission.cwd)

            if let agent = request.agentID {
                Text("Sous-agent \(agent) · session parente \(request.sessionID)")
                    .font(AtollFont.mono(9)).foregroundStyle(colors.dim)
                    .lineLimit(1).help("Sous-agent \(agent), parent \(request.sessionID)")
            }

            ScrollView([.vertical, .horizontal]) {
                Text(request.permission.details)
                    .font(AtollFont.mono(10))
                    .foregroundStyle(colors.fg)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(6)
            }
            .frame(height: 140)
            .accessibilityLabel("Détails complets de la demande Codex")

            Text("Codex attend ta décision. Elle ne vaut que pour cette demande.")
                .font(AtollFont.mono(9))
                .foregroundStyle(colors.dim)

            HStack(spacing: 12) {
                AsciiButton(label: "REFUSER ⌘N", color: colors.warn, shortcut: nil) {
                    center.decide(request.id, .deny(message: nil))
                }
                AsciiButton(label: "AUTORISER ⌘Y", color: colors.accent, shortcut: nil) {
                    center.decide(request.id, .allow)
                }
                Spacer()
                // Rendre la main : la carte part, PUIS la connexion se ferme
                // sans réponse — c'est cet ordre qui évite deux interfaces
                // affichées en même temps.
                AsciiButton(label: "DÉCIDER DANS CODEX", color: colors.dim, shortcut: nil) {
                    center.handBack(request.id)
                }
            }

            if center.pending.count > 1 {
                // Deux outils peuvent demander en parallèle. On l'ANNONCE plutôt
                // que de fusionner les demandes : répondre à l'une par la
                // décision de l'autre serait une faute de sûreté.
                Text("+\(center.pending.count - 1) autre(s) demande(s) Codex en attente")
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.dim)
            }
        }
        .keyboardShortcut(.defaultAction)
        .background {
            // Raccourcis, comme la carte Claude : ⌘Y autorise, ⌘N refuse.
            Button("") { center.decide(request.id, .allow) }
                .keyboardShortcut("y", modifiers: .command).hidden()
            Button("") { center.decide(request.id, .deny(message: nil)) }
                .keyboardShortcut("n", modifiers: .command).hidden()
        }
    }
}
