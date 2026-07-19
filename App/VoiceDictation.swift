import AVFoundation
import Foundation
import Observation
import OSLog
import Speech

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "voice")

/// Dictée vocale locale pour le composer du chat : capture micro + Speech
/// framework EN LOCAL (`requiresOnDeviceRecognition`) — l'audio ne quitte
/// jamais le Mac (fidèle au « zéro télémétrie » du projet). Fail-open : toute
/// permission refusée ou indisponibilité laisse la frappe clavier intacte, et
/// AUCUNE erreur de configuration audio ne doit faire planter l'app (le tap
/// AVAudioEngine appelle abort() sur format invalide — on garde en amont).
@MainActor
@Observable
final class VoiceDictation {

    enum State: Equatable {
        case idle
        case listening
        case denied           // micro ou reconnaissance refusé par l'utilisateur
        case unavailable      // pas de reconnaissance locale pour la locale
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Texte transcrit en direct (partiel puis final).
    private(set) var transcript = ""
    /// L'écoute a-t-elle été déclenchée par l'espace maintenu ? Porté ici (objet
    /// de référence) pour que le moniteur clavier lise/écrive un état VIVANT (un
    /// @State capturé dans la closure du moniteur serait figé/copié).
    @ObservationIgnored var pttHeld = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    // Un moteur NEUF par session : après le tout premier octroi de permission,
    // un moteur créé avant voit encore un format d'entrée invalide (0 canal).
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var onFinal: ((String) -> Void)?

    var isListening: Bool { state == .listening }

    /// Démarre l'écoute. Demande les autorisations au besoin (une fois).
    /// `onFinal` reçoit le texte transcrit quand l'écoute s'arrête.
    func start(onFinal: @escaping (String) -> Void) {
        guard state != .listening else { return }
        transcript = ""
        self.onFinal = onFinal

        SFSpeechRecognizer.requestAuthorization { [weak self] speechAuth in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard speechAuth == .authorized else { self.state = .denied; return }
                    self.requestMicThenListen()
                }
            }
        }
    }

    private func requestMicThenListen() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] micGranted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard micGranted else { self.state = .denied; return }
                    // Léger différé : laisse le sous-système audio publier un
                    // format d'entrée VALIDE après le tout premier octroi (sinon
                    // installTap abort()). Sans effet sur les usages suivants.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        MainActor.assumeIsolated { self.beginListening() }
                    }
                }
            }
        }
    }

    private func beginListening() {
        guard state != .listening else { return }
        guard let recognizer, recognizer.isAvailable else { state = .unavailable; return }
        guard recognizer.supportsOnDeviceRecognition else {
            // Pas de modèle local pour le français sur ce Mac : on REFUSE plutôt
            // que d'envoyer l'audio aux serveurs Apple (zéro télémétrie).
            state = .unavailable
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Format HARDWARE réel du micro : passer un format divergent à installTap
        // déclenche un abort() (le crash observé). Vérifier sa validité AVANT.
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            state = .failed("micro indisponible (aucune entrée audio)")
            log.error("format d'entrée invalide: \(format)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state = .failed("micro indisponible")
            log.error("audioEngine: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.audioEngine = engine
        state = .listening

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        self.deliverFinal()
                    }
                }
            }
        }
    }

    /// Arrête l'écoute (le résultat final arrive via le callback de start()).
    func stop() {
        guard state == .listening else { return }
        request?.endAudio()
        // Certaines locales ne renvoient jamais isFinal après endAudio : on
        // livre nous-mêmes le texte accumulé et on démonte le moteur.
        deliverFinal()
    }

    private func deliverFinal() {
        let finalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanup()
        if state == .listening { state = .idle }
        if !finalText.isEmpty { onFinal?(finalText) }
        onFinal = nil
    }

    private func cleanup() {
        if let engine = audioEngine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        task?.cancel()
        task = nil
        request = nil
    }
}
