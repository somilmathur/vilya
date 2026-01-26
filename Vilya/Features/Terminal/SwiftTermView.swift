import SwiftUI
import SwiftTerm
import UIKit

/// SwiftUI wrapper for SwiftTerm's TerminalView
struct SwiftTermView: UIViewRepresentable {
    let sshTerminal: SSHTerminal
    let fontSize: CGFloat

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let terminalView = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))

        // Configure terminal appearance
        terminalView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)

        // Set font
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.font = font

        // Configure colors for a nice dark theme
        terminalView.nativeForegroundColor = UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
        terminalView.nativeBackgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)

        // Disable SwiftTerm's built-in accessory view (we use our own toolbar)
        terminalView.inputAccessoryView = nil

        // Install custom color palette with brighter blues
        TerminalColors.installBrightPalette(on: terminalView.getTerminal())

        // Attach to SSH terminal
        sshTerminal.attachTerminalView(terminalView)

        // Start the shell session after ensuring terminal is properly initialized
        // We need to wait for SwiftTerm to have non-zero dimensions
        startShellWhenReady(terminal: terminalView, sshTerminal: sshTerminal)

        return terminalView
    }

    private func startShellWhenReady(terminal: SwiftTerm.TerminalView, sshTerminal: SSHTerminal, attempts: Int = 0) {
        let cols = terminal.getTerminal().cols
        let rows = terminal.getTerminal().rows

        if cols > 0 && rows > 0 {
            // Terminal is ready, start the shell
            sshTerminal.startShell()
        } else if attempts < 20 {
            // Wait and retry (up to 2 seconds total)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak terminal] in
                guard let terminal = terminal else { return }
                self.startShellWhenReady(terminal: terminal, sshTerminal: sshTerminal, attempts: attempts + 1)
            }
        } else {
            // Fallback: force a resize and start anyway
            print("Warning: Terminal dimensions still 0 after waiting, starting anyway")
            sshTerminal.startShell()
        }
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        // Update font size if changed
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        uiView.font = font
    }
}

/// Full terminal screen with toolbar
struct PTYTerminalView: View {
    var session: TerminalSession
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss
    @State private var sshTerminal: SSHTerminal?
    @State private var showToolbar = true
    @State private var isConnecting = true
    @State private var errorMessage: String?
    @State private var fontSize: CGFloat = 10

    private let keychainService = KeychainService()

    var body: some View {
        VStack(spacing: 0) {
            if isConnecting {
                // Loading state
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Connecting...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.1, green: 0.1, blue: 0.1))
            } else if let error = errorMessage {
                // Error state
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text("Connection Error")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Dismiss") { dismiss() }
                        .padding(.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.1, green: 0.1, blue: 0.1))
            } else if let terminal = sshTerminal {
                // Terminal view
                SwiftTermView(sshTerminal: terminal, fontSize: fontSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture()) // Consume swipe gestures to prevent back navigation

                if showToolbar {
                    PTYTerminalToolbar(sshTerminal: terminal, fontSize: $fontSize)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.1).ignoresSafeArea())
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.1, green: 0.1, blue: 0.1), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    sshTerminal?.disconnect()
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showToolbar.toggle() } label: {
                        Label(showToolbar ? "Hide Toolbar" : "Show Toolbar", systemImage: "keyboard")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .task {
            await connectToServer()
        }
        .onDisappear {
            sshTerminal?.disconnect()
        }
    }

    private func connectToServer() async {
        guard let server = appState.currentServer else {
            errorMessage = "No server configured"
            isConnecting = false
            return
        }

        do {
            let terminal = SSHTerminal()
            let privateKey = try keychainService.getPrivateKey(withId: "default")
            try await terminal.connect(
                host: server.host,
                port: server.port,
                username: server.username,
                privateKey: privateKey,
                tmuxSession: session.tmuxSessionName
            )
            self.sshTerminal = terminal
            isConnecting = false
        } catch {
            errorMessage = error.localizedDescription
            isConnecting = false
        }
    }
}

struct PTYTerminalToolbar: View {
    let sshTerminal: SSHTerminal
    @Binding var fontSize: CGFloat
    @State private var ctrlPressed = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Arrow keys first
                Button { sshTerminal.sendString("\u{1B}[A") } label: {
                    Image(systemName: "arrow.up").toolbarButtonStyle()
                }
                Button { sshTerminal.sendString("\u{1B}[B") } label: {
                    Image(systemName: "arrow.down").toolbarButtonStyle()
                }
                Button { sshTerminal.sendString("\u{1B}[D") } label: {
                    Image(systemName: "arrow.left").toolbarButtonStyle()
                }
                Button { sshTerminal.sendString("\u{1B}[C") } label: {
                    Image(systemName: "arrow.right").toolbarButtonStyle()
                }

                Divider().frame(height: 30)

                // Escape and Tab
                Button { sshTerminal.sendString("\u{1B}") } label: {
                    Text("Esc").toolbarButtonStyle()
                }

                Button { sshTerminal.sendString("\t") } label: {
                    Text("Tab").toolbarButtonStyle()
                }

                // Ctrl modifier
                Button {
                    ctrlPressed.toggle()
                } label: {
                    Text("Ctrl")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(ctrlPressed ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(ctrlPressed ? Color.accentColor : Color(.tertiarySystemBackground)))
                }

                Divider().frame(height: 30)

                // Common control sequences
                Button {
                    if ctrlPressed {
                        ctrlPressed = false
                    }
                    sshTerminal.sendString("\u{03}") // Ctrl+C
                } label: {
                    Text("Ctrl+C").toolbarButtonStyle()
                }

                Button { sshTerminal.sendString("\u{04}") } label: {
                    Text("Ctrl+D").toolbarButtonStyle()
                }

                Button { sshTerminal.sendString("\u{1A}") } label: {
                    Text("Ctrl+Z").toolbarButtonStyle()
                }

                Divider().frame(height: 30)

                // Font size controls at the end
                Button { fontSize = max(10, fontSize - 1) } label: {
                    Image(systemName: "textformat.size.smaller")
                        .toolbarButtonStyle()
                }

                Button { fontSize = min(24, fontSize + 1) } label: {
                    Image(systemName: "textformat.size.larger")
                        .toolbarButtonStyle()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemBackground))
    }
}

extension View {
    func toolbarButtonStyle() -> some View {
        self
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(.tertiarySystemBackground)))
    }
}
