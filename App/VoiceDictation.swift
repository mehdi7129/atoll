import AVFoundation
import Foundation
import Observation
import OSLog
import Speech

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "voice")

/// Dictée vocale locale pour le composer du chat : capture micro + Speech
/// framework EN LOCAL (`requiresOnDeviceRecognition`) — l'audio ne quitte
/// jamais le Mac (fidèle au « zéro télémétrie » du projet).
///
/// Points DURS de la reconnaissance on-device (corrigés ici) :
/// - le modèle local a un CONTEXTE COURT : sur une longue phrase il finalise
///   des segments (isFinal) et sa transcription ne reflète plus que le segment
///   courant → on ACCUMULE les segments finalisés et on relance une requête
///   pour continuer, sinon on ne garde que « la fin » de ce qui est dit ;
/// - `installTap` appelle abort() sur format invalide → format hardware validé
///   avant usage ; toute erreur reste gracieuse (jamais de crash).
@MainActor
@Observable
final class VoiceDictation {

    enum State: Equatable {
        case idle
        case listening
        case denied           // micro ou reconnaissance refusé
        case unavailable      // pas de reconnaissance locale pour la locale
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Texte affiché en direct : segments finalisés + partiel courant.
    private(set) var transcript = ""
    /// L'écoute a-t-elle été déclenchée par l'espace maintenu ? (moniteur clavier)
    @ObservationIgnored var pttHeld = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var onFinal: ((String) -> Void)?
    /// Segments déjà finalisés par le modèle (le partiel courant s'y ajoute).
    @ObservationIgnored private var accumulated = ""
    /// L'utilisateur a demandé l'arrêt : le prochain final livre et démonte.
    @ObservationIgnored private var stopping = false

    var isListening: Bool { state == .listening }

    /// Démarre l'écoute. Demande les autorisations au besoin (une fois).
    /// `onFinal` reçoit le texte COMPLET transcrit quand l'écoute s'arrête.
    func start(onFinal: @escaping (String) -> Void) {
        guard state != .listening else { return }
        transcript = ""
        accumulated = ""
        stopping = false
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
                    // Léger différé : format d'entrée valide après le 1er octroi.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        MainActor.assumeIsolated { self.beginListening() }
                    }
                }
            }
        }
    }

    private func beginListening() {
        guard state != .listening else { return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            state = .unavailable // pas de modèle local → on refuse (zéro télémétrie)
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            state = .failed("micro indisponible (aucune entrée audio)")
            log.error("format d'entrée invalide: \(format)")
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Alimente TOUJOURS la requête courante (elle change entre segments).
            self?.request?.append(buffer)
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
        audioEngine = engine
        state = .listening
        startSegment()
    }

    /// Ouvre une nouvelle requête/tâche de reconnaissance (segment) sur le
    /// moteur audio déjà en marche.
    private func startSegment() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(result: result, error: error) }
            }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard state == .listening else { return }
        if let result {
            let partial = result.bestTranscription.formattedString
            transcript = join(accumulated, partial)

            if result.isFinal {
                accumulated = transcript // le segment devient définitif
                if stopping {
                    deliverFinal()
                } else {
                    // Le modèle a bouclé un segment mais l'utilisateur parle
                    // encore : relancer pour ne pas perdre la suite.
                    startSegment()
                }
            }
        } else if error != nil {
            // Erreur (souvent après endAudio) : livrer ce qu'on a.
            deliverFinal()
        }
    }

    /// Arrête l'écoute. Le texte final arrive via le callback (isFinal après
    /// endAudio) ; filet de sécurité si ce final n'arrive jamais.
    func stop() {
        guard state == .listening else { return }
        stopping = true
        request?.endAudio()
        // Filet : certaines locales ne renvoient pas d'isFinal après endAudio.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .listening else { return }
                self.deliverFinal()
            }
        }
    }

    private func deliverFinal() {
        let finalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = onFinal
        cleanup()
        state = .idle
        if !finalText.isEmpty { callback?(finalText) }
    }

    private func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespaces)
        let right = b.trimmingCharacters(in: .whitespaces)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
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
        onFinal = nil
        pttHeld = false
    }
}
