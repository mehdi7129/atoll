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

    /// Redessine les Pickers après un import ou une migration (les choix vivent
    /// dans UserDefaults, hors du graphe d'observation SwiftUI).
    @State private var revision = 0
    @State private var message: String?
    @State private var isError = false
    /// Prérequis de la migration Claude uniquement ; Codex sonne indépendamment.
    @State private var hooksInstalled = true

    @State private var previewMigration = CommandLine.arguments.first { $0.hasPrefix("--preview-sounds=") }
        .map { String($0.dropFirst("--preview-sounds=".count)) } ?? "none"
    @State private var previewChoices: [SoundEvent: SoundChoice] = [.decisionNeeded: .system("Glass"), .taskCompleted: .system("Pop")]
    @State private var previewVolumes: [SoundEvent: Double] = [:]

    private var center: SoundCenter { .shared }
    private var customSounds: [String] { CodexPreview.enabled ? [] : center.customSounds }
    private var systemSounds: [String] { CodexPreview.enabled ? ["Glass", "Pop", "Funk"] : center.systemSoundNames }
    private var parked: Bool { CodexPreview.enabled ? previewMigration == "parked" : center.isParked }
    private var unreadable: Bool { CodexPreview.enabled ? previewMigration == "unreadable" : center.isParkingUnreadable }
    private var detectedCommands: [String] {
        if CodexPreview.enabled { return previewMigration == "detected" ? ["PermissionRequest — afplay exemple.aiff"] : [] }
        return center.detectedHooks.map { "\($0.event) — \($0.command)" }
    }
    private func choice(_ event: SoundEvent) -> SoundChoice {
        CodexPreview.enabled ? previewChoices[event] ?? .silent : center.choice(for: event)
    }
    private func volume(_ event: SoundEvent) -> Double {
        CodexPreview.enabled ? previewVolumes[event] ?? SoundEvent.defaultVolume : center.volume(for: event)
    }

    var body: some View {
        Form {
            Section("Sons d'Atoll") {
                // L'écriture passe par le setter de SoundCenter, PAS par
                // `$soundsEnabled` : lui seul republie ~/.atoll/sound-settings.json,
                // le fichier que le helper lit pour sonner quand l'app est
                // fermée. Écrit directement, le réglage n'atteignait le helper
                // qu'au lancement suivant d'Atoll — donc « activer le son puis
                // quitter » rendait muet exactement le cas que ce dispositif
                // existe pour couvrir. La lecture reste en @AppStorage : c'est
                // elle qui redessine la vue.
                Toggle("Jouer des sons", isOn: Binding(
                    get: { soundsEnabled },
                    set: { if CodexPreview.enabled { soundsEnabled = $0 } else { center.soundsEnabled = $0 } }
                ))
                SettingsHelp("Pour Claude Code et Codex : un son quand une décision t'attend, un autre quand le CLI termine son tour.")
            }

            ForEach(SoundEvent.allCases, id: \.self) { event in
                Section(event.title) {
                    eventControls(event)
                }
                .disabled(!soundsEnabled)
            }

            migrationSection

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !CodexPreview.enabled { center.refreshLibraries() }
            if CodexPreview.enabled, CommandLine.arguments.contains("--preview-sound-missing") {
                previewChoices[.decisionNeeded] = .custom("son-absent.wav")
            }
            hooksInstalled = CodexPreview.enabled ? !CommandLine.arguments.contains("--preview-uninstalled") : HookInstaller.isInstalled
        }
    }

    // MARK: - Un événement

    @ViewBuilder
    private func eventControls(_ event: SoundEvent) -> some View {
        let current = choice(event)
        // Fichier importé puis disparu (~/.atoll effacé, ménage manuel) : sans
        // cette entrée, le Picker n'a AUCUN tag correspondant — il s'affiche
        // vide, « Écouter » reste actif et ne produit rien, et les sons sont
        // silencieux sans que rien ne le dise.
        let missingCustom: String? = {
            guard case .custom(let file) = current, !customSounds.contains(file) else { return nil }
            return file
        }()

        Picker("Son", selection: choiceBinding(for: event)) {
            Text("Silencieux").tag(SoundChoice.silent)
            if let missingCustom {
                Divider()
                Text("\(missingCustom) — fichier introuvable").tag(SoundChoice.custom(missingCustom))
            }
            if !customSounds.isEmpty {
                Divider()
                ForEach(customSounds, id: \.self) { file in
                    Text(file).tag(SoundChoice.custom(file))
                }
            }
            Divider()
            ForEach(systemSounds, id: \.self) { name in
                Text(name).tag(SoundChoice.system(name))
            }
        }
        .id(revision)
        .accessibilityIdentifier("sound-" + event.rawValue)

        if let missingCustom {
            Text("« \(missingCustom) » n'est plus dans ~/.atoll/sounds : cet événement est muet. "
                 + "Réimporte le fichier ou choisis un autre son.")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        HStack {
            Slider(value: volumeBinding(for: event), in: 0...1, step: 0.05) {
                Text("Volume")
            }
            Text("\(Int(volume(event) * 100)) %")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Button("Écouter") { if !CodexPreview.enabled { center.preview(event) } }
                .disabled(choice(event).isSilent || missingCustom != nil)
                .accessibilityIdentifier("sound-preview-" + event.rawValue)
        }

        Button("Importer un son…") { importSound(for: event) }
        SettingsHelp(event.explanation)
    }

    // MARK: - Migration des hooks de l'utilisateur

    @ViewBuilder
    private var migrationSection: some View {
        if unreadable {
            Section("Anciens sons de Claude Code") {
                Label("La sauvegarde des anciens sons est illisible.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                SettingsHelp("Tes hooks sonores sont peut-être encore mis de côté. Atoll conserve les données sans les modifier.")
                DisclosureGroup("Détails de la sauvegarde") {
                    SettingsHelp("Le fichier ~/.atoll/parked-sound-hooks.json doit être récupéré avant toute restauration. Conserve-en une copie pour retrouver les commandes.")
                        .textSelection(.enabled)
                }
            }
        } else if parked {
            // La restitution reste accessible même si l'intégration Claude a disparu.
            Section("Anciens sons de Claude Code") {
                Label("Atoll a repris tes anciens sons.", systemImage: "archivebox")
                Button("Restaurer les anciens sons Claude") { restoreHooks() }
                SettingsHelp("Remet tes hooks sonores dans Claude Code. Ils sont aussi restaurés au retrait de l'intégration.")
                DisclosureGroup("Détails de la sauvegarde") {
                    SettingsHelp("Les hooks d'origine sont conservés dans ~/.atoll/parked-sound-hooks.json.")
                }
            }
        } else if !detectedCommands.isEmpty {
            Section("Anciens sons de Claude Code") {
                SettingsHelp("\(detectedCommands.count) ancien(s) hook(s) Claude joue(nt) déjà un son. Atoll peut les reprendre pour éviter les doublons.")
                DisclosureGroup("Voir les sons détectés") {
                    ForEach(Array(detectedCommands.enumerated()), id: \.offset) { _, command in
                        Text(command).font(.system(.caption, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    SettingsHelp("Atoll copie les fichiers audio et met les hooks d'origine de côté. Leur restitution reste accessible à tout moment.")
                    if hooksInstalled {
                        Button("Confier ces sons à Atoll") { adoptHooks() }
                    }
                }
                if !hooksInstalled {
                    SettingsHelp("Installe l'intégration dans l'onglet Claude Code pour reprendre ces anciens sons. Les alertes Codex restent disponibles.")
                }
            }
        }
    }

    // MARK: - Actions

    private func adoptHooks() {
        guard !CodexPreview.enabled else { previewMigration = "parked"; soundsEnabled = true; return }
        // ORDRE IMPÉRATIF : parquer D'ABORD, adopter ENSUITE.
        //
        // L'adoption est persistante (elle copie des fichiers dans
        // ~/.atoll/sounds et réaffecte les deux choix) et le parking est la
        // seule des deux opérations qui peut échouer. Dans l'ordre inverse, un
        // parking en échec laissait les `afplay` de l'utilisateur en place
        // ALORS que les sons d'Atoll venaient d'être armés : si l'interrupteur
        // général était déjà actif, tout sonnait en double — l'invariant « un
        // seul des deux sonne » rompu — et le message d'erreur annonçait
        // pourtant que rien n'avait été modifié.
        //
        // `parkUserSoundHooks` se termine par `refreshLibraries()`, qui vide
        // `detectedHooks` (les hooks ne sont plus dans settings.json) : il faut
        // donc capturer l'instantané AVANT, sinon il n'y a plus rien à adopter.
        let detected = center.detectedHooks
        do {
            try center.parkUserSoundHooks()
            let (adopted, fallbacks) = center.adoptDetectedSounds(from: detected)
            center.soundsEnabled = true
            revision += 1
            isError = false
            // Un repli n'est PAS une reprise : annoncer « 2 sons repris » quand
            // les deux hooks étaient des `say`/`beep` était faux, et le message
            // honnête devenait inatteignable (revue des corrections).
            var phrases: [String] = []
            if adopted > 0 { phrases.append("\(adopted) son\(adopted > 1 ? "s" : "") repris") }
            if fallbacks > 0 {
                phrases.append("\(fallbacks) son\(fallbacks > 1 ? "s" : "") système mis à la place "
                               + "(rien à reprendre pour \(fallbacks > 1 ? "ces événements" : "cet événement"))")
            }
            message = phrases.isEmpty
                ? "Hooks mis de côté (tes événements avaient déjà un son)."
                : phrases.joined(separator: ", ") + ". Tes hooks sont mis de côté."
        } catch {
            isError = true
            message = "Échec : \(error.localizedDescription) — ton settings.json n'a pas été modifié."
        }
    }

    private func restoreHooks() {
        guard !CodexPreview.enabled else { previewMigration = "detected"; return }
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
        guard !CodexPreview.enabled else { message = "Import simulé : aucun fichier modifié."; return }
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
            get: { choice(event) },
            set: { newValue in
                if CodexPreview.enabled { previewChoices[event] = newValue; return }
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
            get: { volume(event) },
            set: {
                if CodexPreview.enabled { previewVolumes[event] = $0 }
                else { center.setVolume($0, for: event); revision += 1 }
            }
        )
    }
}
