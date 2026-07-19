import AVFoundation
import Foundation
import Observation
import OSLog
import Speech

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "voice")

/// Dictée vocale locale pour le composer du chat : capture micro + Speech
/// framework EN LOCAL (`requiresOnDeviceRecognition`) — l'audio ne quitte
/// jamais le Mac (fidèle au « zéro télémétrie » du projet). Fail-open : toute
/// permission refusée ou indisponibilité laisse la frappe clavier intacte.
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

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    var isListening: Bool { state == .listening }

    /// Démarre l'écoute. Demande les autorisations au besoin (une fois).
    /// `onFinal` reçoit le texte transcrit quand l'écoute s'arrête.
    func start(onFinal: @escaping (String) -> Void) {
        guard state != .listening else { return }
        transcript = ""

        SFSpeechRecognizer.requestAuthorization { [weak self] speechAuth in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard speechAuth == .authorized else { self.state = .denied; return }
                    self.requestMicThenListen(onFinal: onFinal)
                }
            }
        }
    }

    private func requestMicThenListen(onFinal: @escaping (String) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] micGranted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard micGranted else { self.state = .denied; return }
                    self.beginListening(onFinal: onFinal)
                }
            }
        }
    }

    private func beginListening(onFinal: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else { state = .unavailable; return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Reconnaissance STRICTEMENT locale (pas de serveur Apple). Si la locale
        // ne la supporte pas, on le signale plutôt que d'envoyer l'audio ailleurs.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else {
            state = .unavailable
            return
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanup()
            state = .failed("micro indisponible")
            log.error("audioEngine: \(error.localizedDescription, privacy: .public)")
            return
        }
        state = .listening

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        let finalText = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.cleanup()
                        self.state = .idle
                        if !finalText.isEmpty { onFinal(finalText) }
                    }
                }
            }
        }
    }

    /// Arrête l'écoute (le résultat final arrive via le callback de start()).
    func stop() {
        guard state == .listening else { return }
        request?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func cleanup() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request = nil
        task = nil
    }
}
