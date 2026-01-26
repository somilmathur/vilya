import Foundation
import SwiftUI
import Observation

@Observable
@MainActor
class ConnectionViewModel {
    var host = ""
    var port = "22"
    var username = ""
    var isConnecting = false
    var isConnected = false
    var isGeneratingKey = false
    var showError = false
    var errorMessage = ""
    var showPublicKey = false
    var hasExistingKey = false
    var publicKey = ""
    var keyFingerprint = ""

    private let keychainService = KeychainService()
    private var sshService: SSHService?
    private let keyId = "default"

    var server: Server { Server(name: host, host: host, port: Int(port) ?? 22, username: username, privateKeyId: keyId) }
    var canConnect: Bool { !host.isEmpty && !username.isEmpty && hasExistingKey && !isConnecting }

    init() { loadExistingKey(); loadLastServer() }

    func setSSHService(_ service: SSHService) {
        self.sshService = service
    }

    func loadExistingKey() {
        do {
            publicKey = try keychainService.getPublicKey(withId: keyId)
            hasExistingKey = true
            keyFingerprint = "SHA256:..." + String(publicKey.split(separator: " ")[1].suffix(8))
        } catch { hasExistingKey = false }
    }

    func generateSSHKey() {
        isGeneratingKey = true
        Task {
            do {
                let keyPair = try SSHKeyGenerator.generateEd25519KeyPair(comment: "vilya-\(UIDevice.current.name)")
                try keychainService.storePrivateKey(keyPair.privateKey, withId: keyId)
                try keychainService.storePublicKey(keyPair.publicKey, withId: keyId)
                self.publicKey = keyPair.publicKey
                self.keyFingerprint = keyPair.fingerprint
                self.hasExistingKey = true
                self.isGeneratingKey = false
                self.showPublicKey = true
            } catch {
                self.errorMessage = error.localizedDescription
                self.showError = true
                self.isGeneratingKey = false
            }
        }
    }

    func connect() async {
        guard canConnect, let sshService = sshService else { return }
        isConnecting = true
        do {
            let privateKey = try keychainService.getPrivateKey(withId: keyId)
            try await sshService.connect(host: host, port: Int(port) ?? 22, username: username, privateKey: privateKey)
            saveLastServer()
            isConnected = true
        } catch {
            // Provide more helpful error messages
            let errorDesc = "\(error)"
            if errorDesc.contains("NIOConnectionError") || errorDesc.contains("connection") {
                errorMessage = """
                    Could not connect to \(host):\(port)

                    Please verify:
                    • Tailscale is running on both devices
                    • The IP address is correct (run 'tailscale ip -4' on your Mac)
                    • Remote Login is enabled (System Settings → General → Sharing)
                    • Your Mac is not asleep
                    """
            } else if errorDesc.contains("authentication") || errorDesc.contains("Authentication") {
                errorMessage = """
                    Authentication failed

                    Please verify:
                    • Your public key is in ~/.ssh/authorized_keys on your Mac
                    • The username '\(username)' is correct
                    """
            } else {
                errorMessage = error.localizedDescription
            }
            showError = true
        }
        isConnecting = false
    }

    private func loadLastServer() {
        if let data = UserDefaults.standard.data(forKey: Constants.UserDefaultsKeys.lastConnectedServer),
           let server = try? JSONDecoder().decode(Server.self, from: data) {
            host = server.host; port = String(server.port); username = server.username
        }
    }

    private func saveLastServer() {
        if let data = try? JSONEncoder().encode(server) {
            UserDefaults.standard.set(data, forKey: Constants.UserDefaultsKeys.lastConnectedServer)
        }
    }
}
