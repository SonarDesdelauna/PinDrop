import SwiftUI

// MARK: - Glass background

/// Glass background. On iOS 26+ it is the system Liquid Glass, so it follows the look chosen in
/// Settings › Display & Brightness › Liquid Glass (Clear or Tinted). Earlier versions use
/// an ultra-thin material + tinted surface + luminous 1pt gradient border.
struct GlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color = Theme.surface
    var tintOpacity: Double = Theme.surfaceOpacity
    var shadowRadius: CGFloat = 22
    /// Reacts to touches (scale + light) like system glass buttons.
    var isInteractive = false
    /// Color tint for prominent glass (e.g. the accent color).
    var glassTint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(Glass.regular.tint(glassTint).interactive(isInteractive), in: shape)
        } else {
            legacy(content)
        }
    }

    private func legacy(_ content: Content) -> some View {
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay { shape.fill(tint.opacity(tintOpacity)) }
            }
            .overlay {
                shape
                    .strokeBorder(Theme.glassBorderGradient, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(0.12), radius: shadowRadius, x: 0, y: 8)
            .background {
                if let glassTint {
                    shape.fill(glassTint.opacity(0.55))
                }
            }
    }
}

// MARK: - Shimmer

/// A soft diagonal light sweep, used on call-to-action cards.
struct ShimmerModifier: ViewModifier {
    let isActive: Bool
    var duration: Double = 2.4
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        LinearGradient(
                            colors: [Color.white.opacity(0), Color.white.opacity(0.2), Color.white.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.5)
                        .rotationEffect(.degrees(12))
                        .offset(x: -width * 0.5 + phase * width * 1.5)
                    }
                    .allowsHitTesting(false)
                    .blendMode(.plusLighter)
                }
            }
            .onAppear {
                guard isActive else { return }
                phase = 0
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - Glow & pulse

struct GlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.55), radius: radius * 0.5)
            .shadow(color: color.opacity(0.3), radius: radius)
    }
}

struct PulseModifier: ViewModifier {
    let isActive: Bool
    @State private var isExpanded = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    content
                        .scaleEffect(isExpanded ? 2.4 : 1)
                        .opacity(isExpanded ? 0 : 0.7)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard isActive else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    isExpanded = true
                }
            }
    }
}

// MARK: - Button styles

/// Primary call to action: violet → neon gradient capsule.
struct PrimaryGradientButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(.headline, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 16)
            .padding(.horizontal, 22)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .modifier(PrimaryButtonBackground(isEnabled: isEnabled))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

/// Accent-tinted Liquid Glass capsule on iOS 26+, gradient capsule before.
private struct PrimaryButtonBackground: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .contentShape(Capsule())
                .glassEffect(Glass.regular.tint(Theme.electricViolet).interactive(), in: Capsule())
        } else {
            content
                .background { Capsule().fill(Theme.accentGradient) }
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1) }
                .shadow(color: Theme.electricViolet.opacity(isEnabled ? 0.45 : 0), radius: 18, x: 0, y: 8)
        }
    }
}

/// Secondary action: glass capsule.
struct GlassButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.neonPurple)
            .multilineTextAlignment(.center)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .contentShape(Capsule())
            .modifier(GlassBackground(shape: Capsule(), shadowRadius: 10, isInteractive: true))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

/// Round glass icon button (close, flash, flip…).
struct CircleGlassButtonStyle: ButtonStyle {
    var diameter: CGFloat = 44
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: diameter * 0.36, weight: .bold))
            .foregroundStyle(Theme.neonPurple)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .modifier(GlassBackground(shape: Circle(), shadowRadius: 8, isInteractive: true))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

/// Plain button with a tactile press-down scale.
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

// MARK: - View helpers

extension View {
    func glassCard(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }

    func glassCapsule(interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassBackground(shape: Capsule(), shadowRadius: 14, isInteractive: interactive, glassTint: tint))
    }

    func glassCircle(interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassBackground(shape: Circle(), shadowRadius: 12, isInteractive: interactive, glassTint: tint))
    }

    func shimmer(isActive: Bool = true) -> some View {
        modifier(ShimmerModifier(isActive: isActive))
    }

    func glow(_ color: Color, radius: CGFloat = 14) -> some View {
        modifier(GlowModifier(color: color, radius: radius))
    }

    func pulsing(isActive: Bool = true) -> some View {
        modifier(PulseModifier(isActive: isActive))
    }

    /// Hero transition helper built on `matchedGeometryEffect`.
    /// A view only participates in the hero group while `isActive` is true; otherwise it gets a
    /// private identifier so that the source and destination never claim the same id at once.
    func heroGeometry(id: UUID, namespace: Namespace.ID, isActive: Bool = true) -> some View {
        matchedGeometryEffect(
            id: isActive ? HeroID.active(id) : HeroID.idle(id),
            in: namespace,
            isSource: true
        )
    }
}

/// Identifiers used by `heroGeometry(id:namespace:isActive:)`.
enum HeroID: Hashable {
    case active(UUID)
    case idle(UUID)
}
