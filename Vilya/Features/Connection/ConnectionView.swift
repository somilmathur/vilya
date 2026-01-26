import SwiftUI

struct ConnectionView: View {
    @Environment(AppState.self) var appState
    @State private var viewModel = ConnectionViewModel()

    var body: some View {
        @Bindable var vm = viewModel
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "terminal.fill").font(.system(size: 60)).foregroundStyle(.tint)
                        Text("Vilya").font(.largeTitle).fontWeight(.bold)
                        Text("SSH into your laptop from anywhere").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 20)

                    // Server Config
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Server").font(.headline).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            HStack {
                                Image(systemName: "network").foregroundStyle(.secondary).frame(width: 24)
                                TextField("Tailscale IP (e.g., 100.100.100.1)", text: $vm.host).keyboardType(.decimalPad).autocapitalization(.none)
                            }.padding().background(Color(.secondarySystemGroupedBackground))
                            Divider().padding(.leading, 48)
                            HStack {
                                Image(systemName: "number").foregroundStyle(.secondary).frame(width: 24)
                                TextField("Port", text: $vm.port).keyboardType(.numberPad)
                                Spacer(); Text("Default: 22").font(.caption).foregroundStyle(.tertiary)
                            }.padding().background(Color(.secondarySystemGroupedBackground))
                            Divider().padding(.leading, 48)
                            HStack {
                                Image(systemName: "person").foregroundStyle(.secondary).frame(width: 24)
                                TextField("Username", text: $vm.username).autocapitalization(.none)
                            }.padding().background(Color(.secondarySystemGroupedBackground))
                        }.clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // SSH Key
                    VStack(alignment: .leading, spacing: 16) {
                        Text("SSH Key").font(.headline).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            if viewModel.hasExistingKey {
                                HStack {
                                    Image(systemName: "key.fill").foregroundStyle(.green).frame(width: 24)
                                    VStack(alignment: .leading) {
                                        Text("SSH Key Ready"); Text(viewModel.keyFingerprint).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("View") { viewModel.showPublicKey = true }
                                }.padding().background(Color(.secondarySystemGroupedBackground))
                            } else {
                                Button { viewModel.generateSSHKey() } label: {
                                    HStack {
                                        Image(systemName: "key.fill").frame(width: 24); Text("Generate SSH Key"); Spacer()
                                        if viewModel.isGeneratingKey { ProgressView() } else { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                                    }.padding()
                                }.background(Color(.secondarySystemGroupedBackground))
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("Add the public key to ~/.ssh/authorized_keys on your laptop.").font(.caption).foregroundStyle(.secondary)
                    }

                    // Connect Button
                    Button { Task { await viewModel.connect() } } label: {
                        HStack {
                            if viewModel.isConnecting { ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)) }
                            else { Image(systemName: "link") }
                            Text(viewModel.isConnecting ? "Connecting..." : "Connect")
                        }.frame(maxWidth: .infinity).padding()
                        .background(viewModel.canConnect ? Color.accentColor : Color.gray)
                        .foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                    }.disabled(!viewModel.canConnect || viewModel.isConnecting)
                }.padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Connect")
            .alert("Connection Error", isPresented: $vm.showError) { Button("OK") {} } message: { Text(viewModel.errorMessage).font(.caption) }
            .sheet(isPresented: $vm.showPublicKey) { PublicKeySheet(publicKey: viewModel.publicKey) }
            .onChange(of: viewModel.isConnected) { _, connected in
                if connected { appState.isConnected = true; appState.currentServer = viewModel.server }
            }
            .onAppear {
                viewModel.setSSHService(appState.sshService)
            }
        }
    }
}

struct PublicKeySheet: View {
    let publicKey: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Add this key to your laptop").font(.headline)
                Text("~/.ssh/authorized_keys").font(.system(.body, design: .monospaced)).padding(8).background(Color(.tertiarySystemGroupedBackground)).clipShape(RoundedRectangle(cornerRadius: 6))
                ScrollView {
                    Text(publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
                }.frame(maxHeight: 200)
                Button { UIPasteboard.general.string = publicKey } label: {
                    Label("Copy to Clipboard", systemImage: "doc.on.doc").frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
            }.padding()
            .navigationTitle("Public Key").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

#Preview { ConnectionView().environment(AppState()) }
