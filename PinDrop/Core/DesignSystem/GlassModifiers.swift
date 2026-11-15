import SwiftUI

// MARK: - Glass background

/// Glassmorphism background: ultra-thin material + tinted surface + luminous 1pt gradient border.
struct GlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color = Theme.surface
    var tintOpacity: Double = Theme.surfaceOpacity
    var shadowRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay { shape.fill(tint.opacity(tintOpacity)) }
                    .environment(\.colorScheme, .dark)
            }
            .overlay {
                shape
                    .strokeBorder(Theme.glassBorderGradient, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(0.35), radius: shadowRadius, x: 0, y: 10)
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
            .background { Capsule().fill(Theme.accentGradient) }
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1) }
            .shadow(color: Theme.electricViolet.opacity(isEnabled ? 0.45 : 0), radius: 18, x: 0, y: 8)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

/// Secondary action: glass capsule.
struct GlassButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .modifier(GlassBackground(shape: Capsule(), shadowRadius: 10))
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
            .foregroundStyle(Theme.textPrimary)
            .frame(width: diameter, height: diameter)
            .modifier(GlassBackground(shape: Circle(), shadowRadius: 8))
            .contentShape(Circle())
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

    func glassCapsule() -> some View {
        modifier(GlassBackground(shape: Capsule(), shadowRadius: 14))
    }

    func glassCircle() -> some View {
        modifier(GlassBackground(shape: Circle(), shadowRadius: 12))
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
