import SwiftUI
import Observation

@main
struct VilyaApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
    }
}

@Observable
class AppState {
    var isConnected: Bool = false
    var currentServer: Server?
    var sessions: [TerminalSession] = []

    let sshService = SSHService()
    let keychainService = KeychainService()
}
