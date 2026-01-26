import Foundation
import SwiftUI

enum Constants {
    static let appName = "Vilya"
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    enum Terminal {
        static let defaultFontSize: CGFloat = 14
        static let minFontSize: CGFloat = 8
        static let maxFontSize: CGFloat = 24
    }

    enum Notifications {
        static let commandCompletionThreshold: TimeInterval = 10.0
    }

    enum FileBrowser {
        static let maxPreviewSize: Int64 = 1024 * 1024
        static let supportedPreviewExtensions = ["txt", "md", "json", "yaml", "yml", "xml", "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "sh"]
    }

    enum Colors {
        static let terminalBackground = Color(hex: "1E1E1E")
        static let terminalForeground = Color(hex: "D4D4D4")
    }

    enum Layout {
        static let cornerRadius: CGFloat = 12
        static let padding: CGFloat = 16
    }

    enum UserDefaultsKeys {
        static let servers = "vilya.servers"
        static let lastConnectedServer = "vilya.lastConnectedServer"
        static let terminalFontSize = "vilya.terminalFontSize"
        static let hapticFeedbackEnabled = "vilya.hapticFeedbackEnabled"
        static let notificationsEnabled = "vilya.notificationsEnabled"
        static let notificationThreshold = "vilya.notificationThreshold"
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0; Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (r, g, b) = (0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}
