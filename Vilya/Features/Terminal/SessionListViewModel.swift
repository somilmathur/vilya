import Foundation
import Observation

@Observable
@MainActor
class SessionListViewModel {
    var sessions: [TerminalSession] = []
    var serverSessions: [VilyaSession] = []
    var isLoading = false
    var errorMessage: String?

    private var sshService: SSHService?
    private var daemonService: VilyaDaemonService?

    func setSSHService(_ service: SSHService) {
        self.sshService = service
        self.daemonService = VilyaDaemonService(sshService: service)
    }

    func createSession(name: String?, usePersistence: Bool) async {
        guard sshService != nil else { return }
        let sessionName = name ?? generateSessionName()

        var actuallyUsePersistence = usePersistence
        if usePersistence, let daemonService = daemonService {
            let daemonRunning = (try? await daemonService.isDaemonRunning()) ?? false
            if !daemonRunning {
                actuallyUsePersistence = false
                errorMessage = "Vilya daemon not running on server"
            }
        }

        do {
            if actuallyUsePersistence, let daemonService = daemonService {
                try await daemonService.createSession(name: sessionName)
            }
            // Note: tmuxSessionName is reused for daemon session name for compatibility
            let session = TerminalSession(serverId: UUID(), name: sessionName, tmuxSessionName: actuallyUsePersistence ? sessionName : nil)
            session.channelId = UUID().uuidString
            sessions.append(session)
        } catch {
            // Session might already exist, which is fine - we'll attach to it
            if error is VilyaDaemonError {
                let session = TerminalSession(serverId: UUID(), name: sessionName, tmuxSessionName: sessionName)
                session.channelId = UUID().uuidString
                sessions.append(session)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func attachToServerSession(_ serverSession: VilyaSession) async -> TerminalSession? {
        guard sshService != nil else { return nil }
        if let existing = sessions.first(where: { $0.tmuxSessionName == serverSession.name }) { return existing }

        let session = TerminalSession(serverId: UUID(), name: serverSession.name, tmuxSessionName: serverSession.name)
        session.channelId = UUID().uuidString
        sessions.append(session)
        return session
    }

    func closeSession(_ session: TerminalSession) async {
        if let channelId = session.channelId, let sshService = sshService {
            await sshService.closeChannel(channelId)
        }
        sessions.removeAll { $0.id == session.id }
    }

    func closeSessions(at offsets: IndexSet) {
        Task {
            for index in offsets {
                await closeSession(sessions[index])
            }
        }
    }

    func refreshServerSessions() async {
        guard let daemonService = daemonService else { return }
        isLoading = true; defer { isLoading = false }
        do { serverSessions = try await daemonService.listSessions() } catch { serverSessions = [] }
    }

    func killServerSession(_ session: VilyaSession) async {
        guard let daemonService = daemonService else { return }
        do {
            try await daemonService.killSession(name: session.name)
            // Also remove any local session attached to it
            sessions.removeAll { $0.tmuxSessionName == session.name }
            // Refresh the list
            await refreshServerSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateSessionName() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "HH-mm"
        return "session-\(formatter.string(from: Date()))"
    }
}
