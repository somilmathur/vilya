import Foundation
import UIKit
import SwiftTerm
import Citadel
import NIO
import NIOSSH
import CryptoKit

/// Bridges SwiftTerm's TerminalView with Citadel's SSH PTY session
@MainActor
class SSHTerminal {
    private var client: SSHClient?
    private weak var terminalView: SwiftTerm.TerminalView?
    private var ptyTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<Data>.Continuation?

    var isConnected = false
    var connectionError: String?

    private var columns: Int = 80
    private var rows: Int = 24
    private var tmuxSessionName: String?

    func connect(host: String, port: Int = 22, username: String, privateKey: String, tmuxSession: String? = nil) async throws {
        self.tmuxSessionName = tmuxSession
        let authMethod = try parsePrivateKeyAuth(username: username, privateKey: privateKey)

        client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        isConnected = true
    }

    func attachTerminalView(_ view: SwiftTerm.TerminalView) {
        self.terminalView = view
        view.terminalDelegate = self
        // Don't read dimensions here - wait until startShell when view is laid out
    }

    func startShell() {
        guard let client = client else { return }

        ptyTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                // Create input stream for sending data to the PTY
                let (inputStream, inputContinuation) = AsyncStream<Data>.makeStream()
                await MainActor.run {
                    self.inputContinuation = inputContinuation
                }

                // Get dimensions now, after the view has been laid out
                // Ensure we have valid dimensions (minimum 1x1, default 80x24)
                let (cols, rows) = await MainActor.run { () -> (Int, Int) in
                    if let view = self.terminalView {
                        let terminal = view.getTerminal()
                        let c = terminal.cols > 0 ? terminal.cols : 80
                        let r = terminal.rows > 0 ? terminal.rows : 24
                        self.columns = c
                        self.rows = r
                        return (c, r)
                    }
                    return (max(self.columns, 80), max(self.rows, 24))
                }

                let sessionName = await MainActor.run { self.tmuxSessionName }

                if let sessionName = sessionName {
                    // For persistent sessions, use DirectTCPIP tunnel to daemon
                    // This bypasses SSH shell entirely, avoiding canonical mode buffering
                    print("[Vilya] *** USING DIRECTTCPIP FOR SESSION: \(sessionName) ***")
                    try await startDaemonSession(client: client, sessionName: sessionName, cols: cols, rows: rows, inputStream: inputStream)
                } else {
                    // Regular session - use normal PTY
                    try await startRegularPTY(client: client, cols: cols, rows: rows, inputStream: inputStream)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.connectionError = error.localizedDescription
                    self?.isConnected = false
                    // Feed error message to terminal
                    let errorMsg = "\r\n[Connection closed: \(error.localizedDescription)]\r\n"
                    if let bytes = errorMsg.data(using: .utf8) {
                        self?.terminalView?.feed(byteArray: Array(bytes)[...])
                    }
                }
            }
        }
    }

    private func startRegularPTY(client: SSHClient, cols: Int, rows: Int, inputStream: AsyncStream<Data>) async throws {
        try await client.withPTY(
            .init(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
        ) { inbound, outbound in
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Task 1: Read from SSH and write to terminal
                group.addTask {
                    for try await output in inbound {
                        switch output {
                        case .stdout(let buffer):
                            let bytes = Array(buffer.readableBytesView)[...]
                            await MainActor.run { [weak self] in
                                self?.terminalView?.feed(byteArray: bytes)
                            }
                        case .stderr(let buffer):
                            let bytes = Array(buffer.readableBytesView)[...]
                            await MainActor.run { [weak self] in
                                self?.terminalView?.feed(byteArray: bytes)
                            }
                        }
                    }
                }

                // Task 2: Read from terminal input and write to SSH
                group.addTask {
                    for await data in inputStream {
                        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                        buffer.writeBytes(data)
                        try await outbound.write(buffer)
                    }
                }

                try await group.next()
                group.cancelAll()
            }
        }
    }

    private func startDaemonViaPTY(client: SSHClient, sessionName: String, cols: Int, rows: Int, inputStream: AsyncStream<Data>) async throws {
        // Use PTY to run the daemon attach command
        // This has the double-echo issue but at least works
        let safeName = sessionName.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "-")
        let attachCmd = "~/.vilya/vilya-daemon.py attach '\(safeName)' --rows \(rows) --cols \(cols) --raw"

        try await client.withPTY(
            .init(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
        ) { inbound, outbound in
            // Send the attach command
            var cmdBuffer = ByteBufferAllocator().buffer(capacity: attachCmd.count + 1)
            cmdBuffer.writeString(attachCmd + "\n")
            try await outbound.write(cmdBuffer)

            try await withThrowingTaskGroup(of: Void.self) { group in
                // Task 1: Read from SSH and write to terminal
                group.addTask {
                    for try await output in inbound {
                        switch output {
                        case .stdout(let buffer):
                            let bytes = Array(buffer.readableBytesView)[...]
                            await MainActor.run { [weak self] in
                                self?.terminalView?.feed(byteArray: bytes)
                            }
                        case .stderr(let buffer):
                            let bytes = Array(buffer.readableBytesView)[...]
                            await MainActor.run { [weak self] in
                                self?.terminalView?.feed(byteArray: bytes)
                            }
                        }
                    }
                }

                // Task 2: Read from terminal input and write to SSH
                group.addTask {
                    for await data in inputStream {
                        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                        buffer.writeBytes(data)
                        try await outbound.write(buffer)
                    }
                }

                try await group.next()
                group.cancelAll()
            }
        }
    }

    private func startDaemonSession(client: SSHClient, sessionName: String, cols: Int, rows: Int, inputStream: AsyncStream<Data>) async throws {
        // DirectTCPIP approach - bypasses SSH shell entirely
        let safeName = sessionName.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "-")

        print("[Vilya] Starting DirectTCPIP to daemon for session: \(safeName)")

        // Create async stream for receiving data from the channel
        let (dataStream, dataContinuation) = AsyncStream<ByteBuffer>.makeStream()

        // Create a handler to capture inbound data
        let handler = DaemonChannelHandler(continuation: dataContinuation)

        // Create a direct TCP/IP channel to the daemon's TCP port (17177)
        print("[Vilya] Creating DirectTCPIP channel to 127.0.0.1:17177")
        let channel = try await client.createDirectTCPIPChannel(
            using: .init(
                targetHost: "127.0.0.1",
                targetPort: 17177,
                originatorAddress: try .init(ipAddress: "127.0.0.1", port: 0)
            )
        ) { channel in
            channel.pipeline.addHandler(handler)
        }
        print("[Vilya] DirectTCPIP channel created successfully")

        // Ensure terminal view is ready before sending/receiving data
        // Wait for terminal to have valid dimensions
        var terminalReady = false
        for _ in 0..<20 {
            let ready = await MainActor.run { () -> Bool in
                if let view = self.terminalView {
                    let terminal = view.getTerminal()
                    return terminal.cols > 0 && terminal.rows > 0
                }
                return false
            }
            if ready {
                terminalReady = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        if !terminalReady {
            print("Warning: Terminal dimensions still 0 after waiting")
        }

        // Send attach command as JSON
        let jsonCmd = #"{"action":"attach","name":"\#(safeName)","rows":\#(rows),"cols":\#(cols),"direct":true}"#
        var cmdBuffer = ByteBufferAllocator().buffer(capacity: jsonCmd.count)
        cmdBuffer.writeString(jsonCmd)
        try await channel.writeAndFlush(cmdBuffer)

        // Now proxy I/O between SwiftTerm and the channel
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Task 1: Read from channel and write to terminal
                group.addTask { [weak self] in
                    for await buffer in dataStream {
                        var bytes = Array(buffer.readableBytesView)
                        // Filter out problematic escape sequences that crash SwiftTerm
                        // DECSET/DECRST 2026 (synchronized output) causes cursor position issues
                        bytes = self?.filterProblematicSequences(bytes) ?? bytes
                        await MainActor.run {
                            self?.terminalView?.feed(byteArray: bytes[...])
                        }
                    }
                    print("[Vilya] Channel read task ended")
                }

                // Task 2: Read from terminal input and write to channel
                group.addTask {
                    for await data in inputStream {
                        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                        buffer.writeBytes(data)
                        try await channel.writeAndFlush(buffer)
                    }
                    print("[Vilya] Input write task ended")
                }

                // Wait for both tasks - don't cancel on first completion
                while !group.isEmpty {
                    do {
                        try await group.next()
                    } catch {
                        print("[Vilya] Task error: \(error)")
                    }
                }
            }
        } catch {
            print("[Vilya] Task group error: \(error)")
        }

        try? await channel.close()
    }

    /// Filter out escape sequences that cause SwiftTerm to crash
    nonisolated private func filterProblematicSequences(_ bytes: [UInt8]) -> [UInt8] {
        // Look for CSI sequences: ESC [ ... h or ESC [ ... l
        // Specifically filter DECSET/DECRST 2026 (synchronized output)
        // Pattern: \x1b[?2026h or \x1b[?2026l
        var result = bytes
        let esc: UInt8 = 0x1b
        let bracket: UInt8 = 0x5b // [
        let question: UInt8 = 0x3f // ?
        let h: UInt8 = 0x68 // h
        let l: UInt8 = 0x6c // l

        // Simple pattern matching for \x1b[?2026h and \x1b[?2026l
        let pattern1: [UInt8] = [esc, bracket, question, 0x32, 0x30, 0x32, 0x36, h] // ESC[?2026h
        let pattern2: [UInt8] = [esc, bracket, question, 0x32, 0x30, 0x32, 0x36, l] // ESC[?2026l

        result = removePattern(from: result, pattern: pattern1)
        result = removePattern(from: result, pattern: pattern2)

        return result
    }

    nonisolated private func removePattern(from bytes: [UInt8], pattern: [UInt8]) -> [UInt8] {
        guard pattern.count > 0 else { return bytes }
        var result: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if i + pattern.count <= bytes.count {
                let slice = Array(bytes[i..<(i + pattern.count)])
                if slice == pattern {
                    i += pattern.count
                    continue
                }
            }
            result.append(bytes[i])
            i += 1
        }
        return result
    }

    func sendData(_ data: Data) {
        inputContinuation?.yield(data)
    }

    func sendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            sendData(data)
        }
    }

    func resize(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        // Note: For dynamic resize, we'd need to use outbound.changeSize()
        // but we don't have access to it outside the withPTY closure
    }

    func disconnect() {
        ptyTask?.cancel()
        inputContinuation?.finish()
        Task {
            try? await client?.close()
            await MainActor.run {
                self.client = nil
                self.isConnected = false
            }
        }
    }

    // MARK: - Private Key Parsing

    private func parsePrivateKeyAuth(username: String, privateKey: String) throws -> SSHAuthenticationMethod {
        let ed25519Key = try parseOpenSSHPrivateKey(privateKey)
        return .ed25519(username: username, privateKey: ed25519Key)
    }

    private func parseOpenSSHPrivateKey(_ pemString: String) throws -> Curve25519.Signing.PrivateKey {
        let base64Content = pemString
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let data = Data(base64Encoded: base64Content) else {
            throw SSHTerminalError.invalidKey
        }

        var offset = 0
        let magic = "openssh-key-v1\0"
        let magicData = magic.data(using: .utf8)!
        guard data.count > magicData.count, data.prefix(magicData.count) == magicData else {
            throw SSHTerminalError.invalidKey
        }
        offset += magicData.count

        // Skip cipher, kdf, kdf options
        let (_, cipherEnd) = try readString(from: data, at: offset)
        offset = cipherEnd
        let (_, kdfEnd) = try readString(from: data, at: offset)
        offset = kdfEnd
        let (_, kdfOptionsEnd) = try readString(from: data, at: offset)
        offset = kdfOptionsEnd

        // Skip number of keys
        guard offset + 4 <= data.count else { throw SSHTerminalError.invalidKey }
        offset += 4

        // Skip public key section
        guard offset + 4 <= data.count else { throw SSHTerminalError.invalidKey }
        let pubKeyLen = Int(readUInt32(from: data, at: offset))
        offset += 4 + pubKeyLen

        // Read private section
        guard offset + 4 <= data.count else { throw SSHTerminalError.invalidKey }
        let privSectionLen = Int(readUInt32(from: data, at: offset))
        offset += 4
        guard offset + privSectionLen <= data.count else { throw SSHTerminalError.invalidKey }

        var privOffset = offset
        privOffset += 8 // Skip check integers

        let (_, keyTypeEnd) = try readString(from: data, at: privOffset)
        privOffset = keyTypeEnd

        guard privOffset + 4 <= data.count else { throw SSHTerminalError.invalidKey }
        let pubInPrivLen = Int(readUInt32(from: data, at: privOffset))
        privOffset += 4 + pubInPrivLen

        guard privOffset + 4 <= data.count else { throw SSHTerminalError.invalidKey }
        _ = Int(readUInt32(from: data, at: privOffset))
        privOffset += 4

        let privateKeyBytes = data.subdata(in: privOffset..<(privOffset + 32))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
    }

    private func readString(from data: Data, at offset: Int) throws -> (String, Int) {
        guard offset + 4 <= data.count else { throw SSHTerminalError.invalidKey }
        let length = Int(readUInt32(from: data, at: offset))
        let start = offset + 4
        guard start + length <= data.count else { throw SSHTerminalError.invalidKey }
        let stringData = data.subdata(in: start..<(start + length))
        let string = String(data: stringData, encoding: .utf8) ?? ""
        return (string, start + length)
    }

    private func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        let bytes = data.subdata(in: offset..<(offset + 4))
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}

// MARK: - Daemon Channel Handler

/// Handler to capture inbound data from the DirectTCPIP channel
final class DaemonChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncStream<ByteBuffer>.Continuation

    init(continuation: AsyncStream<ByteBuffer>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        print("[Vilya] DirectTCPIP received \(buffer.readableBytes) bytes")
        continuation.yield(buffer)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish()
        context.close(promise: nil)
    }
}

// MARK: - TerminalViewDelegate

extension SSHTerminal: TerminalViewDelegate {
    nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            self.resize(columns: newCols, rows: newRows)
        }
    }

    nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
        // Could update navigation title
    }

    nonisolated func setTerminalIconTitle(source: SwiftTerm.TerminalView, title: String) {
        // Optional
    }

    nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        let dataToSend = Data(data)
        Task { @MainActor in
            self.sendData(dataToSend)
        }
    }

    nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {
        // Optional scroll handling
    }

    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        // Optional
    }

    nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {
        if let url = URL(string: link) {
            Task { @MainActor in
                UIApplication.shared.open(url)
            }
        }
    }

    nonisolated func bell(source: SwiftTerm.TerminalView) {
        Task { @MainActor in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let string = String(data: content, encoding: .utf8) {
            Task { @MainActor in
                UIPasteboard.general.string = string
            }
        }
    }

    nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
        // Optional
    }
}

enum SSHTerminalError: Error, LocalizedError {
    case invalidKey
    case notConnected
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "Invalid SSH private key"
        case .notConnected: return "Not connected to server"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        }
    }
}
