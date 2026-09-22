import Foundation
import CryptoKit

/// Empreinte exacte du corpus conservé après un rangement réussi. Les noms et
/// contenus sont encodés séparément : ni l'ordre du listing, ni une frontière
/// ambiguë entre deux notes ne peuvent fabriquer une égalité.
public struct CurationCorpusFingerprint: Codable, Equatable, Sendable {
    public let version: Int
    public let sha256: String

    public init(notes: [(name: String, content: String)]) {
        version = 1
        let ordered = notes.sorted {
            $0.name == $1.name ? $0.content < $1.content : $0.name < $1.name
        }
        var hash = SHA256()
        for note in ordered {
            for field in [note.name, note.content] {
                let bytes = Data(field.utf8)
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
                hash.update(data: bytes)
            }
        }
        sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
