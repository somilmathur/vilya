import Foundation

class TmuxService {
    private let sshService: SSHService

    // tmux binary path - check common locations
    private static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux", "tmux"]
    private var tmuxPath = "tmux"

    init(sshService: SSHService) { self.sshService = sshService }

    func listSessions() async throws -> [TmuxSession] {
        let output = try await sshService.execute("\(tmuxPath) list-sessions -F '#{session_id}:#{session_name}:#{session_attached}:#{session_windows}' 2>/dev/null || echo ''")
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return output.split(separator: "\n").compactMap { line -> TmuxSession? in
            let parts = line.split(separator: ":")
            guard parts.count >= 4 else { return nil }
            return TmuxSession(id: String(parts[0]), name: String(parts[1]), attached: parts[2] == "1", windowCount: Int(parts[3]) ?? 1)
        }
    }

    func createSession(name: String) async throws {
        let safeName = name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "-")
        let output = try await sshService.execute("\(tmuxPath) new-session -d -s '\(safeName)' 2>&1")
        if output.contains("duplicate session") { throw TmuxError.sessionExists(name) }
        if output.contains("error") && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TmuxError.createFailed(output)
        }
    }

    func killSession(name: String) async throws {
        let output = try await sshService.execute("\(tmuxPath) kill-session -t '\(name)' 2>&1")
        if output.contains("session not found") { throw TmuxError.sessionNotFound(name) }
    }

    func attachCommand(sessionName: String) -> String {
        let safeName = sessionName.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "-")
        return "\(tmuxPath) attach-session -t '\(safeName)' || \(tmuxPath) new-session -s '\(safeName)'\n"
    }

    func detachCommand() -> String { "\(tmuxPath) detach-client\n" }

    func isTmuxInstalled() async throws -> Bool {
        do {
            // Check common tmux locations since PATH may not be fully loaded in non-interactive SSH
            let output = try await sshService.execute("""
                if [ -x /opt/homebrew/bin/tmux ]; then echo '/opt/homebrew/bin/tmux'; \
                elif [ -x /usr/local/bin/tmux ]; then echo '/usr/local/bin/tmux'; \
                elif [ -x /usr/bin/tmux ]; then echo '/usr/bin/tmux'; \
                else echo 'not found'; fi
                """)
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if path != "not found" && !path.isEmpty {
                tmuxPath = path
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func generateSessionName(prefix: String = "vilya") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmmss"
        return "\(prefix)-\(formatter.string(from: Date()))"
    }
}

enum TmuxError: Error, LocalizedError {
    case sessionExists(String), sessionNotFound(String), createFailed(String), notInstalled
    var errorDescription: String? {
        switch self {
        case .sessionExists(let n): return "Session '\(n)' already exists"
        case .sessionNotFound(let n): return "Session '\(n)' not found"
        case .createFailed(let m): return "Failed to create session: \(m)"
        case .notInstalled: return "tmux is not installed"
        }
    }
}
