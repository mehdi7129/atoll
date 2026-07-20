import Foundation

/// Découpe un flux d'octets en lignes complètes avec offsets absolus.
///
/// C'est le cœur crash-safe de l'indexation incrémentale : une ligne n'est
/// émise QUE terminée par `\n`, et `consumedOffset` ne dépasse jamais la fin
/// de la dernière ligne complète — une queue partielle (ligne en cours
/// d'écriture par Claude Code) sera relue entière au passage suivant, jamais
/// perdue ni tronquée. Extrait en logique pure pour être testé aux frontières
/// (ligne à cheval sur deux tranches, fichier sans `\n` final, ligne géante).
public struct TranscriptLineSplitter {
    /// Une ligne complète : ses octets (sans le `\n`) et l'offset absolu de
    /// son premier octet dans le fichier.
    public struct Line: Equatable, Sendable {
        public let data: Data
        public let startOffset: Int64
    }

    /// Au-delà de cette taille sans `\n`, la « ligne » est abandonnée et
    /// l'offset avance quand même : un fichier pathologique ne doit pas
    /// bloquer l'indexation ni gonfler la mémoire indéfiniment.
    public static let maxCarryBytes = 16 * 1024 * 1024

    private var carry = Data()
    /// Offset absolu du premier octet de `carry`.
    private var carryStart: Int64
    /// Fin (exclusive) de la dernière ligne complète consommée.
    public private(set) var consumedOffset: Int64

    public init(startOffset: Int64) {
        carryStart = startOffset
        consumedOffset = startOffset
    }

    /// Absorbe une tranche et rend les lignes complètes qu'elle libère.
    public mutating func consume(_ chunk: Data) -> [Line] {
        carry.append(chunk)
        var lines: [Line] = []
        var searchStart = carry.startIndex
        while let newline = carry[searchStart...].firstIndex(of: 0x0A) {
            let lineStart = carryStart + Int64(carry.distance(from: carry.startIndex, to: searchStart))
            if newline > searchStart {
                lines.append(Line(data: Data(carry[searchStart..<newline]), startOffset: lineStart))
            }
            consumedOffset = carryStart
                + Int64(carry.distance(from: carry.startIndex, to: newline)) + 1
            searchStart = carry.index(after: newline)
        }
        if searchStart > carry.startIndex {
            carryStart += Int64(carry.distance(from: carry.startIndex, to: searchStart))
            carry.removeSubrange(carry.startIndex..<searchStart)
        }
        if carry.count > Self.maxCarryBytes {
            carryStart += Int64(carry.count)
            consumedOffset = carryStart
            carry.removeAll(keepingCapacity: false)
        }
        return lines
    }
}
