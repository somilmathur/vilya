import SwiftUI
import Observation

struct SettingsView: View {
    @Environment(AppState.self) var appState
    @State private var viewModel = SettingsViewModel()
    @State private var showDisconnectAlert = false

    var body: some View {
        @Bindable var vm = viewModel
        NavigationStack {
            List {
                Section("Connection") {
                    if let server = appState.currentServer {
                        HStack { Label("Server", systemImage: "server.rack"); Spacer(); Text(server.host).foregroundStyle(.secondary) }
                        HStack { Label("Username", systemImage: "person"); Spacer(); Text(server.username).foregroundStyle(.secondary) }
                        Button(role: .destructive) { showDisconnectAlert = true } label: { Label("Disconnect", systemImage: "xmark.circle") }
                    }
                }
                Section("Terminal") {
                    HStack { Label("Font Size", systemImage: "textformat.size"); Spacer()
                        Stepper("\(Int(viewModel.terminalFontSize))", value: $vm.terminalFontSize, in: Constants.Terminal.minFontSize...Constants.Terminal.maxFontSize, step: 2)
                    }
                    Toggle(isOn: $vm.hapticFeedbackEnabled) { Label("Haptic Feedback", systemImage: "hand.tap") }
                }
                Section("Notifications") {
                    Toggle(isOn: $vm.notificationsEnabled) { Label("Enable Notifications", systemImage: "bell") }
                    if viewModel.notificationsEnabled {
                        HStack { Label("Threshold", systemImage: "timer"); Spacer()
                            Picker("", selection: $vm.notificationThreshold) {
                                Text("5 seconds").tag(5.0); Text("10 seconds").tag(10.0); Text("30 seconds").tag(30.0); Text("1 minute").tag(60.0)
                            }.pickerStyle(.menu)
                        }
                    }
                }
                Section("SSH Key") { NavigationLink { SSHKeyDetailView() } label: { Label("Manage SSH Key", systemImage: "key") } }
                Section("About") {
                    HStack { Label("Version", systemImage: "info.circle"); Spacer(); Text(Constants.appVersion).foregroundStyle(.secondary) }
                    Link(destination: URL(string: "https://tailscale.com")!) { Label("Get Tailscale", systemImage: "network") }
                }
            }
            .navigationTitle("Settings")
            .alert("Disconnect", isPresented: $showDisconnectAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Disconnect", role: .destructive) {
                    Task {
                        await appState.sshService.disconnect()
                        await MainActor.run {
                            appState.isConnected = false
                            appState.currentServer = nil
                        }
                    }
                }
            } message: { Text("Are you sure you want to disconnect?") }
        }
    }
}

@Observable
class SettingsViewModel {
    var terminalFontSize: CGFloat {
        didSet { UserDefaults.standard.set(terminalFontSize, forKey: Constants.UserDefaultsKeys.terminalFontSize) }
    }
    var hapticFeedbackEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticFeedbackEnabled, forKey: Constants.UserDefaultsKeys.hapticFeedbackEnabled) }
    }
    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Constants.UserDefaultsKeys.notificationsEnabled); if notificationsEnabled { Task { await NotificationService.shared.requestAuthorization() } } }
    }
    var notificationThreshold: TimeInterval {
        didSet { UserDefaults.standard.set(notificationThreshold, forKey: Constants.UserDefaultsKeys.notificationThreshold) }
    }

    init() {
        terminalFontSize = UserDefaults.standard.object(forKey: Constants.UserDefaultsKeys.terminalFontSize) as? CGFloat ?? Constants.Terminal.defaultFontSize
        hapticFeedbackEnabled = UserDefaults.standard.object(forKey: Constants.UserDefaultsKeys.hapticFeedbackEnabled) as? Bool ?? true
        notificationsEnabled = UserDefaults.standard.object(forKey: Constants.UserDefaultsKeys.notificationsEnabled) as? Bool ?? true
        notificationThreshold = UserDefaults.standard.object(forKey: Constants.UserDefaultsKeys.notificationThreshold) as? TimeInterval ?? Constants.Notifications.commandCompletionThreshold
    }
}

struct SSHKeyDetailView: View {
    @State private var publicKey = ""; @State private var fingerprint = ""; @State private var showRegenerateAlert = false; @State private var isRegenerating = false
    private let keychainService = KeychainService()

    var body: some View {
        List {
            Section("Public Key") { Text(publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            Section("Fingerprint") { Text(fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            Section {
                Button { UIPasteboard.general.string = publicKey } label: { Label("Copy Public Key", systemImage: "doc.on.doc") }
                Button(role: .destructive) { showRegenerateAlert = true } label: { Label("Regenerate Key Pair", systemImage: "arrow.triangle.2.circlepath") }
            }
        }
        .navigationTitle("SSH Key").navigationBarTitleDisplayMode(.inline)
        .onAppear { loadKey() }
        .alert("Regenerate Key?", isPresented: $showRegenerateAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) { regenerateKey() }
        } message: { Text("You'll need to add the new public key to your laptop.") }
        .overlay { if isRegenerating { ProgressView("Generating...").padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 10)) } }
    }

    private func loadKey() {
        do { publicKey = try keychainService.getPublicKey(withId: "default"); fingerprint = "SHA256:..." + String(publicKey.split(separator: " ")[1].suffix(8)) }
        catch { publicKey = "No key found"; fingerprint = "N/A" }
    }

    private func regenerateKey() {
        isRegenerating = true
        Task {
            do {
                let keyPair = try SSHKeyGenerator.generateEd25519KeyPair(comment: "vilya-\(UIDevice.current.name)")
                try keychainService.storePrivateKey(keyPair.privateKey, withId: "default")
                try keychainService.storePublicKey(keyPair.publicKey, withId: "default")
                await MainActor.run { publicKey = keyPair.publicKey; fingerprint = keyPair.fingerprint; isRegenerating = false }
            } catch { await MainActor.run { isRegenerating = false } }
        }
    }
}

#Preview { SettingsView().environment(AppState()) }
