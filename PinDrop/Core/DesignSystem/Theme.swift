import SwiftUI

/// Central design tokens for PinDrop. Compiled into both the app and the widget extension.
enum Theme {
    // MARK: - Palette

    /// Primary background (#09090B, Obsidian Black).
    static let obsidian = Color(hex: 0x09090B)
    /// Elevated surfaces and cards (#121216), used at `surfaceOpacity` over a material.
    static let surface = Color(hex: 0x121216)
    static let surfaceOpacity: Double = 0.75
    /// Primary accent: the user's profile color (default #7C3AED, Electric Violet).
    static var electricViolet: Color {
        AccentStore.palette.primary
    }
    /// Gradient end of the primary accent: a lighter tint of the profile color.
    static var neonPurple: Color {
        AccentStore.palette.secondary
    }
    /// Secondary accent, success and live state (#10B981, Emerald Pulse).
    static let emerald = Color(hex: 0x10B981)
    static let emeraldLight = Color(hex: 0x34D399)
    /// Primary text (#FAFAFA).
    static let textPrimary = Color(hex: 0xFAFAFA)
    /// Secondary text (#A1A1AA).
    static let textSecondary = Color(hex: 0xA1A1AA)
    static let danger = Color(hex: 0xF43F5E)
    static let warning = Color(hex: 0xF59E0B)

    // MARK: - Gradients

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [electricViolet, neonPurple], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var emeraldGradient: LinearGradient {
        LinearGradient(colors: [emerald, emeraldLight], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Glass border: white 0.18 → 0.04, used with a 1pt stroke.
    static var glassBorderGradient: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var ringGradient: AngularGradient {
        AngularGradient(colors: [neonPurple, electricViolet, neonPurple], center: .center)
    }

    static var liveRingGradient: AngularGradient {
        AngularGradient(colors: [emeraldLight, emerald, emeraldLight], center: .center)
    }

    static var photoScrim: LinearGradient {
        LinearGradient(
            colors: [Color.black.opacity(0), Color.black.opacity(0.35), Color.black.opacity(0.8)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Motion

    /// The signature spring used across the app.
    static var spring: Animation {
        .spring(response: 0.38, dampingFraction: 0.78)
    }

    // MARK: - Metrics

    enum Radius {
        static let photo: CGFloat = 26
        static let card: CGFloat = 28
        static let sheet: CGFloat = 32
        static let control: CGFloat = 20
    }

    // MARK: - Typography

    /// Rounded design: numbers, distances, timers and badges. Scales with Dynamic Type.
    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }

    /// Default design: copy and captions. Scales with Dynamic Type.
    static func text(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default, weight: weight)
    }

    /// Fixed-size rounded font for very small, layout-constrained badges (map pins, widgets).
    static func roundedFixed(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The app-wide accent color, chosen by the user as their profile color. Stored in the App Group
/// so the widget uses it too. The UI is rebuilt when it changes (see `RootView`).
enum AccentStore {
    static let defaultHex = "#7C3AED"
    private static let key = "pindrop.accentHex"

    struct Palette {
        let primary: Color
        let secondary: Color
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.pindrop.app")
    }

    static var hex: String {
        defaults?.string(forKey: key) ?? defaultHex
    }

    static func setHex(_ value: String) {
        defaults?.set(value, forKey: key)
    }

    static var palette: Palette {
        palette(for: hex)
    }

    static func palette(for hex: String) -> Palette {
        let rgb = rgbComponents(hex)
        let primary = Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2, opacity: 1)
        let mix = 0.32
        let secondary = Color(
            .sRGB,
            red: rgb.0 + (1 - rgb.0) * mix,
            green: rgb.1 + (1 - rgb.1) * mix,
            blue: rgb.2 + (1 - rgb.2) * mix,
            opacity: 1
        )
        return Palette(primary: primary, secondary: secondary)
    }

    private static func rgbComponents(_ hex: String) -> (Double, Double, Double) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return (124.0 / 255, 58.0 / 255, 237.0 / 255)
        }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}

extension Color {
    /// Creates a color from a 24-bit RGB hex value, e.g. `0x7C3AED`.
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    /// Creates a color from a `#RRGGBB` string, falling back to Electric Violet for invalid input.
    init(hexString: String, fallback: UInt32 = 0x7C3AED) {
        let cleaned = hexString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        if cleaned.count == 6, let value = UInt32(cleaned, radix: 16) {
            self.init(hex: value)
        } else {
            self.init(hex: fallback)
        }
    }
}
