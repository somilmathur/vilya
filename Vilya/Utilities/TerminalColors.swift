import Foundation
import SwiftTerm

/// Custom terminal color palette with brighter blues for better visibility
enum TerminalColors {
    /// Creates a SwiftTerm.Color from 8-bit RGB values
    private static func color(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        // SwiftTerm.Color uses 16-bit values, multiply 8-bit by 257 to scale
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }

    /// Installs a custom color palette with brighter blues on the terminal
    static func installBrightPalette(on terminal: Terminal) {
        let colors: [SwiftTerm.Color] = [
            // Standard colors (0-7)
            color(0, 0, 0),             // 0: Black
            color(204, 51, 51),         // 1: Red
            color(51, 204, 51),         // 2: Green
            color(204, 204, 51),        // 3: Yellow
            color(102, 153, 255),       // 4: Blue (brighter!)
            color(204, 102, 204),       // 5: Magenta
            color(102, 204, 204),       // 6: Cyan
            color(204, 204, 204),       // 7: White
            // Bright colors (8-15)
            color(102, 102, 102),       // 8: Bright Black
            color(255, 102, 102),       // 9: Bright Red
            color(102, 255, 102),       // 10: Bright Green
            color(255, 255, 102),       // 11: Bright Yellow
            color(153, 204, 255),       // 12: Bright Blue (brighter!)
            color(255, 153, 255),       // 13: Bright Magenta
            color(153, 255, 255),       // 14: Bright Cyan
            color(255, 255, 255),       // 15: Bright White
        ]
        terminal.installPalette(colors: colors)
    }
}
