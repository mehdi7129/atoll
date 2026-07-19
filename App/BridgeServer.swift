import Foundation
import Darwin
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "bridge-server")

/// Serveur du socket Unix `/tmp/atoll-<uid>.sock` : reçoit les enveloppes JSON
/// envoyées par `atoll-bridge` (une connexion = un événement, close = fin).
///
/// BSD sockets + DispatchSource — NWListener a des comportements erratiques avec
/// les sockets Unix (connexions acceptées au niveau noyau mais jamais livrées au
/// newConnectionHandler, constaté sur macOS 26).
final class BridgeServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.mehdiguiard.atoll.bridge-server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var readers: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]
    /// Connexions PermissionRequest gardées ouvertes en attendant la décision
    /// de l'îlot (requestID → fd du helper bloqué).
    private var pendingReplies: [String: Int32] = [:]

    /// Appelés sur la main queue. requestID non-nil = PermissionRequest en
    /// attente de décision via reply()/cancelPending().
    private let onEvent: (ParsedHookEvent, _ requestID: String?) -> Void
    private let onStatusline: (Data) -> Void
    private let onStateChange: (Bool) -> Void

    init(
        onEvent: @escaping (ParsedHookEvent, String?) -> Void,
        onStatusline: @escaping (Data) -> Void,
        onStateChange: @escaping (Bool) -> Void
    ) {
        self.onEvent = onEvent
        self.onStatusline = onStatusline
        self.onStateChange = onStateChange
    }

    // MARK: - Réponses aux PermissionRequest

    /// Envoie la décision au helper bloqué puis ferme la connexion.
    func reply(_ requestID: String, decision: Data) {
        queue.async { [weak self] in
            guard let self, let fd = self.pendingReplies.removeValue(forKey: requestID) else { return }
            // Le helper est garanti bloqué en lecture : on repasse le fd en
            // bloquant pour ne jamais tronquer la décision sur EAGAIN.
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
            decision.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        break // EPIPE (helper mort) etc. — SO_NOSIGPIPE évite le crash.
                    }
                    if written == 0 { break }
                    offset += written
                }
            }
            close(fd)
            log.info("décision envoyée pour \(requestID, privacy: .public)")
        }
    }

    /// Ferme la connexion SANS décision : le helper sort en silence et le
    /// prompt du terminal garde la main (course perdue, îlot fermé, etc.).
    func cancelPending(_ requestID: String) {
        queue.async { [weak self] in
            guard let self, let fd = self.pendingReplies.removeValue(forKey: requestID) else { return }
            close(fd)
            log.info("requête \(requestID, privacy: .public) rendue au terminal")
        }
    }

    enum ServerError: Error {
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
    }

    func start() throws {
        let path = BridgePaths.socketPath
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed(errno) }
        // Non-bloquant : la boucle d'accept tourne sur une queue série — un
        // accept() bloquant la gèlerait après la première connexion.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(
                    from: UnsafeRawBufferPointer(rebasing: source.prefix(destination.count))
                )
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length)
            }
        }
        guard bound == 0 else {
            close(fd)
            throw ServerError.bindFailed(errno)
        }
        // Le socket ne doit être accessible qu'à l'utilisateur courant.
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw ServerError.listenFailed(errno)
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        acceptSource = source

        log.info("serveur à l'écoute sur \(path, privacy: .public)")
        DispatchQueue.main.async { self.onStateChange(true) }
    }

    func stop() {
        queue.sync {
            for (fd, entry) in readers {
                entry.source.cancel()
                close(fd)
            }
            readers.removeAll()
            // Les helpers bloqués repartent en silence → prompts terminal intacts.
            for (_, fd) in pendingReplies {
                close(fd)
            }
            pendingReplies.removeAll()
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
        }
        unlink(BridgePaths.socketPath)
        DispatchQueue.main.async { self.onStateChange(false) }
    }

    // MARK: - Connexions (tout sur `queue`)

    private func acceptConnection() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                // fd épuisés : la connexion reste dans le backlog et la source
                // se redéclencherait en boucle CPU — pause d'une seconde.
                if errno == EMFILE || errno == ENFILE, let source = acceptSource {
                    log.warning("descripteurs épuisés — accept en pause 1 s")
                    source.suspend()
                    queue.asyncAfter(deadline: .now() + 1) {
                        source.resume()
                    }
                }
                return
            }

            let flags = fcntl(clientFD, F_GETFL)
            _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)
            // Écrire dans un fd dont le pair (helper) est mort ne doit JAMAIS
            // tuer l'app par SIGPIPE — write échoue alors avec EPIPE.
            var noSigpipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

            log.debug("connexion entrante (fd \(clientFD))")
            let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
            source.setEventHandler { [weak self] in
                self?.readAvailable(clientFD)
            }
            // Pas de fermeture dans le cancel handler : le fd d'une PermissionRequest
            // survit à l'annulation de sa source (on lui répondra plus tard).
            // La fermeture est toujours explicite (finish / reply / stop).
            readers[clientFD] = (source, Data())
            source.resume()
        }
    }

    private func readAvailable(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let byteCount = read(fd, &chunk, chunk.count)
            if byteCount > 0 {
                readers[fd]?.buffer.append(contentsOf: chunk[0..<byteCount])
                // Garde-fou : un client fou ne doit pas remplir la mémoire.
                if let size = readers[fd]?.buffer.count, size > 10_485_760 {
                    log.warning("enveloppe > 10 Mo, abandonnée")
                    finish(fd, parse: false)
                    return
                }
            } else if byteCount == 0 {
                // EOF propre : le client a tout envoyé.
                finish(fd, parse: true)
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                // Erreur : on tente quand même de parser ce qui a été reçu.
                finish(fd, parse: true)
                return
            }
        }
    }

    private func finish(_ fd: Int32, parse: Bool) {
        guard let entry = readers.removeValue(forKey: fd) else { return }

        // Enveloppe statusline : {"v":1,"statusline": <payload>} — pas un hook.
        if parse, !entry.buffer.isEmpty, isStatuslineEnvelope(entry.buffer) {
            entry.source.cancel()
            close(fd)
            let buffer = entry.buffer
            DispatchQueue.main.async { self.onStatusline(buffer) }
            return
        }

        entry.source.cancel()

        let event = parse && !entry.buffer.isEmpty
            ? ParsedHookEvent(envelopeData: entry.buffer)
            : nil

        if let event, event.kind == .permissionRequest {
            // Le helper attend la décision : le fd reste OUVERT (non fermé ici).
            let requestID = UUID().uuidString
            pendingReplies[requestID] = fd
            // Filet de sécurité : jamais de fd orphelin au-delà du timeout du hook.
            queue.asyncAfter(deadline: .now() + 86_400) { [weak self] in
                self?.pendingRepliesTimeout(requestID)
            }
            log.info("permission en attente \(requestID, privacy: .public) — \(event.toolSummary ?? event.toolName ?? "?", privacy: .public)")
            DispatchQueue.main.async { self.onEvent(event, requestID) }
            return
        }

        // Tous les autres cas : fermeture explicite du fd.
        close(fd)
        guard parse, !entry.buffer.isEmpty else { return }
        if let event {
            log.info("événement reçu: \(event.kind.rawValue, privacy: .public) session \(event.sessionID, privacy: .public)")
            DispatchQueue.main.async { self.onEvent(event, nil) }
        } else {
            log.warning("enveloppe illisible (\(entry.buffer.count) octets)")
        }
    }

    private func pendingRepliesTimeout(_ requestID: String) {
        if let fd = pendingReplies.removeValue(forKey: requestID) {
            close(fd)
        }
    }

    private func isStatuslineEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return false }
        return dict["statusline"] != nil
    }
}
