import Foundation
import SwiftUI
import Observation

@Observable
@MainActor
class TerminalViewModel {
    var terminalOutput = ""
    var currentInput = ""
    var fontSize: CGFloat = Constants.Terminal.defaultFontSize
    var ctrlPressed = false
    var isConnected = false
    var isExecuting = false

    weak var inputField: UITextField?
    private var session: TerminalSession?
    private var sshService: SSHService?
    private var currentDirectory = "~"
    private var commandHistory: [String] = []
    private var historyIndex = -1

    func setSSHService(_ service: SSHService) {
        self.sshService = service
    }

    func attachToSession(_ session: TerminalSession) {
        self.session = session
        isConnected = true
        appendOutput("Connected to \(session.name)\n")
        if let tmux = session.tmuxSessionName { appendOutput("tmux session: \(tmux)\n") }
        appendOutput("\n")

        // Get initial directory and show prompt
        Task {
            if let sshService = sshService {
                do {
                    let home = try await sshService.execute("echo $HOME")
                    currentDirectory = home.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {}
            }
            showPrompt()
        }
    }

    func detach() {
        // No-op for command mode
    }

    func disconnect() {
        session?.isActive = false
        isConnected = false
    }

    func focus() { inputField?.becomeFirstResponder() }

    func hideKeyboard() { inputField?.resignFirstResponder() }

    func sendInput(_ input: String) {
        // Handle special characters
        if input == "\u{7F}" || input == "\u{08}" {
            // Backspace
            if !currentInput.isEmpty {
                currentInput.removeLast()
                // Remove last character from output (the one we typed)
                if terminalOutput.hasSuffix(String(currentInput.last ?? " ")) {
                    // Redraw the prompt and current input
                    removeLastLine()
                    showPrompt()
                    appendOutput(currentInput)
                }
            }
            return
        }

        if ctrlPressed && input.count == 1, let char = input.lowercased().first, let ascii = char.asciiValue {
            let ctrlChar = String(Character(UnicodeScalar(ascii - 96)))
            ctrlPressed = false
            if ctrlChar == "\u{03}" { // Ctrl+C
                currentInput = ""
                appendOutput("^C\n")
                showPrompt()
            }
            return
        }

        if input == "\n" || input == "\r" {
            executeCurrentCommand()
        } else {
            currentInput += input
            appendOutput(input)
        }
    }

    private func executeCurrentCommand() {
        let command = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        appendOutput("\n")

        guard !command.isEmpty else {
            showPrompt()
            return
        }

        // Add to history
        commandHistory.append(command)
        historyIndex = commandHistory.count
        currentInput = ""

        // Handle cd specially
        if command.hasPrefix("cd ") || command == "cd" {
            handleCd(command)
            return
        }

        // Handle clear
        if command == "clear" {
            terminalOutput = ""
            showPrompt()
            return
        }

        isExecuting = true
        Task {
            await executeCommand(command)
            isExecuting = false
            showPrompt()
        }
    }

    private func handleCd(_ command: String) {
        let path: String
        if command == "cd" {
            path = "~"
        } else {
            path = String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }

        Task {
            guard let sshService = sshService else { return }
            do {
                // Resolve the path
                let resolvedPath: String
                if path.hasPrefix("/") {
                    resolvedPath = path
                } else if path.hasPrefix("~") {
                    let home = try await sshService.execute("echo $HOME").trimmingCharacters(in: .whitespacesAndNewlines)
                    resolvedPath = path.replacingOccurrences(of: "~", with: home)
                } else {
                    resolvedPath = currentDirectory + "/" + path
                }

                // Check if directory exists
                let checkResult = try await sshService.execute("cd '\(resolvedPath)' && pwd")
                let newDir = checkResult.trimmingCharacters(in: .whitespacesAndNewlines)
                if !newDir.isEmpty && !newDir.contains("No such file") {
                    currentDirectory = newDir
                } else {
                    appendOutput("cd: no such file or directory: \(path)\n")
                }
            } catch {
                appendOutput("cd: \(error.localizedDescription)\n")
            }
            showPrompt()
        }
    }

    private func executeCommand(_ command: String) async {
        guard let sshService = sshService else {
            appendOutput("[Not connected]\n")
            return
        }

        do {
            // Execute command in the current directory
            let fullCommand = "cd '\(currentDirectory)' && \(command)"
            let output = try await sshService.execute(fullCommand)
            if !output.isEmpty {
                appendOutput(output)
                if !output.hasSuffix("\n") {
                    appendOutput("\n")
                }
            }
        } catch {
            appendOutput("[Error: \(error.localizedDescription)]\n")
        }
    }

    private func showPrompt() {
        let displayDir = currentDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let shortDir = displayDir.hasSuffix("/") ? displayDir : (displayDir as NSString).lastPathComponent
        appendOutput("\(shortDir) $ ")
    }

    private func removeLastLine() {
        if let lastNewline = terminalOutput.lastIndex(of: "\n") {
            terminalOutput = String(terminalOutput[...lastNewline])
        }
    }

    func sendEscape() { }
    func sendTab() {
        // Simple tab completion - just add spaces for now
        currentInput += "    "
        appendOutput("    ")
    }
    func sendArrowUp() {
        if historyIndex > 0 {
            historyIndex -= 1
            replaceCurrentInput(with: commandHistory[historyIndex])
        }
    }
    func sendArrowDown() {
        if historyIndex < commandHistory.count - 1 {
            historyIndex += 1
            replaceCurrentInput(with: commandHistory[historyIndex])
        } else {
            historyIndex = commandHistory.count
            replaceCurrentInput(with: "")
        }
    }
    func sendArrowRight() { }
    func sendArrowLeft() { }
    func sendCtrlC() {
        currentInput = ""
        appendOutput("^C\n")
        showPrompt()
    }
    func sendCtrlD() {
        appendOutput("logout\n")
        disconnect()
    }
    func sendCtrlZ() { }
    func clearScreen() {
        terminalOutput = ""
        showPrompt()
    }

    private func replaceCurrentInput(with newInput: String) {
        removeLastLine()
        showPrompt()
        currentInput = newInput
        appendOutput(currentInput)
    }

    private func appendOutput(_ text: String) {
        terminalOutput += text
        session?.lastActivity = Date()
        if terminalOutput.count > 100_000 { terminalOutput = String(terminalOutput.suffix(50_000)) }
    }
}
