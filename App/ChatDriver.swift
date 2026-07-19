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
        /// Tour chargé du transcript de la session reprise (rendu atténué).
        var isHistory: Bool = false
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
    /// Session dont ce chat est la reprise (fork `--resume`), nil pour un chat neuf.
    private(set) var resumedSessionID: String?
    /// Brouillon du composer — porté par le driver (survit à la reconstruction de
    /// la vue, à une carte qui interrompt, au repli de l'îlot).
    var draft: String = ""
    let cwd: String

    /// Au-delà, on replie les plus anciens tours (borne mémoire).
    private let maxTurns = 200

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdinFD: Int32 = -1

    init(cwd: String) {
        self.cwd = cwd
    }

    // MARK: - Cycle de vie

    /// Démarre le processus. Seule la résolution du binaire (potentiellement lente,
    /// shell de login) part hors du thread principal ; le spawn et le câblage des
    /// pipes/reader se font sur le main actor (fiable, comme la version validée).
    func start(resume: String? = nil) {
        guard state == .idle else { return }
        state = .starting
        resumedSessionID = resume
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let path = ClaudeLocator.resolve()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.spawn(path: path, resume: resume) } }
        }
    }

    /// Précharge l'historique de la session reprise EN TÊTE du transcript
    /// (l'utilisateur a pu envoyer un message avant la fin du chargement).
    func preloadHistory(_ history: [TranscriptHistory.HistoryTurn]) {
        guard !history.isEmpty else { return }
        let loaded = history.map { turn in
            Turn(role: turn.role == .user ? .user : .assistant,
                 text: turn.text, streaming: false, isHistory: true)
        }
        turns.insert(contentsOf: loaded, at: 0)
        trimTurns()
    }

    private func spawn(path: String?, resume: String?) {
        guard state == .starting else { return }
        guard let claudePath = path else {
            state = .failed("binaire claude introuvable")
            return
        }
        let preChosenID = resume == nil ? UUID().uuidString : nil
        claudeSessionID = resume ?? preChosenID

        // Spawn via un shell de login (`zsh -l -c "exec claude …"`) : claude hérite
        // de nos pipes mais tourne dans un contexte identique au terminal (où il
        // fonctionne) — un spawn direct depuis l'app GUI le laisse muet.
        func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let claudeArgs = ChatProtocol.arguments(sessionID: preChosenID, resume: resume)
        let command = "exec " + ([claudePath] + claudeArgs).map(shellQuote).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeLocator.augmentedPATH
        process.environment = env

        // Pipes POSIX explicites : je contrôle chaque descripteur (les Pipe/
        // FileHandle de Foundation croisaient les fds sous concurrence — vérifié
        // à l'lsof : le reader lisait le pipe stdin).
        var inFDs: [Int32] = [-1, -1]   // [0]=lecture (enfant), [1]=écriture (nous)
        var outFDs: [Int32] = [-1, -1]  // [0]=lecture (nous), [1]=écriture (enfant)
        guard pipe(&inFDs) == 0, pipe(&outFDs) == 0 else {
            state = .failed("création des pipes impossible")
            return
        }
        let inRead = inFDs[0], inWrite = inFDs[1]
        let outRead = outFDs[0], outWrite = outFDs[1]

        // close-on-exec sur TOUS les fds : le dup2 de posix_spawn pose stdin/stdout
        // proprement, mais l'enfant (et ses sous-processus de hooks) ne doit PAS
        // hériter de nos autres descripteurs (socket du bridge, extrémités de
        // pipe…) — sinon des blocages/EOF fantômes.
        for fd in [inRead, inWrite, outRead, outWrite] {
            fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
        }

        process.standardInput = FileHandle(fileDescriptor: inRead, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: outWrite, closeOnDealloc: false)
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            [inRead, inWrite, outRead, outWrite].forEach { close($0) }
            state = .failed("échec du lancement: \(error.localizedDescription)")
            return
        }

        // L'enfant a dupliqué ses extrémités : fermer NOS copies des extrémités
        // côté enfant, sinon EOF ne se propage jamais.
        close(inRead)
        close(outWrite)

        self.process = process
        self.stdinFD = inWrite
        state = .ready
        log.info("chat démarré dans \(self.cwd, privacy: .public)")

        // Lecture stdout par read(2) direct sur outRead (fd sous notre contrôle).
        // Découpage NDJSON ici (séquentiel) ; événements livrés au main en FIFO.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(outRead, &chunk, chunk.count)
                if count <= 0 { break } // EOF ou erreur
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let event = StreamEvent(line: lineData) else { continue }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
                }
            }
            close(outRead)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.readerFinished() } }
        }
    }

    /// Envoie un message utilisateur. REFUSÉ pendant une réponse en cours (sinon
    /// les fragments du 1er tour iraient dans la mauvaise bulle).
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard state == .ready, stdinFD >= 0 else { return }

        turns.append(Turn(role: .user, text: trimmed, streaming: false))
        turns.append(Turn(role: .assistant, text: "", streaming: true))
        trimTurns()
        state = .responding

        let data = ChatProtocol.userMessage(trimmed)
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(stdinFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { if errno == EINTR { continue }; return false }
                offset += written
            }
            return true
        }
        if !ok {
            log.error("écriture stdin échouée (errno \(errno))")
            state = .failed("écriture impossible")
        }
    }

    func stop() {
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 } // EOF → claude sort
        process?.terminate()
        process = nil
        if case .failed = state {} else { state = .idle }
    }

    // MARK: - Application des événements (sur le main actor, dans l'ordre)

    private func handle(_ event: StreamEvent) {
        switch event {
        case .initialized(let sessionID, _):
            if !sessionID.isEmpty { claudeSessionID = sessionID }
        case .textDelta(let text):
            appendToCurrentAssistant(text)
        case .thinkingDelta:
            break
        case .assistantText(let full):
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
        if state == .responding { state = .ready }
    }

    /// EOF stdout : le processus a fini d'écrire → clôturer proprement.
    private func readerFinished() {
        if let index = currentAssistantIndex {
            turns[index].streaming = false
            if turns[index].text.isEmpty { turns[index].text = "· (session terminée)" }
        }
        process = nil
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
        if case .failed = state {} else { state = .idle }
    }

    private func trimTurns() {
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }
}
