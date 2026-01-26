import Foundation
import UserNotifications

class NotificationService: NSObject {
    static let shared = NotificationService()
    var isAuthorized = false

    private override init() { super.init(); checkAuthorizationStatus() }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run { self.isAuthorized = granted }
            return granted
        } catch { return false }
    }

    func checkAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { self.isAuthorized = settings.authorizationStatus == .authorized }
        }
    }

    func notifyCommandComplete(sessionName: String, duration: TimeInterval, command: String? = nil) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Command Complete"
        content.body = command.map { "\(String($0.prefix(50))) finished in \(formatDuration(duration))" } ?? "Command in '\(sessionName)' finished"
        content.sound = .default
        content.userInfo = ["sessionName": sessionName]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func notifyDisconnected(serverName: String) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Disconnected"
        content.body = "Lost connection to \(serverName)"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func notifyTransferComplete(fileName: String, isUpload: Bool, success: Bool) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = success ? (isUpload ? "Upload Complete" : "Download Complete") : (isUpload ? "Upload Failed" : "Download Failed")
        content.body = fileName
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func clearBadge() { UNUserNotificationCenter.current().setBadgeCount(0) }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        else if seconds < 3600 { return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s" }
        else { return "\(Int(seconds / 3600))h \(Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60))m" }
    }
}

class CommandWatcher {
    var notificationThreshold: TimeInterval = 10.0
    private var commandStartTime: Date?
    private var lastCommand: String?
    private let notificationService: NotificationService
    private let promptPatterns = ["\\$\\s*$", ">\\s*$", "\\]\\$\\s*$", "#\\s*$"]

    init(notificationService: NotificationService = .shared) { self.notificationService = notificationService }

    func processOutput(_ output: String, sessionName: String) {
        if containsPrompt(output), let start = commandStartTime {
            let duration = Date().timeIntervalSince(start)
            if duration >= notificationThreshold {
                notificationService.notifyCommandComplete(sessionName: sessionName, duration: duration, command: lastCommand)
            }
            commandStartTime = nil; lastCommand = nil
        }
    }

    func processInput(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, input.contains("\n") || input.contains("\r") else { return }
        commandStartTime = Date(); lastCommand = trimmed
    }

    private func containsPrompt(_ output: String) -> Bool {
        promptPatterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil
        }
    }

    func reset() { commandStartTime = nil; lastCommand = nil }
}
