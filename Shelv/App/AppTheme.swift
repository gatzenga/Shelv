import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

struct ThemeOption {
    let name: String
    let localizationKey: String
    let color: Color
    let useDarkCheckmark: Bool
}

struct AppTheme {
    static let options: [ThemeOption] = [
        ThemeOption(name: "violet",     localizationKey: "theme.violet",     color: Color(hex: "7C3AED"), useDarkCheckmark: false),
        ThemeOption(name: "blue",       localizationKey: "theme.blue",       color: Color(hex: "0077FF"), useDarkCheckmark: false),
        ThemeOption(name: "green",      localizationKey: "theme.green",      color: Color(hex: "00B56A"), useDarkCheckmark: false),
        ThemeOption(name: "lightpink",  localizationKey: "theme.light_pink", color: Color(hex: "FF6B9D"), useDarkCheckmark: false),
        ThemeOption(name: "lime",       localizationKey: "theme.lime",       color: Color(hex: "84CC16"), useDarkCheckmark: true),
        ThemeOption(name: "pink",       localizationKey: "theme.pink",       color: Color(hex: "FF1988"), useDarkCheckmark: false),
        ThemeOption(name: "pumpkin",    localizationKey: "theme.pumpkin",    color: Color(hex: "F97316"), useDarkCheckmark: false),
        ThemeOption(name: "red",        localizationKey: "theme.red",        color: Color(hex: "DC2626"), useDarkCheckmark: false),
        ThemeOption(name: "teal",       localizationKey: "theme.teal",       color: Color(hex: "14B8A6"), useDarkCheckmark: false),
        ThemeOption(name: "yellow",     localizationKey: "theme.yellow",     color: Color(hex: "F59E0B"), useDarkCheckmark: true),
    ]

    static func color(for name: String) -> Color {
        options.first { $0.name == name }?.color ?? options[0].color
    }

    static func option(for name: String) -> ThemeOption {
        options.first { $0.name == name } ?? options[0]
    }
}
