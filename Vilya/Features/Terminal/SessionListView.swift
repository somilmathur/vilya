import SwiftUI

struct SessionListView: View {
    @Environment(AppState.self) var appState
    @State private var viewModel = SessionListViewModel()
    @State private var showNewSessionSheet = false
    @State private var selectedSession: TerminalSession?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.sessions.isEmpty && viewModel.serverSessions.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "terminal").font(.system(size: 60)).foregroundStyle(.secondary)
                        Text("No Sessions").font(.title2).fontWeight(.semibold)
                        Text("Create a new terminal session to get started.").font(.subheadline).foregroundStyle(.secondary)
                        Button { showNewSessionSheet = true } label: {
                            Label("New Session", systemImage: "plus").padding(.horizontal, 20).padding(.vertical, 12)
                                .background(Color.accentColor).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                } else {
                    List {
                        if !viewModel.sessions.isEmpty {
                            Section("Active Sessions") {
                                ForEach(viewModel.sessions.sorted { $0.lastActivity > $1.lastActivity }) { session in
                                    SessionRow(session: session).onTapGesture { selectedSession = session }
                                }.onDelete { viewModel.closeSessions(at: $0) }
                            }
                        }
                        if !viewModel.serverSessions.isEmpty {
                            Section("Server Sessions") {
                                ForEach(viewModel.serverSessions) { serverSession in
                                    ServerSessionRow(session: serverSession) { Task { if let s = await viewModel.attachToServerSession(serverSession) { selectedSession = s } } }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                Task { await viewModel.killServerSession(serverSession) }
                                            } label: {
                                                Label("Kill", systemImage: "xmark.circle.fill")
                                            }
                                        }
                                }
                            }
                        }
                    }.listStyle(.insetGrouped).refreshable { await viewModel.refreshServerSessions() }
                }
            }
            .navigationTitle("Terminals")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button { showNewSessionSheet = true } label: { Image(systemName: "plus") } }
                ToolbarItem(placement: .topBarLeading) { Button { Task { await viewModel.refreshServerSessions() } } label: { Image(systemName: "arrow.clockwise") } }
            }
            .sheet(isPresented: $showNewSessionSheet) { NewSessionSheet(viewModel: viewModel, onSessionCreated: { session in selectedSession = session }) }
            .navigationDestination(item: $selectedSession) { session in PTYTerminalView(session: session) }
            .task { viewModel.setSSHService(appState.sshService); await viewModel.refreshServerSessions() }
        }
    }
}

struct SessionRow: View {
    var session: TerminalSession
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(session.isActive ? Color.green : Color.gray).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name).fontWeight(.medium)
                if session.tmuxSessionName != nil { Label("persistent", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 4)
    }
}

struct ServerSessionRow: View {
    let session: VilyaSession; let onAttach: () -> Void
    var body: some View {
        Button(action: onAttach) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(session.running ? .green : .secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name).fontWeight(.medium).foregroundColor(.primary)
                    HStack {
                        Text("Persistent session").font(.caption).foregroundStyle(.secondary)
                        if session.running { Text("running").font(.caption).foregroundStyle(.green) }
                    }
                }
                Spacer(); Text("Attach").font(.subheadline).foregroundColor(.accentColor)
            }.padding(.vertical, 4)
        }
    }
}

struct NewSessionSheet: View {
    @Bindable var viewModel: SessionListViewModel
    var onSessionCreated: (TerminalSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sessionName = ""
    @State private var usePersistence = true

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Session Name", text: $sessionName) } footer: { Text("Leave blank for auto-generated name") }
                Section { Toggle("Persistent Session", isOn: $usePersistence) } footer: { Text("Keeps your session alive when you disconnect") }
            }
            .navigationTitle("New Session").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            let countBefore = viewModel.sessions.count
                            await viewModel.createSession(name: sessionName.isEmpty ? nil : sessionName, usePersistence: usePersistence)
                            dismiss()
                            // Navigate to the new session if it was created
                            if viewModel.sessions.count > countBefore, let newSession = viewModel.sessions.last {
                                onSessionCreated(newSession)
                            }
                        }
                    }
                }
            }
        }.presentationDetents([.medium])
    }
}

#Preview { SessionListView().environment(AppState()) }
