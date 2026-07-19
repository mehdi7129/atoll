import Foundation

/// Une session d'agent (Claude Code) telle qu'affichée par l'îlot.
/// En Phase 1 les données sont factices ; la Phase 2 branchera les hooks.
public struct AgentSession: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case working(tool: String?)
        case awaitingPermission(tool: String)
        case awaitingInput
        case done
    }

    /// Identifiant stable : le session_id Claude Code (ou un id synthétique).
    public let id: String
    public var projectName: String
    public var gitBranch: String?
    public var status: Status
    /// Contexte court affiché sous le nom (premier prompt, titre de session…).
    public var subtitle: String?
    public var startedAt: Date

    // Infos enrichies (transcript + statusline), toutes optionnelles.
    public var model: String?
    public var subagentCount: Int
    public var mcpServers: [String]
    public var contextUsedFraction: Double?
    public var costUSD: Double?
    public var cwd: String?

    public init(id: String = UUID().uuidString, projectName: String, gitBranch: String? = nil,
                status: Status, subtitle: String? = nil, startedAt: Date = Date(),
                model: String? = nil, subagentCount: Int = 0, mcpServers: [String] = [],
                contextUsedFraction: Double? = nil, costUSD: Double? = nil, cwd: String? = nil) {
        self.id = id
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.status = status
        self.subtitle = subtitle
        self.startedAt = startedAt
        self.model = model
        self.subagentCount = subagentCount
        self.mcpServers = mcpServers
        self.contextUsedFraction = contextUsedFraction
        self.costUSD = costUSD
        self.cwd = cwd
    }

    /// La session réclame une DÉCISION de l'utilisateur MAINTENANT (permission
    /// bloquante). Une session simplement inactive (`awaitingInput`, au repos
    /// entre deux messages) ne « réclame » rien — sinon chaque session dormante
    /// s'afficherait en alerte sur le notch.
    public var needsAttention: Bool {
        switch status {
        case .awaitingPermission: return true
        case .awaitingInput, .working, .done: return false
        }
    }

    /// La session est en train de travailler.
    public var isActive: Bool {
        if case .working = status { return true }
        return false
    }
}

/// Quota d'usage (5 h / 7 j) — factice en Phase 1, statusline en Phase 5.
public struct UsageSnapshot: Equatable, Sendable {
    public var fiveHourFraction: Double
    public var sevenDayFraction: Double

    public init(fiveHourFraction: Double, sevenDayFraction: Double) {
        self.fiveHourFraction = fiveHourFraction
        self.sevenDayFraction = sevenDayFraction
    }
}

/// Données de démonstration pour la Phase 1.
public enum MockData {
    public static let sessions: [AgentSession] = [
        AgentSession(projectName: "atoll", gitBranch: "main",
                     status: .working(tool: "Bash(xcodebuild build)"),
                     startedAt: Date().addingTimeInterval(-260),
                     model: "Fable 5", subagentCount: 2, mcpServers: ["github"],
                     contextUsedFraction: 0.45),
        AgentSession(projectName: "dynamic-island", gitBranch: "feat/notch",
                     status: .awaitingPermission(tool: "Edit(NotchPanel.swift)"),
                     startedAt: Date().addingTimeInterval(-1240)),
        AgentSession(projectName: "sandbox", gitBranch: nil,
                     status: .done,
                     startedAt: Date().addingTimeInterval(-3600))
    ]

    public static let usage = UsageSnapshot(fiveHourFraction: 0.27, sevenDayFraction: 0.11)
}
