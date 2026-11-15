import SwiftUI

/// "Shared Hub": 2+ pins within 50 m, shown as stacked photos, a `+N` badge, a luminous rotating
/// ring and the reverse-geocoded place name.
struct ClusterAnnotationView: View {
    let cluster: PinCluster
    let placeName: String?
    let currentUserID: UUID
    let isAppUnlocked: Bool
    let distanceText: String?
    let namespace: Namespace.ID
    let inactiveHeroPinIDs: Set<UUID>

    @State private var ringRotation: Double = 0

    private let hubDiameter: CGFloat = 88
    private let thumbSize: CGFloat = 46

    private var visiblePins: [PhotoPin] {
        Array(cluster.pins.prefix(3))
    }

    private var hasLockedPins: Bool {
        cluster.pins.contains { isLocked($0) }
    }

    private func isLocked(_ pin: PhotoPin) -> Bool {
        !isAppUnlocked && pin.author.id != currentUserID
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(Theme.surface.opacity(0.9))

                    Circle()
                        .stroke(Theme.ringGradient, lineWidth: 3)
                        .rotationEffect(.degrees(ringRotation))
                        .glow(Theme.neonPurple, radius: 10)

                    ForEach(Array(visiblePins.enumerated()), id: \.element.id) { index, pin in
                        PinThumbnail(pin: pin, size: thumbSize, isLocked: isLocked(pin))
                            .heroGeometry(id: pin.id, namespace: namespace, isActive: !inactiveHeroPinIDs.contains(pin.id))
                            .offset(offset(for: index, count: visiblePins.count))
                            .zIndex(Double(visiblePins.count - index))
                    }

                    if hasLockedPins {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(7)
                            .background(Circle().fill(Theme.obsidian.opacity(0.75)))
                            .zIndex(10)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: hubDiameter, height: hubDiameter)

                Text("cluster.badge \(cluster.pins.count - 1)")
                    .font(Theme.roundedFixed(12, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accentGradient))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                    .offset(x: 6, y: -2)
                    .fixedSize()
            }

            VStack(spacing: 1) {
                Text(verbatim: placeName ?? String(localized: "cluster.sharedHub"))
                    .font(Theme.roundedFixed(12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text("cluster.povs \(cluster.pins.count)")
                    if let distanceText {
                        Text(verbatim: "·")
                        Text(verbatim: distanceText)
                    }
                }
                .font(Theme.roundedFixed(10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: 170)
            .glassCard(cornerRadius: 14)
            .fixedSize(horizontal: false, vertical: true)

            PinTail()
                .fill(Theme.accentGradient)
                .frame(width: 14, height: 8)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 6)
        .animation(Theme.spring, value: isAppUnlocked)
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                ringRotation = 360
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: placeName ?? String(localized: "cluster.sharedHub")))
        .accessibilityValue(Text("cluster.povs \(cluster.pins.count)"))
        .accessibilityAddTraits(.isButton)
    }

    private func offset(for index: Int, count: Int) -> CGSize {
        switch (count, index) {
        case (2, 0): CGSize(width: -12, height: 0)
        case (2, 1): CGSize(width: 12, height: 0)
        case (3, 0): CGSize(width: -13, height: -9)
        case (3, 1): CGSize(width: 13, height: -9)
        case (3, 2): CGSize(width: 0, height: 13)
        default: .zero
        }
    }
}
