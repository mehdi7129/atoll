import SwiftUI
import AtollCore

/// Vue de conversation dans l'îlot : transcript ASCII + composer.
struct ChatView: View {
    let driver: ChatDriver
    let colors: ThemeColors
    /// Composer actif seulement là où le focus clavier est accordé (écran primaire).
    let interactive: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            transcript
            if interactive {
                composer
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Text("‹ fermer")
                    .foregroundStyle(colors.accent)
            }
            .buttonStyle(.plain)
            Text(AsciiArt.sectionHeader("CHAT", width: 20))
                .foregroundStyle(colors.dim)
                .lineLimit(1)
            Text((driver.cwd as NSString).lastPathComponent)
                .foregroundStyle(colors.dim)
                .lineLimit(1)
            Spacer()
            stateBadge
        }
        .font(AtollFont.mono(10))
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch driver.state {
        case .starting:
            Text("[ démarrage ]").foregroundStyle(colors.dim)
        case .responding:
            AsciiSpinnerView(color: colors.accent)
        case .failed(let message):
            Text("[ \(message) ]").foregroundStyle(colors.warn).lineLimit(1)
        case .idle, .ready:
            EmptyView()
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if driver.turns.isEmpty {
                        Text(driver.resumedSessionID == nil
                             ? "· pose ta question à Claude dans ce dossier"
                             : "· reprise de la conversation — historique en chargement…")
                            .font(AtollFont.mono(10))
                            .foregroundStyle(colors.dim)
                    }
                    // Historique de la session reprise (atténué), puis le vif.
                    let history = driver.turns.filter(\.isHistory)
                    let live = driver.turns.filter { !$0.isHistory }
                    ForEach(history) { turn in
                        turnView(turn).id(turn.id)
                    }
                    if !history.isEmpty {
                        Text("──── reprise ────")
                            .font(AtollFont.mono(9))
                            .foregroundStyle(colors.dim)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(live) { turn in
                        turnView(turn).id(turn.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Prend toute la hauteur offerte par le panneau chat (plus haut).
            .frame(maxHeight: .infinity)
            // Défilement à la frontière de tour (pas à chaque token — moins coûteux).
            .onChange(of: driver.turns.count) { _, _ in
                if let last = driver.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onAppear {
                if let last = driver.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func turnView(_ turn: ChatDriver.Turn) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(turn.role == .user ? "› toi" : "‹ claude")
                .font(AtollFont.mono(9, weight: .bold))
                .foregroundStyle(
                    turn.isHistory ? colors.dim
                        : (turn.role == .user ? colors.accent : colors.ok))
            Text(turn.text.isEmpty && turn.streaming ? "…" : turn.text)
                .font(AtollFont.mono(11))
                .foregroundStyle(turn.isHistory ? colors.dim : colors.fg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Text("›")
                .foregroundStyle(colors.accent)
            TextField("message à Claude…", text: Binding(
                get: { driver.draft },
                set: { driver.draft = $0 }
            ), axis: .vertical)
                .textFieldStyle(.plain)
                .font(AtollFont.mono(11))
                .foregroundStyle(colors.fg)
                .lineLimit(1...4)
                .disabled(driver.state == .responding || driver.state == .starting)
                .onSubmit(sendMessage)
            if driver.state == .responding {
                Text("réponse en cours…")
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.dim)
            }
            AsciiButton(label: "⏎", color: canSend ? colors.ok : colors.dim, shortcut: nil) {
                sendMessage()
            }
            .disabled(!canSend)
        }
        .padding(8)
        .background(colors.surface)
    }

    private var canSend: Bool {
        !driver.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && driver.state == .ready
    }

    private func sendMessage() {
        guard canSend else { return }
        driver.send(driver.draft)
        driver.draft = ""
    }
}
