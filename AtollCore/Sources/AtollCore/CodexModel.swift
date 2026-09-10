import Foundation

public struct CodexModel: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let model: String
    public let displayName: String
    public let isDefault: Bool
    public let hidden: Bool

    public struct Page: Decodable, Sendable {
        public let data: [CodexModel]
        public let nextCursor: String?
    }
}
