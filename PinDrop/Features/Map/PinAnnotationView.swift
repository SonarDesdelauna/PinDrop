import SwiftUI

/// Circular photo pin with a 6-hour countdown ring, blur-to-unlock state and distance badge.
struct PinAnnotationView: View {
    let pin: PhotoPin
    let thumbnail: PinImage?
    let isOwn: Bool
    let isLocked: Bool
    let distanceText: String?
    let namespace: Namespace.ID
    let isHeroActive: Bool
    /// The author has the app open right now.
    var isOnline = false

    private let diameter: CGFloat = 60
    private var ringDiameter: CGFloat { diameter + 12 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Theme.obsidian.opacity(0.7))
                    .frame(width: ringDiameter + 4, height: ringDiameter + 4)
                    .overlay {
                        if isOnline {
                            Circle()
                                .strokeBorder(Theme.emerald, lineWidth: 3)
                                .shadow(color: Theme.emerald.opacity(0.7), radius: 8)
                        }
                    }

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ExpiryRing(progress: pin.remainingFraction(at: context.date), lineWidth: 3.5, isLive: isOwn)
                }
                .frame(width: ringDiameter, height: ringDiameter)

                PinThumbnail(pin: pin, image: thumbnail, size: diameter, isLocked: isLocked)
                    .heroGeometry(id: pin.id, namespace: namespace, isActive: isHeroActive)

                if isLocked {
                    lockBadge
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: ringDiameter + 4, height: ringDiameter + 4)

            nameTag

            PinTail()
                .fill(isOwn ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.accentGradient))
                .frame(width: 14, height: 8)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 6)
        .animation(Theme.spring, value: isLocked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: isOwn ? String(localized: "pin.you") : pin.author.displayName))
        .accessibilityValue(isLocked ? Text("a11y.pin.locked") : Text("a11y.pin.unlocked"))
        .accessibilityAddTraits(.isButton)
    }

    private var lockBadge: some View {
        VStack(spacing: 2) {
            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .bold))
            if let distanceText {
                Text(verbatim: distanceText)
                    .font(Theme.roundedFixed(10, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(width: diameter - 10)
    }

    private var nameTag: some View {
        HStack(spacing: 4) {
            if isOwn {
                Circle()
                    .fill(Theme.emerald)
                    .frame(width: 6, height: 6)
                Text("pin.you")
            } else {
                Text(verbatim: pin.author.firstName)
            }
            if !isLocked, let distanceText {
                Text(verbatim: "·")
                    .foregroundStyle(Theme.textSecondary)
                Text(verbatim: distanceText)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(Theme.roundedFixed(11, weight: .bold))
        .foregroundStyle(Theme.textPrimary)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .glassCapsule()
        .fixedSize()
    }
}

// MARK: - Shared pin components

/// Circular countdown ring that empties proportionally to the remaining lifetime.
struct ExpiryRing: View {
    let progress: Double
    var lineWidth: CGFloat = 3.5
    var isLive = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(
                    isLive ? Theme.liveRingGradient : Theme.ringGradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut(duration: 0.6), value: progress)
    }
}

/// Round photo thumbnail; frosted (blur 18) while the map is locked. While locked only the
/// server-side pre-blurred preview is ever downloaded.
/// The image is passed in explicitly: Map annotation content does not inherit custom
/// environment values, so it must never read `AppState` from the environment.
struct PinThumbnail: View {
    let pin: PhotoPin
    let image: PinImage?
    let size: CGFloat
    let isLocked: Bool

    var body: some View {
        ZStack {
            if let source = image,
               let image = ImageCache.image(forKey: source.key, data: source.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(hexString: pin.author.avatarColorHex)
            }
        }
        .frame(width: size, height: size)
        .blur(radius: isLocked ? 18 : 0, opaque: true)
        .overlay {
            if isLocked {
                Color.black.opacity(0.28)
            }
        }
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
        }
        .accessibilityHidden(true)
    }
}

/// Initials or photo avatar.
struct AvatarBadge: View {
    let user: UserProfile
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            initialsView
            if let url = user.avatarURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var initialsView: some View {
        let base = Color(hexString: user.avatarColorHex)
        return ZStack {
            LinearGradient(colors: [base, base.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(verbatim: user.initials)
                .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
        }
    }
}

/// Small downward triangle under map pins.
struct PinTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
