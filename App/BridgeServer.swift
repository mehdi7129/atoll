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
    private let socketPath: String
    private var listenFD: Int32 = -1
    /// (device, inode) du socket créé par CETTE instance — voir `stop()`.
    private var boundNode: (dev_t, ino_t)?
    private var acceptSource: DispatchSourceRead?
    private var readers: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]
    /// Connexions PermissionRequest gardées ouvertes en attendant la décision
    /// de l'îlot (requestID → fd du helper bloqué).
    private var pendingReplies: [String: Int32] = [:]

    /// Appelés sur la main queue. requestID non-nil = PermissionRequest en
    /// attente de décision via reply()/cancelPending().
    private let onEvent: (ParsedHookEvent, _ requestID: String?) -> Void
    private let onStatusline: (Data) -> Void
    /// `requestID` non-nil = le helper Codex ATTEND une décision sur ce fd.
    private let onCodexEvent: (CodexHookEvent, _ requestID: String?, _ helperPid: pid_t) -> Void
    private let onStateChange: (Bool) -> Void
    /// Prévenu sur la main queue quand une attente expire — voir
    /// `pendingRepliesTimeout`.
    private let onPendingExpired: (_ requestID: String) -> Void

    init(
        onEvent: @escaping (ParsedHookEvent, String?) -> Void,
        onStatusline: @escaping (Data) -> Void,
        onStateChange: @escaping (Bool) -> Void,
        onCodexEvent: @escaping (CodexHookEvent, String?, pid_t) -> Void = { _, _, _ in },
        onPendingExpired: @escaping (String) -> Void = { _ in },
        socketPath: String = BridgePaths.socketPath
    ) {
        self.onEvent = onEvent
        self.onStatusline = onStatusline
        self.onStateChange = onStateChange
        self.onCodexEvent = onCodexEvent
        self.onPendingExpired = onPendingExpired
        self.socketPath = socketPath
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
        let path = socketPath
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
        // Identité du nœud qu'on VIENT de créer. `stop()` ne supprimera le
        // chemin que s'il désigne toujours CE nœud : deux instances d'Atoll
        // (le produit de build et la copie ~/Applications — la boucle de dev
        // documentée) se volaient le socket, puis la première à quitter
        // supprimait celui de la seconde, qui n'en savait rien et n'a plus
        // jamais reçu un hook (audit du 2026-07-27).
        var info = stat()
        if stat(path, &info) == 0 { boundNode = (info.st_dev, info.st_ino) }
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
        // Ne retirer le chemin QUE s'il désigne encore notre propre nœud : une
        // autre instance a pu le remplacer entre-temps, et le lui supprimer la
        // rendrait sourde définitivement, sans qu'elle puisse le détecter.
        var info = stat()
        if let boundNode, stat(socketPath, &info) == 0,
           info.st_dev == boundNode.0, info.st_ino == boundNode.1 {
            unlink(socketPath)
        }
        boundNode = nil
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

        // JSON parsé UNE seule fois : enveloppe statusline vs événement de hook.
        let envelope = (parse && !entry.buffer.isEmpty)
            ? (try? JSONSerialization.jsonObject(with: entry.buffer)) as? [String: Any]
            : nil

        if socketPath == CodexPaths.socketPath, envelope?["provider"] as? String != "codex" {
            entry.source.cancel()
            close(fd)
            return
        }

        // Les fournisseurs étrangers sont dispatchés AVANT tout chemin Claude :
        // une permission Codex n'entre JAMAIS dans `InteractionCenter`, donc
        // jamais dans Rockstar.
        if let envelope, let provider = envelope["provider"], provider as? String != "claude" {
            entry.source.cancel()
            guard let event = CodexHookEvent(envelope: envelope) else { close(fd); return }

            // Une demande d'autorisation Codex laisse le fd OUVERT : le helper
            // attend notre décision. La corrélation se fait par cet UUID lié au
            // descripteur — jamais par le nom d'outil, qui ne distingue pas deux
            // demandes simultanées identiques (spécifié par Codex).
            if event.kind == .permissionRequest {
                let requestID = UUID().uuidString
                pendingReplies[requestID] = fd

                // ⚠️ ON NE PEUT PAS DÉTECTER LA MORT DU HELPER PAR EOF.
                // Il fait `shutdown(SHUT_WR)` juste après avoir envoyé son
                // payload — un half-close NORMAL et systématique. Un détecteur
                // d'EOF confond donc « a fini d'écrire » et « est mort », et
                // referme la carte AUSSITÔT : mesuré le 2026-09-09, le chemin
                // nominal rendait la main en 0 s avec une réponse vide.
                //
                // La seule preuve fiable est le PROCESSUS. `LOCAL_PEERPID` le
                // donne à la connexion ; `CodexInteractionCenter` le vérifie
                // ensuite périodiquement.
                var peer: pid_t = 0
                var size = socklen_t(MemoryLayout<pid_t>.size)
                let helperPid = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0
                    ? peer : 0
                // Filet : jamais de fd orphelin. Posé APRÈS la deadline du
                // helper — c'est lui qui doit rendre la main le premier.
                queue.asyncAfter(deadline: .now() + CodexPermissionTiming.codexTimeoutSeconds) {
                    [weak self] in self?.pendingRepliesTimeout(requestID)
                }
                log.info("permission Codex en attente \(requestID, privacy: .public)")
                DispatchQueue.main.async { self.onCodexEvent(event, requestID, helperPid) }
                return
            }
            close(fd)
            DispatchQueue.main.async { self.onCodexEvent(event, nil, 0) }
            return
        }

        if let envelope, envelope["statusline"] != nil {
            entry.source.cancel()
            close(fd)
            let buffer = entry.buffer
            DispatchQueue.main.async { self.onStatusline(buffer) }
            return
        }

        entry.source.cancel()

        let event = envelope.flatMap { ParsedHookEvent(envelope: $0) }

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

    /// Le filet de temps s'est déclenché : plus PERSONNE n'attend derrière ce
    /// descripteur.
    ///
    /// ⚠️ FERMER LE FD NE SUFFIT PAS, et c'est le trou que Codex a relevé en
    /// revue : la carte restait affichée dans l'îlot après l'expiration, et
    /// un clic envoyait alors une décision dans le vide. Le serveur PRÉVIENT
    /// donc le centre d'interaction, qui la retire.
    private func pendingRepliesTimeout(_ requestID: String) {
        guard let fd = pendingReplies.removeValue(forKey: requestID) else { return }
        close(fd)
        log.info("attente \(requestID, privacy: .public) expirée — descripteur fermé")
        let notify = onPendingExpired
        DispatchQueue.main.async { notify(requestID) }
    }

}
