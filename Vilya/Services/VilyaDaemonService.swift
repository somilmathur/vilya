import Foundation

class VilyaDaemonService {
    private let sshService: SSHService
    private let controlSocketPath = "/tmp/vilya/control.sock"

    init(sshService: SSHService) { self.sshService = sshService }

    func listSessions() async throws -> [VilyaSession] {
        let response = try await sendCommand(["action": "list"])
        guard let sessions = response["sessions"] as? [[String: Any]] else {
            return []
        }
        return sessions.compactMap { dict -> VilyaSession? in
            guard let name = dict["name"] as? String,
                  let running = dict["running"] as? Bool else { return nil }
            return VilyaSession(name: name, running: running)
        }
    }

    func createSession(name: String) async throws {
        let response = try await sendCommand(["action": "create", "name": name])
        if let error = response["error"] as? String {
            throw VilyaDaemonError.sessionExists(name)
        }
    }

    func killSession(name: String) async throws {
        let response = try await sendCommand(["action": "kill", "name": name])
        if let error = response["error"] as? String {
            throw VilyaDaemonError.sessionNotFound(name)
        }
    }

    func attachCommand(sessionName: String, rows: Int, cols: Int) -> String {
        // Send JSON command to attach, daemon will respond with OK then switch to raw PTY mode
        let cmd = ["action": "attach", "name": sessionName, "rows": rows, "cols": cols] as [String: Any]
        let jsonData = try! JSONSerialization.data(withJSONObject: cmd)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        // Use socat to connect to unix socket and send the command
        return "echo '\(jsonString)' | nc -U \(controlSocketPath) | tail -n +2\n"
    }

    func isDaemonRunning() async throws -> Bool {
        do {
            // Check if socket exists
            let output = try await sshService.execute("test -S \(controlSocketPath) && echo 'running' || echo 'not running'")
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "running"
        } catch {
            return false
        }
    }

    func generateSessionName(prefix: String = "vilya") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmmss"
        return "\(prefix)-\(formatter.string(from: Date()))"
    }

    private func sendCommand(_ command: [String: Any]) async throws -> [String: Any] {
        let jsonData = try JSONSerialization.data(withJSONObject: command)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        // Use nc to send command to daemon via SSH
        let output = try await sshService.execute("echo '\(jsonString)' | nc -U \(controlSocketPath)")

        // Parse response
        guard let responseData = output.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return [:]
        }
        return response
    }
}

struct VilyaSession: Identifiable {
    let id = UUID()
    let name: String
    let running: Bool
}

enum VilyaDaemonError: Error, LocalizedError {
    case sessionExists(String), sessionNotFound(String), daemonNotRunning
    var errorDescription: String? {
        switch self {
        case .sessionExists(let n): return "Session '\(n)' already exists"
        case .sessionNotFound(let n): return "Session '\(n)' not found"
        case .daemonNotRunning: return "Vilya daemon is not running"
        }
    }
}
