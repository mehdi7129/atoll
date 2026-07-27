import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AtollCore

/// Onglet « Alertes » : les deux sons d'Atoll et l'annonce de fin de tâche.
///
/// Tout est OPT-IN et réversible. La partie délicate est en bas : reprendre les
/// hooks sonores que l'utilisateur avait posés dans son `settings.json` — on les
/// MONTRE avant d'y toucher, et le bouton de restitution reste visible tant
/// qu'ils sont chez nous.
struct AlertsPane: View {
    @AppStorage(SoundCenter.enabledKey) private var soundsEnabled = false
    @AppStorage(TaskCompletionNotifier.notifyKey) private var notifyOnCompletion = true

    /// Redessine les Pickers après un import ou une migration (les choix vivent
    /// dans UserDefaults, hors du graphe d'observation SwiftUI).
    @State private var revision = 0
    @State private var message: String?
    @State private var isError = false
    /// Les hooks Atoll sont-ils installés ? Sans eux, aucun événement n'arrive
    /// et aucun son ne peut être joué : la migration n'aurait aucun sens.
    @State private var hooksInstalled = true

    private var center: SoundCenter { .shared }
    private var notifier: TaskCompletionNotifier { .shared }

    var body: some View {
        Form {
            Section("Sons") {
                Toggle("Jouer des sons", isOn: $soundsEnabled)
                Text("""
                Atoll se signale à l'oreille à deux moments : quand une décision \
                t'attend, et quand une session a fini de travailler. Deux sons \
                distincts, réglables séparément.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // La migration passe AVANT le réglage fin des sons : quand des
            // hooks sont détectés, c'est LE geste à faire en premier — enterré
            // sous deux sections de curseurs, il ne serait jamais vu.
            migrationSection

            ForEach(SoundEvent.allCases, id: \.self) { event in
                Section(event.title) {
                    eventControls(event)
                }
                .disabled(!soundsEnabled)
            }

            Section("Fin de tâche") {
                Toggle("Notification quand une tâche lancée depuis le notch se termine",
                       isOn: $notifyOnCompletion)
                Text("""
                Une notification macOS avec un résumé d'une ligne — clique dessus \
                pour ouvrir la session. Ne concerne QUE les tâches lancées depuis \
                l'îlot : jamais tes sessions interactives. L'îlot garde de toute \
                façon une trace visible jusqu'à ce que tu l'écartes.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                // Un refus de macOS doit se VOIR ici : sans cela, la fonction
                // paraît simplement cassée (c'est ainsi qu'on a découvert que
                // les builds signés « adhoc » sont refusés d'office).
                if let explanation = notifier.authorization.explanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(notifier.authorization == .granted
                                         ? Color.secondary : Color.orange)
                    // Les deux chemins restent offerts tant que ce n'est pas
                    // accordé : « refusé » peut aussi vouloir dire « jamais
                    // inscrit » (c'est l'appel à la demande qui inscrit l'app),
                    // auquel cas le bouton de demande suffit.
                    HStack {
                        Button("Autoriser les notifications") {
                            notifier.requestAuthorization()
                        }
                        Button("Ouvrir les Réglages système…") {
                            notifier.openSystemNotificationSettings()
                        }
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            center.refreshLibraries()
            notifier.refreshAuthorization()
            hooksInstalled = HookInstaller.isInstalled
        }
    }

    // MARK: - Un événement

    @ViewBuilder
    private func eventControls(_ event: SoundEvent) -> some View {
        Picker("Son", selection: choiceBinding(for: event)) {
            Text("Silencieux").tag(SoundChoice.silent)
            if !center.customSounds.isEmpty {
                Divider()
                ForEach(center.customSounds, id: \.self) { file in
                    Text(file).tag(SoundChoice.custom(file))
                }
            }
            Divider()
            ForEach(center.systemSoundNames, id: \.self) { name in
                Text(name).tag(SoundChoice.system(name))
            }
        }
        .id(revision)

        HStack {
            Slider(value: volumeBinding(for: event), in: 0...1, step: 0.05) {
                Text("Volume")
            }
            Text("\(Int(center.volume(for: event) * 100)) %")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Button("Écouter") { center.preview(event) }
                .disabled(center.choice(for: event).isSilent)
        }

        Button("Importer un son…") { importSound(for: event) }
        Text(event.explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Migration des hooks de l'utilisateur

    @ViewBuilder
    private var migrationSection: some View {
        if center.isParkingUnreadable {
            Section("Tes sons Claude Code") {
                Label("Le fichier de parking est illisible.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("""
                Tes hooks sonores sont peut-être encore mis de côté dans \
                ~/.atoll/parked-sound-hooks.json, mais Atoll n'arrive plus à le lire. \
                Il refuse d'y toucher pour ne rien perdre : ouvre ce fichier pour en \
                récupérer les commandes, puis supprime-le.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else if !hooksInstalled {
            // Parquer sans les hooks Atoll = silence total pour zéro bénéfice
            // (Atoll ne reçoit aucun événement, donc ne joue rien).
            Section("Tes sons Claude Code") {
                Text("""
                Installe d'abord les hooks Atoll (onglet Claude Code) : sans eux, Atoll \
                ne reçoit aucun événement et ne pourrait jouer aucun son — reprendre tes \
                hooks maintenant te laisserait simplement en silence.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else if center.isParked {
            Section("Tes sons Claude Code") {
                Label("Tes hooks sonores sont mis de côté par Atoll.", systemImage: "archivebox")
                Text("""
                Ils sont conservés intacts dans ~/.atoll/parked-sound-hooks.json et \
                seront remis à l'identique — automatiquement si tu désinstalles les \
                hooks d'Atoll, ou tout de suite avec ce bouton.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Rendre mes hooks sonores") { restoreHooks() }
            }
        } else if !center.detectedHooks.isEmpty {
            Section("Tes sons Claude Code") {
                Text("""
                \(center.detectedHooks.count) hook\(center.detectedHooks.count > 1 ? "s" : "") \
                de ton settings.json joue\(center.detectedHooks.count > 1 ? "nt" : "") déjà un son :
                """)
                ForEach(center.detectedHooks, id: \.hookJSON) { hook in
                    Text("· \(hook.event) — \(hook.command)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("""
                Atoll peut reprendre ces sons à son compte : il copie tes fichiers \
                audio, les affecte aux deux événements, puis met tes hooks de côté \
                pour que tu n'entendes pas tout en double. Rien n'est supprimé — la \
                restitution reste à un clic, et se fait aussi toute seule à la \
                désinstallation.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Confier ces sons à Atoll") { adoptHooks() }
            }
        }
    }

    // MARK: - Actions

    private func adoptHooks() {
        let adopted = center.adoptDetectedSounds()
        do {
            try center.parkUserSoundHooks()
            soundsEnabled = true
            revision += 1
            isError = false
            message = adopted > 0
                ? "\(adopted) son\(adopted > 1 ? "s" : "") repris. Tes hooks sont mis de côté."
                : "Hooks mis de côté (aucun fichier audio lisible à reprendre)."
        } catch {
            isError = true
            message = "Échec : \(error.localizedDescription) — ton settings.json n'a pas été modifié."
        }
    }

    private func restoreHooks() {
        do {
            try center.restoreUserSoundHooks()
            isError = false
            message = "Tes hooks sonores sont revenus dans settings.json."
        } catch {
            isError = true
            message = "Échec de la restitution : \(error.localizedDescription)"
        }
    }

    private func importSound(for event: SoundEvent) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Importer"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let name = try center.importSound(from: url)
            center.setChoice(.custom(name), for: event)
            revision += 1
            isError = false
            message = "« \(name) » importé."
            center.preview(event)
        } catch {
            isError = true
            message = "Import impossible : \(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        guard let importError = error as? SoundImport.ImportError else {
            return error.localizedDescription
        }
        switch importError {
        case .unsupportedFormat(let ext):
            return "format « \(ext) » non pris en charge (aiff, wav, mp3, m4a, caf)."
        case .tooLarge(let bytes):
            return "fichier trop lourd (\(bytes / 1_048_576) Mo, maximum 10 Mo)."
        case .unreadable:
            return "fichier illisible."
        }
    }

    // MARK: - Liaisons

    private func choiceBinding(for event: SoundEvent) -> Binding<SoundChoice> {
        Binding(
            get: { center.choice(for: event) },
            set: { newValue in
                center.setChoice(newValue, for: event)
                revision += 1
                // Écouter tout de suite ce qu'on vient de choisir : sans cela il
                // faut deviner à quoi « Sosumi » ressemble.
                if !newValue.isSilent { center.preview(event) }
            }
        )
    }

    private func volumeBinding(for event: SoundEvent) -> Binding<Double> {
        Binding(
            get: { center.volume(for: event) },
            set: { center.setVolume($0, for: event); revision += 1 }
        )
    }
}
