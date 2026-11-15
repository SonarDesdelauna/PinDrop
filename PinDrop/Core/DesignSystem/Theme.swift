import SwiftUI

/// Central design tokens for PinDrop. Compiled into both the app and the widget extension.
enum Theme {
    // MARK: - Palette

    /// Primary background (#09090B, Obsidian Black).
    static let obsidian = Color(hex: 0x09090B)
    /// Elevated surfaces and cards (#121216), used at `surfaceOpacity` over a material.
    static let surface = Color(hex: 0x121216)
    static let surfaceOpacity: Double = 0.75
    /// Primary accent (#7C3AED, Electric Violet).
    static let electricViolet = Color(hex: 0x7C3AED)
    /// Gradient end of the primary accent (#A855F7, Neon Purple).
    static let neonPurple = Color(hex: 0xA855F7)
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
