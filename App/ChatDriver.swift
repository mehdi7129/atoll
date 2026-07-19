import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "chat")

/// Pilote une conversation Claude depuis l'îlot : spawne un `claude -p` persistant
/// en stream-json bidirectionnel, écrit les messages sur stdin, lit les événements
/// sur stdout et expose un transcript observable.
@MainActor
@Observable
final class ChatDriver {

    struct Turn: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        var streaming: Bool
    }

    enum State: Equatable {
        case idle
        case starting
        case ready       // en attente d'un message
        case responding  // Claude répond
        case failed(String)
    }

    private(set) var turns: [Turn] = []
    private(set) var state: State = .idle
    private(set) var claudeSessionID: String?
    let cwd: String

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdinHandle: FileHandle?
    @ObservationIgnored private var stdoutBuffer = Data()

    init(cwd: String) {
        self.cwd = cwd
    }

    // MARK: - Cycle de vie

    /// Démarre le processus. `resume` = reprendre une session existante par id.
    func start(resume: String? = nil) {
        guard state == .idle else { return }
        guard let claudePath = ClaudeLocator.resolve() else {
            state = .failed("binaire claude introuvable")
            return
        }
        state = .starting

        let preChosenID = resume == nil ? UUID().uuidString : nil
        claudeSessionID = resume ?? preChosenID

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ChatProtocol.arguments(sessionID: preChosenID, resume: resume)
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeLocator.augmentedPATH
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdinHandle = stdinPipe.fileHandleForWriting

        // Lecture par thread dédié bloquant : plus fiable que readabilityHandler
        // dans une app LSUIElement (dont la run loop peut ne pas pomper le handler).
        let stdoutFD = stdoutPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let chunk = stdoutFD.availableData
                if chunk.isEmpty { break } // EOF
                Task { @MainActor in self?.ingest(chunk) }
            }
        }
        let stderrFD = stderrPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            let data = stderrFD.readDataToEndOfFile()
            if !data.isEmpty {
                log.error("claude stderr: \(String(decoding: data, as: UTF8.self), privacy: .public)")
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.processEnded(status: proc.terminationStatus) }
        }

        do {
            try process.run()
            self.process = process
            state = .ready
            log.info("chat démarré dans \(self.cwd, privacy: .public)")
        } catch {
            state = .failed("échec du lancement: \(error.localizedDescription)")
        }
    }

    /// Envoie un message utilisateur (démarre le processus si besoin).
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if state == .idle { start() }
        guard state == .ready || state == .responding, let stdinHandle else { return }

        turns.append(Turn(role: .user, text: trimmed, streaming: false))
        turns.append(Turn(role: .assistant, text: "", streaming: true))
        state = .responding

        let data = ChatProtocol.userMessage(trimmed)
        do {
            try stdinHandle.write(contentsOf: data)
            log.info("message écrit (\(data.count) octets)")
        } catch {
            log.error("écriture stdin échouée: \(error.localizedDescription, privacy: .public)")
            state = .failed("écriture impossible: \(error.localizedDescription)")
        }
    }

    func stop() {
        stdinHandle?.closeFile()
        stdinHandle = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        if case .failed = state {} else { state = .idle }
    }

    // MARK: - Lecture du flux

    private func ingest(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        // Découper sur les sauts de ligne (NDJSON).
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            if let event = StreamEvent(line: Data(lineData)) {
                handle(event)
            }
        }
    }

    private func handle(_ event: StreamEvent) {
        switch event {
        case .initialized(let sessionID, _):
            if !sessionID.isEmpty { claudeSessionID = sessionID }
        case .textDelta(let text):
            appendToCurrentAssistant(text)
        case .thinkingDelta:
            break // le raisonnement n'est pas affiché en v1
        case .assistantText(let full):
            // Si aucun delta n'est arrivé (mode non-partiel), poser le texte complet.
            if let index = currentAssistantIndex, turns[index].text.isEmpty {
                turns[index].text = full
            }
        case .result(let text, _, let isError):
            finishAssistant(fallback: text, isError: isError)
        case .rateLimit, .other:
            break
        }
    }

    private var currentAssistantIndex: Int? {
        turns.lastIndex(where: { $0.role == .assistant && $0.streaming })
    }

    private func appendToCurrentAssistant(_ text: String) {
        guard let index = currentAssistantIndex else { return }
        turns[index].text += text
    }

    private func finishAssistant(fallback: String?, isError: Bool) {
        if let index = currentAssistantIndex {
            if turns[index].text.isEmpty, let fallback { turns[index].text = fallback }
            if turns[index].text.isEmpty, isError { turns[index].text = "· (erreur ou tour vide)" }
            turns[index].streaming = false
        }
        state = .ready
    }

    private func processEnded(status: Int32) {
        if let index = currentAssistantIndex {
            turns[index].streaming = false
            if turns[index].text.isEmpty { turns[index].text = "· (session terminée)" }
        }
        process = nil
        stdinHandle = nil
        if case .failed = state {} else { state = .idle }
    }
}
