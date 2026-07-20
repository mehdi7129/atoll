import Foundation
import SQLite3

/// Destructeur `SQLITE_TRANSIENT` : demande à SQLite de copier immédiatement le
/// buffer lié — indispensable pour des `String` Swift dont la représentation C
/// ne survit pas à l'appel de bind.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Index plein-texte des transcripts Claude Code (SQLite + FTS5) — la mémoire
/// long-terme d'Atoll (Phase 7a).
///
/// Invariants structurants :
/// - **Donnée dérivée** : tout le contenu se reconstruit depuis les JSONL de
///   `~/.claude/projects/`. Une version de schéma inconnue (`PRAGMA user_version`
///   ≠ `schemaVersion`) ne se migre donc JAMAIS : la base (db + `-wal` + `-shm`)
///   est supprimée et recréée de zéro.
/// - **Append-only** : un message inséré n'est jamais modifié — il n'existe pas
///   de trigger UPDATE sur le FTS, seulement INSERT (`messages_ai`) et DELETE
///   (`messages_ad`, purge par fichier après rotation/troncature). C'est ce qui
///   rend l'index externe `content='messages'` sûr.
/// - **Idempotence crash-safe** : `ingest` écrit fragments + offset de lecture
///   dans UNE transaction ; la contrainte `(file_id, uuid, block_idx)` rend le
///   rejeu d'un lot déjà ingéré sans effet (`INSERT OR IGNORE`, et le trigger
///   FTS ne se déclenche pas sur une ligne ignorée).
/// - **Non-Sendable, confinement par l'appelant** : un handle SQLite ne se
///   partage pas entre threads. L'app confine son instance dans un actor, le
///   bridge dans son unique thread. WAL + `busy_timeout=2000` permettent la
///   coexistence app (readWrite) / bridge (readOnly) sur le même fichier.
public final class MemoryIndex {

    /// Mode d'ouverture. `readOnly` n'écrit JAMAIS rien : ni création de
    /// fichier, ni migration, ni pragma persistant — une URL inexistante est
    /// une erreur (`databaseNotFound`), pas une invitation à créer.
    public enum Mode: Equatable, Sendable {
        case readWrite
        case readOnly
    }

    /// Erreurs parlantes : code SQLite brut + message texte, pour que les logs
    /// de l'app comme du bridge racontent quelque chose d'actionnable.
    public enum MemoryIndexError: Error, Equatable {
        /// Ouverture `readOnly` d'une base absente — on refuse de la créer.
        case databaseNotFound(path: String)
        /// `sqlite3_open_v2` a échoué.
        case cannotOpen(code: Int32, message: String)
        /// Échec de prepare/bind/step/exec.
        case sqlite(code: Int32, message: String)
        /// Opération tentée après `close()`.
        case connectionClosed
    }

    /// Un résultat de recherche : la session d'où vient le message, et un
    /// extrait avec les termes trouvés entre « » (fragments joints par ' … ').
    public struct Hit: Equatable, Sendable {
        public let sessionID: String
        public let projectPath: String?
        public let projectDir: String
        public let title: String?
        public let role: String
        public let timestamp: Date?
        public let snippet: String
        /// Score bm25 brut : plus NÉGATIF = plus pertinent (c'est l'ordre de tri).
        public let rank: Double

        public init(sessionID: String, projectPath: String?, projectDir: String,
                    title: String?, role: String, timestamp: Date?,
                    snippet: String, rank: Double) {
            self.sessionID = sessionID
            self.projectPath = projectPath
            self.projectDir = projectDir
            self.title = title
            self.role = role
            self.timestamp = timestamp
            self.snippet = snippet
            self.rank = rank
        }
    }

    /// Photographie de l'index pour l'UI de diagnostic.
    public struct Stats: Equatable, Sendable {
        public let sessionCount: Int
        public let messageCount: Int
        /// Taille logique de la base : `page_count × page_size`.
        public let databaseBytes: Int64

        public init(sessionCount: Int, messageCount: Int, databaseBytes: Int64) {
            self.sessionCount = sessionCount
            self.messageCount = messageCount
            self.databaseBytes = databaseBytes
        }
    }

    /// État d'un fichier suivi : son id en base et l'offset (octets) déjà
    /// ingéré — l'appelant reprend la lecture du JSONL à cet offset.
    public struct FileState: Equatable, Sendable {
        public let fileID: Int64
        public let offset: Int64

        public init(fileID: Int64, offset: Int64) {
            self.fileID = fileID
            self.offset = offset
        }
    }

    /// Version du schéma, stockée dans `PRAGMA user_version`. Toute autre
    /// valeur non nulle rencontrée → suppression + recréation (pas de migration).
    public static let schemaVersion: Int32 = 1

    private let url: URL
    private let mode: Mode
    private var db: OpaquePointer?

    // MARK: - Cycle de vie

    /// Ouvre (readWrite : et crée/migre au besoin) la base à `url`.
    /// readWrite pose WAL + synchronous=NORMAL + busy_timeout=2000 ;
    /// readOnly pose seulement busy_timeout (les autres pragmas écriraient).
    public init(url: URL, mode: Mode) throws {
        self.url = url
        self.mode = mode
        switch mode {
        case .readOnly:
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MemoryIndexError.databaseNotFound(path: url.path)
            }
            db = try Self.openHandle(path: url.path, flags: SQLITE_OPEN_READONLY)
            try exec("PRAGMA busy_timeout=2000")
        case .readWrite:
            db = try Self.openHandle(path: url.path,
                                     flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            try configureForWriting()
            try migrateIfNeeded()
        }
    }

    deinit {
        close()
    }

    /// Ferme le handle. Toute opération ultérieure échoue en `connectionClosed`.
    /// Idempotent (un second close est un no-op).
    public func close() {
        sqlite3_close_v2(db)
        db = nil
    }

    // MARK: - Fichiers suivis

    /// Déclare un fichier JSONL avant ingestion et rend l'offset de reprise.
    ///
    /// Détection des réécritures — dans les deux cas les messages déjà indexés
    /// ne correspondent plus au contenu, donc purge (le trigger `messages_ad`
    /// désindexe) et relecture complète depuis 0 :
    /// - `inode` différent de celui stocké → rotation (nouveau fichier au même
    ///   chemin) ;
    /// - `size` plus petit que l'offset déjà lu → troncature.
    /// Sinon l'offset stocké est rendu tel quel. Remet toujours `missing` à 0.
    public func openFile(path: String, inode: UInt64, size: Int64) throws -> FileState {
        try withTransaction {
            if let existing = try selectFile(path: path) {
                if existing.inode != inode || size < existing.offset {
                    try run("DELETE FROM messages WHERE file_id = ?1",
                            binds: [.int(existing.id)])
                    try run("UPDATE files SET inode = ?1, offset = 0, missing = 0 WHERE id = ?2",
                            binds: [.int(Int64(bitPattern: inode)), .int(existing.id)])
                    return FileState(fileID: existing.id, offset: 0)
                }
                try run("UPDATE files SET missing = 0 WHERE id = ?1",
                        binds: [.int(existing.id)])
                return FileState(fileID: existing.id, offset: existing.offset)
            }
            try run("INSERT INTO files(path, inode) VALUES(?1, ?2)",
                    binds: [.text(path), .int(Int64(bitPattern: inode))])
            return FileState(fileID: sqlite3_last_insert_rowid(try handle()), offset: 0)
        }
    }

    /// Marque un fichier disparu du disque. Ses messages restent cherchables
    /// (la mémoire survit au ménage dans `~/.claude/projects/`) ; le flag sert
    /// au diagnostic et à un éventuel ménage explicite futur.
    public func markMissing(path: String) throws {
        try run("UPDATE files SET missing = 1 WHERE path = ?1", binds: [.text(path)])
    }

    // MARK: - Ingestion

    /// Ingère un lot de lignes lues entre `fileState.offset` et `newOffset`,
    /// en UNE transaction : upsert de la session, insertion de chaque fragment,
    /// puis avancée de l'offset. Un crash avant COMMIT ne laisse rien ; un
    /// rejeu du même lot est neutre (dédup `(file_id, uuid, block_idx)`).
    ///
    /// - `uuid` d'un message : `line.uuid` si le transcript en porte un, sinon
    ///   le `syntheticUUID` fourni par l'appelant (dérivé de l'offset — stable
    ///   d'un rejeu à l'autre, condition de l'idempotence).
    /// - Le titre de session vient des fragments `.title` (le dernier gagne) ;
    ///   `project_path`/`git_branch` : dernière valeur non vide du lot ;
    ///   `first_ts`/`last_ts` : bornes min/max, jamais rétrécies par l'upsert.
    public func ingest(lines: [(line: TranscriptLine, syntheticUUID: String)],
                       fileState: FileState,
                       sessionID: String,
                       projectDir: String,
                       newOffset: Int64) throws {
        try withTransaction {
            let digest = SessionDigest(lines: lines.map(\.line))
            try run(Self.sessionUpsertSQL, binds: [
                .text(sessionID),
                .text(projectDir),
                .optionalText(digest.projectPath),
                .optionalText(digest.title),
                .optionalText(digest.gitBranch),
                .optionalInt(digest.firstTS),
                .optionalInt(digest.lastTS),
            ])
            guard let sessionRowID = try scalarRow(
                "SELECT id FROM sessions WHERE session_id = ?1",
                binds: [.text(sessionID)]
            ) else {
                throw MemoryIndexError.sqlite(code: SQLITE_INTERNAL,
                                              message: "session absente après upsert")
            }

            let insert = try prepare(
                """
                INSERT OR IGNORE INTO messages(session_id, file_id, uuid, block_idx, role, ts, text)
                VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
                """
            )
            defer { sqlite3_finalize(insert) }
            for entry in lines {
                let uuid = entry.line.uuid ?? entry.syntheticUUID
                let ts = entry.line.timestamp.map { Int64($0.timeIntervalSince1970) }
                for (blockIdx, fragment) in entry.line.fragments.enumerated() {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    try apply([
                        .int(sessionRowID),
                        .int(fileState.fileID),
                        .text(uuid),
                        .int(Int64(blockIdx)),
                        .text(fragment.role.rawValue),
                        .optionalInt(ts),
                        .text(fragment.text),
                    ], to: insert)
                    _ = try step(insert)
                }
            }

            try run("UPDATE files SET offset = ?1, mtime = ?2 WHERE id = ?3", binds: [
                .int(newOffset),
                .real(Date().timeIntervalSince1970),
                .int(fileState.fileID),
            ])
        }
    }

    // MARK: - Recherche

    /// Recherche plein-texte. `rawQuery` est TOUJOURS passée par
    /// `sanitizedMatchQuery` — l'utilisateur ne parle jamais directement à
    /// FTS5 ; une requête vide après sanitisation rend `[]` sans exécuter de
    /// MATCH. `projectPrefix` restreint aux sessions dont `project_path`
    /// commence par ce préfixe. Tri par pertinence bm25 (négatif croissant).
    public func search(rawQuery: String, limit: Int, projectPrefix: String?) throws -> [Hit] {
        let match = Self.sanitizedMatchQuery(rawQuery)
        guard !match.isEmpty, limit > 0 else { return [] }

        // Le préfixe devient un motif LIKE : ses jokers (% _) et l'échappement
        // eux-mêmes sont neutralisés, sinon un chemin comme Dynamic_Island
        // matcherait aussi DynamicXIsland (vécu en revue).
        let prefixPattern = projectPrefix.map { Self.escapedLikePrefix($0) + "%" }

        let stmt = try prepare(Self.searchSQL)
        defer { sqlite3_finalize(stmt) }
        try apply([.text(match), .optionalText(prefixPattern), .int(Int64(limit))], to: stmt)

        var hits: [Hit] = []
        while try step(stmt) {
            hits.append(Hit(
                sessionID: columnText(stmt, 0) ?? "",
                projectPath: columnText(stmt, 1),
                projectDir: columnText(stmt, 2) ?? "",
                title: columnText(stmt, 3),
                role: columnText(stmt, 4) ?? "",
                timestamp: columnEpoch(stmt, 5),
                snippet: columnText(stmt, 6) ?? "",
                rank: sqlite3_column_double(stmt, 7)
            ))
        }
        return hits
    }

    /// Statistiques globales : nombre de sessions, de messages, et taille
    /// logique de la base (`page_count × page_size` — ignore le `-wal`).
    public func stats() throws -> Stats {
        let sessions = try scalar("SELECT COUNT(*) FROM sessions")
        let messages = try scalar("SELECT COUNT(*) FROM messages")
        let bytes = try scalar("PRAGMA page_count") * (try scalar("PRAGMA page_size"))
        return Stats(sessionCount: Int(sessions),
                     messageCount: Int(messages),
                     databaseBytes: bytes)
    }

    /// Neutralise une requête utilisateur pour FTS5 : chaque token (découpe sur
    /// l'espace) devient une chaîne entre guillemets — les opérateurs FTS5
    /// (`AND OR NOT NEAR ( ) - ^ :`) deviennent des littéraux inertes, et une
    /// syntaxe invalide ne peut plus faire échouer le MATCH.
    ///
    /// SEULE syntaxe préservée : l'étoile finale (`géom*` → `"géom"*`, requête
    /// par préfixe). Les guillemets internes sont doublés (échappement FTS5),
    /// les tokens vides (ou réduits à des étoiles) sont ignorés ; les tokens
    /// sont joints par espace, le AND implicite de FTS5.
    public static func sanitizedMatchQuery(_ raw: String) -> String {
        var pieces: [String] = []
        for token in raw.split(whereSeparator: { $0.isWhitespace }) {
            var body = token[...]
            var isPrefix = false
            while body.hasSuffix("*") {
                isPrefix = true
                body = body.dropLast()
            }
            guard !body.isEmpty else { continue }
            let escaped = body.replacingOccurrences(of: "\"", with: "\"\"")
            pieces.append(isPrefix ? "\"\(escaped)\"*" : "\"\(escaped)\"")
        }
        return pieces.joined(separator: " ")
    }

    // MARK: - Accès internes (tests)

    /// `PRAGMA user_version` — exposé en interne pour vérifier la migration.
    func storedSchemaVersion() throws -> Int32 {
        Int32(try scalar("PRAGMA user_version"))
    }

    /// Bornes temporelles stockées d'une session (nil = session inconnue) —
    /// exposé en interne pour tester l'upsert min/max.
    func sessionTimeBounds(sessionID: String) throws -> (first: Int64?, last: Int64?)? {
        let stmt = try prepare("SELECT first_ts, last_ts FROM sessions WHERE session_id = ?1")
        defer { sqlite3_finalize(stmt) }
        try apply([.text(sessionID)], to: stmt)
        guard try step(stmt) else { return nil }
        return (first: columnInt64(stmt, 0), last: columnInt64(stmt, 1))
    }

    // MARK: - Ouverture / migration

    private static func openHandle(path: String, flags: Int32) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close_v2(handle)
            throw MemoryIndexError.cannotOpen(code: rc, message: message)
        }
        return handle
    }

    private func configureForWriting() throws {
        // WAL : les lecteurs (bridge) ne sont jamais bloqués par l'écrivain.
        // NORMAL suffit : une transaction perdue sur coupure de courant sera
        // ré-ingérée au prochain passage — l'offset n'avance qu'avec ses
        // messages. busy_timeout court : personne ne doit attendre l'index.
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA busy_timeout=2000")
    }

    private func migrateIfNeeded() throws {
        let version = try storedSchemaVersion()
        guard version != Self.schemaVersion else { return }
        if version == 0 {
            // Base neuve. Schéma + user_version posés dans UNE transaction :
            // une création interrompue laisse une base revenue à zéro, jamais
            // un schéma partiel avec version posée.
            do {
                try createSchema()
                return
            } catch {
                // version 0 mais contenu incompatible (fichier étranger, débris)
                // → même traitement qu'une version inconnue.
            }
        }
        try recreateFromScratch()
    }

    private func createSchema() throws {
        try withTransaction {
            try exec(Self.schemaSQL)
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    /// Version de schéma inconnue : pas de migration incrémentale — l'index est
    /// une donnée dérivée reconstructible, on jette tout (db, -wal, -shm) et on
    /// repart d'une base vierge.
    private func recreateFromScratch() throws {
        close()
        try Self.removeDatabaseFiles(at: url)
        db = try Self.openHandle(path: url.path,
                                 flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try configureForWriting()
        try createSchema()
    }

    private static func removeDatabaseFiles(at url: URL) throws {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if manager.fileExists(atPath: path) {
                try manager.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Aides SQLite

    /// Valeur à lier à un placeholder — le petit sous-ensemble utile à l'index.
    private enum BindValue {
        case text(String)
        case optionalText(String?)
        case int(Int64)
        case optionalInt(Int64?)
        case real(Double)
    }

    private func handle() throws -> OpaquePointer {
        guard let db else { throw MemoryIndexError.connectionClosed }
        return db
    }

    private func lastMessage() -> String {
        guard let db else { return "connexion fermée" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(try handle(), sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "code \(rc)"
            sqlite3_free(errorMessage)
            throw MemoryIndexError.sqlite(code: rc, message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(try handle(), sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw MemoryIndexError.sqlite(code: rc, message: lastMessage())
        }
        return stmt
    }

    private func apply(_ binds: [BindValue], to stmt: OpaquePointer) throws {
        for (offset, value) in binds.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .text(let string), .optionalText(.some(let string)):
                rc = sqlite3_bind_text(stmt, index, string, -1, sqliteTransient)
            case .int(let number), .optionalInt(.some(let number)):
                rc = sqlite3_bind_int64(stmt, index, number)
            case .real(let number):
                rc = sqlite3_bind_double(stmt, index, number)
            case .optionalText(nil), .optionalInt(nil):
                rc = sqlite3_bind_null(stmt, index)
            }
            guard rc == SQLITE_OK else {
                throw MemoryIndexError.sqlite(code: rc, message: lastMessage())
            }
        }
    }

    /// Avance d'un pas. true = une ligne est disponible, false = terminé.
    private func step(_ stmt: OpaquePointer) throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let rc: throw MemoryIndexError.sqlite(code: rc, message: lastMessage())
        }
    }

    /// Exécute une requête sans résultat attendu (INSERT/UPDATE/DELETE lié).
    private func run(_ sql: String, binds: [BindValue] = []) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try apply(binds, to: stmt)
        _ = try step(stmt)
    }

    /// Premier entier de la première ligne ; 0 si aucune ligne.
    private func scalar(_ sql: String) throws -> Int64 {
        try scalarRow(sql, binds: []) ?? 0
    }

    /// Premier entier de la première ligne ; nil si aucune ligne.
    private func scalarRow(_ sql: String, binds: [BindValue]) throws -> Int64? {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try apply(binds, to: stmt)
        guard try step(stmt) else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func selectFile(path: String) throws -> (id: Int64, inode: UInt64, offset: Int64)? {
        let stmt = try prepare("SELECT id, inode, offset FROM files WHERE path = ?1")
        defer { sqlite3_finalize(stmt) }
        try apply([.text(path)], to: stmt)
        guard try step(stmt) else { return nil }
        return (id: sqlite3_column_int64(stmt, 0),
                inode: UInt64(bitPattern: sqlite3_column_int64(stmt, 1)),
                offset: sqlite3_column_int64(stmt, 2))
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }

    private func columnInt64(_ stmt: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, index)
    }

    private func columnEpoch(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
        columnInt64(stmt, index).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// BEGIN IMMEDIATE (le verrou d'écriture est pris tout de suite : un échec
    /// pour cause de base occupée arrive AVANT d'avoir travaillé) ; ROLLBACK
    /// best-effort sur toute erreur.
    private func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Condensé de session

    /// Condensé d'un lot de lignes pour l'upsert session : la dernière valeur
    /// non vide gagne (cwd → project_path, branche, titre `.title`), bornes
    /// min/max en secondes epoch pour first_ts/last_ts.
    private struct SessionDigest {
        var projectPath: String?
        var gitBranch: String?
        var title: String?
        var firstTS: Int64?
        var lastTS: Int64?

        init(lines: [TranscriptLine]) {
            for line in lines {
                if let cwd = line.cwd, !cwd.isEmpty { projectPath = cwd }
                if let branch = line.gitBranch, !branch.isEmpty { gitBranch = branch }
                if let date = line.timestamp {
                    let ts = Int64(date.timeIntervalSince1970)
                    firstTS = min(firstTS ?? ts, ts)
                    lastTS = max(lastTS ?? ts, ts)
                }
                for fragment in line.fragments
                where fragment.role == .title && !fragment.text.isEmpty {
                    title = fragment.text
                }
            }
        }
    }

    // MARK: - SQL

    /// Upsert d'une session : les COALESCE garantissent qu'un lot pauvre
    /// (sans titre, sans cwd…) n'efface jamais une valeur déjà connue, et que
    /// first_ts/last_ts ne font que s'élargir.
    private static let sessionUpsertSQL = """
        INSERT INTO sessions(session_id, project_dir, project_path, title, git_branch, first_ts, last_ts)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(session_id) DO UPDATE SET
            title = COALESCE(excluded.title, title),
            project_path = COALESCE(excluded.project_path, project_path),
            git_branch = COALESCE(excluded.git_branch, git_branch),
            last_ts = MAX(COALESCE(last_ts, 0), COALESCE(excluded.last_ts, 0)),
            first_ts = MIN(COALESCE(first_ts, excluded.first_ts), COALESCE(excluded.first_ts, first_ts))
        """

    /// La recherche : FTS5 → messages → sessions, filtre optionnel par préfixe
    /// de project_path, tri bm25 (négatif croissant = pertinence décroissante).
    private static let searchSQL = """
        SELECT s.session_id, s.project_path, s.project_dir, s.title,
               m.role, m.ts,
               snippet(messages_fts, 0, '«', '»', ' … ', 14),
               bm25(messages_fts)
        FROM messages_fts
        JOIN messages m ON m.id = messages_fts.rowid
        JOIN sessions s ON s.id = m.session_id
        WHERE messages_fts MATCH ?1
          AND (?2 IS NULL OR s.project_path LIKE ?2 ESCAPE '\\')
        ORDER BY bm25(messages_fts)
        LIMIT ?3
        """

    /// Échappe un préfixe pour LIKE : `\` `%` `_` deviennent littéraux
    /// (l'appelant ajoute le `%` final, non échappé, lui).
    static func escapedLikePrefix(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Schéma v1. Le FTS est en contenu externe (`content='messages'`) :
    /// il n'est cohérent QUE parce que messages est append-only — d'où
    /// l'absence délibérée de trigger UPDATE (seuls INSERT et DELETE existent).
    private static let schemaSQL = """
        CREATE TABLE files(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            inode INTEGER NOT NULL DEFAULT 0,
            offset INTEGER NOT NULL DEFAULT 0,
            mtime REAL NOT NULL DEFAULT 0,
            missing INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE sessions(
            id INTEGER PRIMARY KEY,
            session_id TEXT NOT NULL UNIQUE,
            project_dir TEXT NOT NULL,
            project_path TEXT,
            title TEXT,
            git_branch TEXT,
            first_ts INTEGER,
            last_ts INTEGER
        );
        CREATE TABLE messages(
            id INTEGER PRIMARY KEY,
            session_id INTEGER NOT NULL REFERENCES sessions(id),
            file_id INTEGER NOT NULL REFERENCES files(id),
            uuid TEXT NOT NULL,
            block_idx INTEGER NOT NULL DEFAULT 0,
            role TEXT NOT NULL,
            ts INTEGER,
            text TEXT NOT NULL
        );
        CREATE UNIQUE INDEX idx_messages_dedup ON messages(file_id, uuid, block_idx);
        CREATE INDEX idx_messages_session ON messages(session_id);
        CREATE VIRTUAL TABLE messages_fts USING fts5(
            text,
            content='messages',
            content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
            INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
            INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;
        """
}
