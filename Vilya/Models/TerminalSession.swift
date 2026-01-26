import Foundation
import Observation

@Observable
class TerminalSession: Identifiable, Hashable {
    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: UUID
    let serverId: UUID
    var name: String
    var tmuxSessionName: String?
    var isActive: Bool
    var lastActivity: Date
    var channelId: String?

    init(id: UUID = UUID(), serverId: UUID, name: String, tmuxSessionName: String? = nil, isActive: Bool = true) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.tmuxSessionName = tmuxSessionName
        self.isActive = isActive
        self.lastActivity = Date()
    }
}

struct TmuxSession: Identifiable, Equatable {
    let id: String
    let name: String
    let attached: Bool
    let windowCount: Int
    let createdAt: Date?

    init(id: String, name: String, attached: Bool = false, windowCount: Int = 1, createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.attached = attached
        self.windowCount = windowCount
        self.createdAt = createdAt
    }
}
