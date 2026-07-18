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

    public let id: UUID
    public var projectName: String
    public var gitBranch: String?
    public var status: Status
    public var startedAt: Date

    public init(id: UUID = UUID(), projectName: String, gitBranch: String? = nil,
                status: Status, startedAt: Date = Date()) {
        self.id = id
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.status = status
        self.startedAt = startedAt
    }

    /// La session réclame l'attention de l'utilisateur.
    public var needsAttention: Bool {
        switch status {
        case .awaitingPermission, .awaitingInput: return true
        case .working, .done: return false
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
                     startedAt: Date().addingTimeInterval(-260)),
        AgentSession(projectName: "dynamic-island", gitBranch: "feat/notch",
                     status: .awaitingPermission(tool: "Edit(NotchPanel.swift)"),
                     startedAt: Date().addingTimeInterval(-1240)),
        AgentSession(projectName: "sandbox", gitBranch: nil,
                     status: .done,
                     startedAt: Date().addingTimeInterval(-3600))
    ]

    public static let usage = UsageSnapshot(fiveHourFraction: 0.27, sevenDayFraction: 0.11)
}
