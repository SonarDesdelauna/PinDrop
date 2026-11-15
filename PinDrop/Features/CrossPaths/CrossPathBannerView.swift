import SwiftUI

/// "You and Giulia crossed paths here 25 min apart": glass banner with a pulsing radar and a
/// quick button to compare both photos (unlocked for both of you).
struct CrossPathBannerView: View {
    let event: CrossPathEvent
    let onCompare: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RadarPulseView(size: 46)
                .overlay {
                    AvatarBadge(user: event.friend, size: 30)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text("crossPath.banner.title \(event.friend.firstName)")
                    .font(Theme.text(.subheadline, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("crossPath.banner.subtitle \(event.timeDeltaText) \(event.distanceText)")
                    .font(Theme.text(.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Image(systemName: "lock.open.fill")
                    Text("crossPath.banner.unlocked")
                }
                .font(Theme.text(.caption2, weight: .bold))
                .foregroundStyle(Theme.emeraldLight)
            }
            Spacer(minLength: 4)
            Button(action: onCompare) {
                Image(systemName: "square.split.2x1.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Theme.accentGradient))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text("crossPath.banner.compare"))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text("common.close"))
        }
        .padding(12)
        .glassCard(cornerRadius: 24)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.emerald.opacity(0.45), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture(perform: onCompare)
    }
}

/// Concentric emerald rings expanding forever, like a radar.
struct RadarPulseView: View {
    var size: CGFloat = 46
    var color: Color = Theme.emerald

    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(color.opacity(0.7), lineWidth: 1.5)
                    .scaleEffect(animate ? 1.35 : 0.45)
                    .opacity(animate ? 0 : 0.9)
                    .animation(
                        .easeOut(duration: 2.1).repeatForever(autoreverses: false).delay(Double(index) * 0.7),
                        value: animate
                    )
            }
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: size * 0.78, height: size * 0.78)
        }
        .frame(width: size, height: size)
        .onAppear {
            animate = true
        }
        .accessibilityHidden(true)
    }
}

/// Map marker where two friends crossed paths (annotation content: no environment access).
struct CrossPathMarkerView: View {
    let friend: UserProfile

    var body: some View {
        RadarPulseView(size: 64)
            .overlay {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.emerald))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
