import Foundation

public enum BoundedProcessOutput {
    /// Toujours vider le pipe, mais ne jamais conserver plus que cap + 1 octets.
    /// L'octet supplémentaire permet au parseur de distinguer une sortie tronquée.
    public static func drain(_ handle: FileHandle, cap: Int, tail: Bool = false) -> Data {
        var data = Data()
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            if tail {
                data.append(chunk)
                if data.count > cap { data = Data(data.suffix(cap)) }
            } else if data.count <= cap {
                data.append(chunk.prefix(cap + 1 - data.count))
            }
        }
        return data
    }

    public static func file(at url: URL, cap: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: cap + 1), data.count <= cap else { return nil }
        return data
    }
}
