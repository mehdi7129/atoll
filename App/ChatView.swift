import AppKit
import SwiftUI
import AtollCore

/// Vue de conversation dans l'îlot : transcript ASCII + composer.
struct ChatView: View {
    let driver: ChatDriver
    let colors: ThemeColors
    /// Composer actif seulement là où le focus clavier est accordé (écran primaire).
    let interactive: Bool
    let onClose: () -> Void

    /// Dictée vocale (locale) : une instance par vue de chat.
    @State private var voice = VoiceDictation()
    /// Moniteur clavier local du push-to-talk (espace maintenu).
    @State private var pttMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            transcript
            if interactive {
                composer
            }
        }
        // Chat fermé/remplacé pendant une dictée : couper le micro (sinon le tap
        // audio et la reconnaissance resteraient actifs — micro allumé fantôme).
        .onDisappear {
            voice.stop()
            removePushToTalk()
        }
        .onAppear {
            if interactive { installPushToTalk() }
        }
        #if DEBUG
        // Test scripté du micro (crash installTap) : notifyutil …debug.voice
        // démarre la dictée 3 s puis l'arrête.
        .onReceive(NotificationCenter.default.publisher(for: .atollDebugVoice)) { _ in
            guard interactive, !voice.isListening else { return }
            voice.start { text in driver.draft = text }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { voice.stop() }
        }
        #endif
    }

    // MARK: - Push-to-talk (espace maintenu)

    /// Installe le moniteur clavier LOCAL (aucune permission d'accessibilité :
    /// il ne voit que les touches destinées à Atoll quand le chat a le focus).
    /// Règle anti-conflit avec la frappe : l'espace ne déclenche la voix QUE si
    /// le composer est VIDE — dès qu'un texte est saisi, l'espace se tape
    /// normalement. Maintenir l'espace = parler ; relâcher = transcrire.
    private func installPushToTalk() {
        guard pttMonitor == nil else { return }
        pttMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            MainActor.assumeIsolated {
                handlePushToTalk(event)
            }
        }
    }

    private func removePushToTalk() {
        if let monitor = pttMonitor { NSEvent.removeMonitor(monitor) }
        pttMonitor = nil
        voice.pttHeld = false
    }

    /// Retourne nil pour AVALER l'événement (espace consommé par la voix), ou
    /// l'événement pour le laisser suivre son cours (frappe normale).
    private func handlePushToTalk(_ event: NSEvent) -> NSEvent? {
        let spaceKeyCode: UInt16 = 49
        guard event.keyCode == spaceKeyCode else { return event }

        if event.type == .keyDown {
            if voice.isListening { return voice.pttHeld ? nil : event } // auto-repeat
            let composerEmpty = driver.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let canDictate = composerEmpty && driver.state == .ready
            guard canDictate else { return event } // texte présent → espace normal
            voice.pttHeld = true
            let base = driver.draft
            voice.start { text in
                driver.draft = base.isEmpty ? text : base + " " + text
            }
            return nil
        }

        // keyUp
        if voice.pttHeld {
            voice.pttHeld = false
            voice.stop()
            return nil
        }
        return event
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
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
            // Reprise = FORK : on parle à une COPIE, la session du terminal
            // continue séparément. Le dire clairement évite la confusion.
            if driver.resumedSessionID != nil {
                Text("⑂ copie de la session — le terminal continue à part")
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.warn)
                    .lineLimit(1)
            }
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
                        Text(emptyStateMessage)
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

    /// Message d'état vide, honnête selon reprise / chargement / historique absent.
    private var emptyStateMessage: String {
        guard driver.resumedSessionID != nil else {
            return "· pose ta question à Claude dans ce dossier"
        }
        if !driver.historyLoadAttempted {
            return "· reprise de la conversation — historique en chargement…"
        }
        return "· reprise — pas d'historique lisible, continue la conversation"
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
        VStack(alignment: .leading, spacing: 2) {
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
                micButton
                AsciiButton(label: "⏎", color: canSend ? colors.ok : colors.dim, shortcut: nil) {
                    sendMessage()
                }
                .disabled(!canSend)
            }
            if let voiceHint {
                Text(voiceHint)
                    .font(AtollFont.mono(9))
                    .foregroundStyle(voice.isListening ? colors.accent : colors.warn)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(colors.surface)
    }

    /// Micro : appuie pour dicter, appuie encore pour arrêter. Le texte transcrit
    /// (en local) remplit le composer — l'utilisateur relit avant d'envoyer.
    private var micButton: some View {
        AsciiButton(label: voice.isListening ? "◉" : "🎤",
                    color: voice.isListening ? colors.accent : colors.dim,
                    shortcut: nil) {
            if voice.isListening {
                voice.stop()
            } else {
                let base = driver.draft
                voice.start { text in
                    // Ajoute au brouillon existant (ne l'écrase pas).
                    driver.draft = base.isEmpty ? text : base + " " + text
                }
            }
        }
        .disabled(driver.state == .responding || driver.state == .starting)
    }

    /// Indication sous le composer selon l'état de la dictée.
    private var voiceHint: String? {
        switch voice.state {
        case .idle:
            // Astuce push-to-talk visible quand le composer est vide et prêt.
            let empty = driver.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (empty && driver.state == .ready) ? "espace maintenu ou 🎤 pour dicter" : nil
        case .listening:
            let partial = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return partial.isEmpty ? "◉ à l'écoute — parle, relâche pour terminer" : "◉ " + partial
        case .denied:
            return "micro/reconnaissance refusés — Réglages › Confidentialité"
        case .unavailable:
            return "dictée locale indisponible pour le français sur ce Mac"
        case .failed(let message):
            return message
        }
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
