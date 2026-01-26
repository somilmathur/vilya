import Foundation
import Citadel
import NIO
import NIOFoundationCompat
import Crypto
import CryptoKit

actor SSHService {
    private var client: SSHClient?
    private var sftpClient: SFTPClient?

    var isConnected: Bool {
        client != nil
    }

    // MARK: - Connection

    func connect(host: String, port: Int = 22, username: String, privateKey: String) async throws {
        // Parse the OpenSSH private key
        let authMethod = try parsePrivateKeyAuth(username: username, privateKey: privateKey)

        client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
    }

    func disconnect() async {
        try? await sftpClient?.close()
        sftpClient = nil

        try? await client?.close()
        client = nil
    }

    // MARK: - Shell

    func openShell(columns: Int = 80, rows: Int = 24) async throws -> String {
        guard let client = client else { throw SSHError.notConnected }

        let channelId = UUID().uuidString

        // For now, return the channel ID - actual shell implementation
        // would use client.withPTY() but that requires a different architecture
        return channelId
    }

    func write(_ string: String, toChannel channelId: String) async throws {
        // Shell writing would be implemented with the PTY callback
        // For now this is a placeholder
    }

    func readFromChannel(_ channelId: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            // Shell reading would be implemented with the PTY callback
            continuation.finish()
        }
    }

    func resizeTerminal(channelId: String, columns: Int, rows: Int) async throws {
        // Terminal resize would be implemented with PTY
    }

    func closeChannel(_ channelId: String) async {
        // Channel closing would be implemented with PTY
    }

    // MARK: - Command Execution

    func execute(_ command: String) async throws -> String {
        guard let client = client else { throw SSHError.notConnected }

        let buffer = try await client.executeCommand(command)
        return String(buffer: buffer)
    }

    // MARK: - SFTP

    func openSFTP() async throws {
        guard let client = client else { throw SSHError.notConnected }
        sftpClient = try await client.openSFTP()
    }

    func listDirectory(_ directoryPath: String) async throws -> [FileItem] {
        guard let sftp = sftpClient else { throw SSHError.sftpNotConnected }

        // Use ls command as fallback since SFTP API may vary
        guard let client = client else { throw SSHError.notConnected }

        let output = try await client.executeCommand("ls -la '\(directoryPath)'")
        let outputString = String(buffer: output)

        var items: [FileItem] = []
        let lines = outputString.split(separator: "\n").dropFirst() // Skip "total" line

        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }

            let permissions = String(parts[0])
            let name = parts.dropFirst(8).joined(separator: " ")
            guard name != "." && name != ".." else { continue }

            let isDirectory = permissions.hasPrefix("d")
            let size = Int64(parts[4]) ?? 0

            items.append(FileItem(
                name: name,
                path: (directoryPath as NSString).appendingPathComponent(name),
                isDirectory: isDirectory,
                size: size,
                modifiedDate: nil
            ))
        }

        return items
    }

    func downloadFile(remotePath: String, localPath: String, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard let sftp = sftpClient else { throw SSHError.sftpNotConnected }

        // Get file attributes for size
        let attributes = try await sftp.getAttributes(at: remotePath)
        let totalSize = Int64(attributes.size ?? 0)

        // Read file using withFile
        let data = try await sftp.withFile(filePath: remotePath, flags: .read) { file in
            try await file.readAll()
        }

        // Write to local path
        let url = URL(fileURLWithPath: localPath)
        try Data(buffer: data).write(to: url)

        progress(totalSize, totalSize)
    }

    func uploadFile(localPath: String, remotePath: String, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard let sftp = sftpClient else { throw SSHError.sftpNotConnected }

        let url = URL(fileURLWithPath: localPath)
        let data = try Data(contentsOf: url)
        let totalSize = Int64(data.count)

        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)

        try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
            try await file.write(buffer)
        }

        progress(totalSize, totalSize)
    }

    func createDirectory(_ path: String) async throws {
        guard let sftp = sftpClient else { throw SSHError.sftpNotConnected }
        try await sftp.createDirectory(atPath: path)
    }

    func delete(_ path: String, isDirectory: Bool) async throws {
        guard let sftp = sftpClient else { throw SSHError.sftpNotConnected }

        // Use shell command to delete since SFTP client may not have direct methods
        guard let client = client else { throw SSHError.notConnected }

        let command = isDirectory ? "rm -rf '\(path)'" : "rm -f '\(path)'"
        _ = try await client.executeCommand(command)
    }

    func readFile(_ path: String) async throws -> Data {
        guard let sftp = sftpClient else { throw SSHError.sftpNotConnected }

        let buffer = try await sftp.withFile(filePath: path, flags: .read) { file in
            try await file.readAll()
        }
        return Data(buffer: buffer)
    }

    // MARK: - Private Helpers

    private func parsePrivateKeyAuth(username: String, privateKey: String) throws -> SSHAuthenticationMethod {
        // Parse OpenSSH private key format to extract Ed25519 key
        let ed25519Key = try parseOpenSSHPrivateKey(privateKey)
        return .ed25519(username: username, privateKey: ed25519Key)
    }

    private func parseOpenSSHPrivateKey(_ pemString: String) throws -> Curve25519.Signing.PrivateKey {
        // Remove PEM headers and decode base64
        let base64Content = pemString
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let data = Data(base64Encoded: base64Content) else {
            throw SSHError.authenticationFailed
        }

        // Parse OpenSSH key format
        // Format: "openssh-key-v1\0" + cipher + kdf + kdf_options + num_keys + public_key + private_section
        var offset = 0

        // Check magic header "openssh-key-v1\0"
        let magic = "openssh-key-v1\0"
        let magicData = magic.data(using: .utf8)!
        guard data.count > magicData.count,
              data.prefix(magicData.count) == magicData else {
            throw SSHError.authenticationFailed
        }
        offset += magicData.count

        // Skip cipher name (should be "none")
        let (_, cipherEnd) = try readString(from: data, at: offset)
        offset = cipherEnd

        // Skip kdf name (should be "none")
        let (_, kdfEnd) = try readString(from: data, at: offset)
        offset = kdfEnd

        // Skip kdf options (should be empty)
        let (_, kdfOptionsEnd) = try readString(from: data, at: offset)
        offset = kdfOptionsEnd

        // Read number of keys (should be 1)
        guard offset + 4 <= data.count else { throw SSHError.authenticationFailed }
        offset += 4

        // Skip public key section
        guard offset + 4 <= data.count else { throw SSHError.authenticationFailed }
        let pubKeyLen = Int(readUInt32(from: data, at: offset))
        offset += 4 + pubKeyLen

        // Read private section length
        guard offset + 4 <= data.count else { throw SSHError.authenticationFailed }
        let privSectionLen = Int(readUInt32(from: data, at: offset))
        offset += 4

        guard offset + privSectionLen <= data.count else { throw SSHError.authenticationFailed }

        // Parse private section
        var privOffset = offset

        // Skip two check integers (random, for encryption verification)
        privOffset += 8

        // Skip key type string "ssh-ed25519"
        let (_, keyTypeEnd) = try readString(from: data, at: privOffset)
        privOffset = keyTypeEnd

        // Skip public key in private section
        guard privOffset + 4 <= data.count else { throw SSHError.authenticationFailed }
        let pubInPrivLen = Int(readUInt32(from: data, at: privOffset))
        privOffset += 4 + pubInPrivLen

        // Read the actual private key (64 bytes: 32 private + 32 public)
        guard privOffset + 4 <= data.count else { throw SSHError.authenticationFailed }
        let fullPrivKeyLen = Int(readUInt32(from: data, at: privOffset))
        privOffset += 4

        guard privOffset + fullPrivKeyLen <= data.count else { throw SSHError.authenticationFailed }

        // Ed25519 private key is first 32 bytes of the 64-byte blob
        let privateKeyBytes = data.subdata(in: privOffset..<(privOffset + 32))

        return try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
    }

    private func readString(from data: Data, at offset: Int) throws -> (String, Int) {
        guard offset + 4 <= data.count else { throw SSHError.authenticationFailed }
        let length = Int(readUInt32(from: data, at: offset))
        let start = offset + 4
        guard start + length <= data.count else { throw SSHError.authenticationFailed }
        let stringData = data.subdata(in: start..<(start + length))
        let string = String(data: stringData, encoding: .utf8) ?? ""
        return (string, start + length)
    }

    private func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        let bytes = data.subdata(in: offset..<(offset + 4))
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}

// MARK: - SSH Errors

enum SSHError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case channelOpenFailed
    case channelNotFound
    case writeError(String)
    case commandFailed(String)
    case sessionClosed
    case invalidData
    case sftpConnectionFailed
    case sftpNotConnected
    case sftpListFailed
    case downloadFailed
    case uploadFailed
    case createDirectoryFailed
    case deleteFailed
    case readFileFailed

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .authenticationFailed: return "Authentication failed - private key auth not yet implemented"
        case .channelOpenFailed: return "Failed to open channel"
        case .channelNotFound: return "Channel not found"
        case .writeError(let m): return "Write error: \(m)"
        case .commandFailed(let m): return "Command failed: \(m)"
        case .sessionClosed: return "Session closed"
        case .invalidData: return "Invalid data"
        case .sftpConnectionFailed: return "SFTP connection failed"
        case .sftpNotConnected: return "SFTP not connected"
        case .sftpListFailed: return "Failed to list directory"
        case .downloadFailed: return "Download failed"
        case .uploadFailed: return "Upload failed"
        case .createDirectoryFailed: return "Failed to create directory"
        case .deleteFailed: return "Failed to delete"
        case .readFileFailed: return "Failed to read file"
        }
    }
}
