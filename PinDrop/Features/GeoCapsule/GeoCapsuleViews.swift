import SwiftUI
import UIKit

private enum CapsuleColors {
    static let amber = Color(hex: 0xF59E0B)
    static let violet = Color(hex: 0xA855F7)

    static var gradient: LinearGradient {
        LinearGradient(colors: [amber, violet], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Map annotation

/// A Geo-Capsule on the map: a pulsing amber → violet crystal while locked, an open gem once
/// opened (annotation content: data is passed in, no environment access).
struct GeoCapsuleAnnotationView: View {
    let author: UserProfile
    let isOpened: Bool
    let isOwn: Bool
    let distanceText: String?

    @State private var isPulsing = false
    @State private var isFloating = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if !isOpened {
                    Circle()
                        .fill(CapsuleColors.amber.opacity(0.35))
                        .frame(width: 58, height: 58)
                        .scaleEffect(isPulsing ? 1.25 : 0.8)
                        .opacity(isPulsing ? 0 : 0.8)
                        .blur(radius: 2)
                }
                CrystalShape()
                    .fill(isOpened ? AnyShapeStyle(Theme.emeraldGradient) : AnyShapeStyle(CapsuleColors.gradient))
                    .frame(width: 34, height: 44)
                    .overlay {
                        CrystalShape()
                            .stroke(Color.white.opacity(0.7), lineWidth: 1.2)
                    }
                    .overlay {
                        CrystalFacets()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                            .frame(width: 34, height: 44)
                    }
                    .overlay {
                        Image(systemName: isOpened ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .shadow(color: Color.black.opacity(0.4), radius: 2)
                    }
                    .shadow(color: (isOpened ? Theme.emerald : CapsuleColors.amber).opacity(0.7), radius: 12)
                    .rotation3DEffect(.degrees(isFloating ? 14 : -14), axis: (x: 0, y: 1, z: 0))
                    .offset(y: isFloating ? -3 : 3)
                AvatarBadge(user: author, size: 20)
                    .overlay(Circle().strokeBorder(Theme.obsidian, lineWidth: 1.5))
                    .offset(x: 18, y: 16)
            }
            .frame(width: 60, height: 60)

            HStack(spacing: 4) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(isOpened ? Theme.emeraldLight : CapsuleColors.amber)
                if isOwn {
                    Text("capsule.annotation.yours")
                } else if let distanceText, !isOpened {
                    Text(verbatim: distanceText)
                } else {
                    Text(verbatim: author.firstName)
                }
            }
            .font(Theme.roundedFixed(10, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassCapsule()
            .fixedSize()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                isFloating = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("capsule.a11y \(author.firstName)"))
        .accessibilityAddTraits(.isButton)
    }
}

/// An elongated gem outline.
struct CrystalShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.32))
        path.addLine(to: CGPoint(x: rect.maxX * 0.86, y: rect.height * 0.78))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.14, y: rect.height * 0.78))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.32))
        path.closeSubpath()
        return path
    }
}

/// Inner facet lines of the gem.
struct CrystalFacets: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.32))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.32))
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.width * 0.3, y: rect.height * 0.32))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.7, y: rect.height * 0.32))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }
}

// MARK: - Detail sheet

/// Locked: author, hint and how far you are. Opened: photo and secret message.
struct GeoCapsuleSheet: View {
    let capsule: GeoCapsule

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false

    private var isOpened: Bool {
        appState.isCapsuleOpened(capsule)
    }

    private var isOwn: Bool {
        appState.isOwnCapsule(capsule)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if isOpened {
                        openedContent
                    } else {
                        lockedContent
                    }
                    expiry
                    if isOwn {
                        ownFooter
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(Text("capsule.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("common.done")
                            .fontWeight(.semibold)
                    }
                }
            }
            .confirmationDialog(Text("capsule.delete.confirm"), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button(role: .destructive) {
                    Task { await appState.deleteCapsule(capsule) }
                } label: {
                    Text("capsule.delete")
                }
            }
        }
        .preferredColorScheme(.light)
        .task {
            await appState.loadCapsuleContent(capsule)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AvatarBadge(user: capsule.author, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                if isOwn {
                    Text("capsule.header.yours")
                        .font(Theme.text(.headline, weight: .bold))
                } else {
                    Text("capsule.header.from \(capsule.author.firstName)")
                        .font(Theme.text(.headline, weight: .bold))
                }
                if let recipient = capsule.recipientID {
                    if recipient == appState.currentUser.id {
                        Text("capsule.header.forYou")
                            .font(Theme.text(.caption, weight: .semibold))
                            .foregroundStyle(CapsuleColors.amber)
                    } else if let friend = appState.friends.first(where: { $0.id == recipient }) {
                        Text("capsule.header.for \(friend.firstName)")
                            .font(Theme.text(.caption, weight: .semibold))
                            .foregroundStyle(CapsuleColors.amber)
                    }
                } else {
                    Text("capsule.header.everyone")
                        .font(Theme.text(.caption))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
    }

    private var lockedContent: some View {
        VStack(spacing: 16) {
            ZStack {
                RadialGradient(colors: [CapsuleColors.amber.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 140)
                CrystalShape()
                    .fill(CapsuleColors.gradient)
                    .frame(width: 90, height: 118)
                    .overlay(CrystalShape().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
                    .overlay(CrystalFacets().stroke(Color.white.opacity(0.35), lineWidth: 1).frame(width: 90, height: 118))
                    .overlay {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 26, weight: .heavy))
                            .foregroundStyle(Color.white)
                    }
                    .shadow(color: CapsuleColors.amber.opacity(0.6), radius: 24)
            }
            .frame(height: 190)

            if !capsule.hint.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(CapsuleColors.amber)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("capsule.hint")
                            .font(Theme.text(.caption, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .textCase(.uppercase)
                        Text(verbatim: capsule.hint)
                            .font(Theme.text(.body, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .glassCard(cornerRadius: Theme.Radius.control)
            }

            VStack(spacing: 8) {
                if let distance = appState.distance(to: capsule) {
                    Text(verbatim: LocaleFormatter.distance(meters: distance))
                        .font(Theme.rounded(.largeTitle, weight: .heavy))
                        .foregroundStyle(CapsuleColors.gradient)
                        .contentTransition(.numericText())
                }
                Text("capsule.locked.body \(LocaleFormatter.distance(meters: GeoCapsule.unlockRadius))")
                    .font(Theme.text(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                appState.presentedCapsule = nil
                appState.showOnMap(capsule.location)
            } label: {
                Label("capsule.showOnMap", systemImage: "map.fill")
            }
            .buttonStyle(GlassButtonStyle())
        }
    }

    private var openedContent: some View {
        VStack(spacing: 14) {
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    if let source = appState.capsuleImage(for: capsule),
                       let image = ImageCache.image(forKey: source.key, data: source.data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Theme.surface
                            ProgressView()
                                .tint(Color.white)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(CapsuleColors.gradient, lineWidth: 1.5)
                }
                .shadow(color: CapsuleColors.violet.opacity(0.3), radius: 20, x: 0, y: 10)

            if let message = appState.capsuleSecret(for: capsule), !message.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "envelope.open.fill")
                        .foregroundStyle(CapsuleColors.violet)
                    Text(verbatim: message)
                        .font(Theme.text(.body, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .glassCard(cornerRadius: Theme.Radius.control)
            }

            if !capsule.hint.isEmpty {
                Label {
                    Text(verbatim: capsule.hint)
                } icon: {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(CapsuleColors.amber)
                }
                .font(Theme.text(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var expiry: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
            Text("capsule.expires \(Text(capsule.expiresAt, style: .relative))")
        }
        .font(Theme.rounded(.caption, weight: .bold))
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity)
    }

    private var ownFooter: some View {
        VStack(spacing: 10) {
            let count = appState.capsuleOpenCounts[capsule.id] ?? 0
            Label {
                Text("capsule.openedBy \(count)")
            } icon: {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(Theme.emerald)
            }
            .font(Theme.text(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(12)
            .glassCard(cornerRadius: Theme.Radius.control)

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("capsule.delete", systemImage: "trash")
                    .foregroundStyle(Theme.danger)
            }
            .buttonStyle(GlassButtonStyle())
        }
    }
}

// MARK: - Unlock celebration

/// Full-screen celebration when you reach a capsule: the crystal shakes, bursts open and
/// reveals the photo and the secret message.
struct CapsuleUnlockCelebrationView: View {
    let capsule: GeoCapsule

    @Environment(AppState.self) private var appState
    @State private var stage = 0
    @State private var burst = false
    @State private var shake = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture {
                    if stage >= 2 { close() }
                }

            RadialGradient(colors: [CapsuleColors.amber.opacity(burst ? 0.45 : 0.15), .clear], center: .center, startRadius: 0, endRadius: burst ? 420 : 160)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if stage < 2 {
                crystal
                    .transition(.scale(scale: 1.8).combined(with: .opacity))
            } else {
                reveal
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }

            ConfettiBurst(isActive: burst)
                .allowsHitTesting(false)
        }
        .task {
            await runSequence()
        }
    }

    private var crystal: some View {
        VStack(spacing: 18) {
            CrystalShape()
                .fill(CapsuleColors.gradient)
                .frame(width: 120, height: 158)
                .overlay(CrystalShape().stroke(Color.white.opacity(0.8), lineWidth: 2))
                .overlay(CrystalFacets().stroke(Color.white.opacity(0.4), lineWidth: 1).frame(width: 120, height: 158))
                .overlay {
                    Image(systemName: stage >= 1 ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .shadow(color: CapsuleColors.amber.opacity(0.8), radius: 30)
                .rotationEffect(.degrees(shake ? 6 : -6))
                .scaleEffect(stage >= 1 ? 1.15 : 1)
            Text("capsule.celebration.found")
                .font(Theme.rounded(.title2, weight: .heavy))
                .foregroundStyle(Color.white)
        }
    }

    private var reveal: some View {
        VStack(spacing: 16) {
            Text("capsule.celebration.title \(capsule.author.firstName)")
                .font(Theme.rounded(.title3, weight: .heavy))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxWidth: 300)
                .overlay {
                    if let source = appState.capsuleImage(for: capsule),
                       let image = ImageCache.image(forKey: source.key, data: source.data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Theme.surface
                            ProgressView()
                                .tint(Color.white)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(CapsuleColors.gradient, lineWidth: 2)
                }
                .shadow(color: CapsuleColors.violet.opacity(0.5), radius: 26)
            if let message = appState.capsuleSecret(for: capsule), !message.isEmpty {
                Text(verbatim: message)
                    .font(Theme.text(.body, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .frame(maxWidth: 320)
                    .glassCard(cornerRadius: Theme.Radius.control)
            }
            Button {
                close()
            } label: {
                Text("capsule.celebration.close")
            }
            .buttonStyle(PrimaryGradientButtonStyle(fullWidth: false))
        }
        .padding(24)
    }

    private func runSequence() async {
        withAnimation(.easeInOut(duration: 0.09).repeatCount(8, autoreverses: true)) {
            shake = true
        }
        try? await Task.sleep(for: .milliseconds(800))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) {
            stage = 1
            shake = false
        }
        try? await Task.sleep(for: .milliseconds(450))
        HapticManager.shared.success()
        withAnimation(.easeOut(duration: 0.6)) {
            burst = true
        }
        withAnimation(Theme.spring) {
            stage = 2
        }
    }

    private func close() {
        HapticManager.shared.tap()
        withAnimation(Theme.spring) {
            appState.celebratingCapsule = nil
        }
    }
}

/// Amber and violet sparks flying out from the center.
struct ConfettiBurst: View {
    let isActive: Bool

    private struct Spark: Identifiable {
        let id: Int
        let angle: Double
        let distance: CGFloat
        let size: CGFloat
        let color: Color
    }

    private let sparks: [Spark] = (0..<36).map { index in
        let colors: [Color] = [Color(hex: 0xF59E0B), Color(hex: 0xA855F7), Color(hex: 0x10B981), Color.white]
        return Spark(
            id: index,
            angle: Double(index) / 36 * 360 + Double(index % 3) * 7,
            distance: CGFloat(140 + (index * 37) % 160),
            size: CGFloat(5 + (index * 13) % 7),
            color: colors[index % colors.count]
        )
    }

    var body: some View {
        ZStack {
            ForEach(sparks) { spark in
                Circle()
                    .fill(spark.color)
                    .frame(width: spark.size, height: spark.size)
                    .offset(
                        x: isActive ? cos(spark.angle * Double.pi / 180) * spark.distance : 0,
                        y: isActive ? sin(spark.angle * Double.pi / 180) * spark.distance : 0
                    )
                    .opacity(isActive ? 0 : 1)
                    .animation(.easeOut(duration: 1.4), value: isActive)
            }
        }
        .opacity(isActive ? 1 : 0)
    }
}
