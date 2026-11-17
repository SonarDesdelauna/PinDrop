import MapKit
import SwiftUI

// MARK: - Colors

enum RelayStyle {
    static let orange = Color(hex: 0xFF7A1A)
    static let pink = Color(hex: 0xFF2E93)
    static var gradient: LinearGradient { LinearGradient(colors: [orange, pink], startPoint: .leading, endPoint: .trailing) }
    static var softGradient: LinearGradient { LinearGradient(colors: [orange.opacity(0.24), pink.opacity(0.24)], startPoint: .topLeading, endPoint: .bottomTrailing) }

    static func lineColors(for status: Relay.Status) -> [Color] {
        switch status {
        case .active: [orange, pink]
        case .finished: [Theme.emerald, Theme.emeraldLight]
        case .broken: [Color.gray.opacity(0.75), Color.gray.opacity(0.5)]
        }
    }

    /// "5 h 12 min" left to run the leg.
    static func remaining(until deadline: Date?, now: Date = .now) -> String {
        guard let deadline else { return "" }
        let seconds = max(0, deadline.timeIntervalSince(now))
        let rounded = (seconds / 60).rounded(.up) * 60
        if rounded < 3_600 {
            return Duration.seconds(rounded).formatted(.units(allowed: [.minutes], width: .abbreviated))
        }
        return Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

// MARK: - Map marker

/// One leg on the map: the runner's avatar with the leg number. The last leg of a running
/// relay carries the baton.
struct RelayLegMarker: View {
    let relay: Relay
    let leg: RelayLeg

    @State private var isPulsing = false

    private var isTip: Bool {
        relay.status == .active && leg.id == relay.lastLeg?.id
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AvatarBadge(user: leg.runner.profile, size: isTip ? 34 : 28)
                .padding(2.5)
                .background(Circle().fill(LinearGradient(colors: RelayStyle.lineColors(for: relay.status), startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay {
                    if isTip {
                        Circle()
                            .stroke(RelayStyle.orange.opacity(0.6), lineWidth: 3)
                            .scaleEffect(isPulsing ? 1.55 : 1)
                            .opacity(isPulsing ? 0 : 1)
                    }
                }
            Text(verbatim: isTip ? "🏃" : "\(leg.seq)")
                .font(Theme.roundedFixed(isTip ? 12 : 10, weight: .heavy))
                .foregroundStyle(Color.white)
                .frame(minWidth: 17, minHeight: 17)
                .padding(.horizontal, isTip ? 2 : 0)
                .background(Circle().fill(isTip ? AnyShapeStyle(RelayStyle.gradient) : AnyShapeStyle(Theme.ink.opacity(0.85))))
                .offset(x: 6, y: -6)
        }
        .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)
        .onAppear {
            guard isTip else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("relay.a11y.leg \(leg.seq) \(leg.runner.displayName) \(relay.title)"))
        .accessibilityAddTraits(.isButton)
    }
}

/// The line of a relay, drawn under its markers.
struct RelayLine: MapContent {
    let relay: Relay

    var body: some MapContent {
        let coordinates = relay.legs.map(\.coordinate)
        let colors = RelayStyle.lineColors(for: relay.status)
        MapPolyline(coordinates: coordinates)
            .stroke(colors[0].opacity(relay.status == .broken ? 0.12 : 0.28), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
        MapPolyline(coordinates: coordinates)
            .stroke(
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round, dash: relay.status == .broken ? [6, 7] : [])
            )
    }
}

// MARK: - Baton banner

/// "You have the baton!": shown on the map while it is your turn to run.
struct RelayBatonBanner: View {
    let relay: Relay
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Text(verbatim: "🏃")
                    .font(.system(size: 24))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(RelayStyle.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("relay.banner.title")
                        .font(Theme.text(.subheadline, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("relay.banner.body \(relay.emoji) \(relay.title) \(RelayStyle.remaining(until: relay.deadline, now: context.date))")
                            .font(Theme.text(.caption, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(10)
            .padding(.trailing, 6)
            .glassCard(cornerRadius: 22)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(RelayStyle.gradient, lineWidth: 1.5)
            }
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
    }
}

// MARK: - Relay sheet

/// A relay: where it has been, who has the baton, how long is left, or who dropped it.
struct RelaySheet: View {
    let relay: Relay

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var me: UUID { appState.currentUser.id }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    statusCard
                    if relay.isHeld(by: me) {
                        Button {
                            HapticManager.shared.tap()
                            appState.runLeg(of: relay)
                        } label: {
                            Label("relay.run", systemImage: "figure.run")
                        }
                        .buttonStyle(PrimaryGradientButtonStyle())
                    }
                    legsList
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .navigationDestination(for: UserProfile.self) { user in
                ProfileView(user: user)
            }
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
        }
        .preferredColorScheme(.light)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(verbatim: relay.emoji)
                .font(.system(size: 44))
                .frame(width: 84, height: 84)
                .background(Circle().fill(LinearGradient(colors: RelayStyle.lineColors(for: relay.status).map { $0.opacity(0.22) }, startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text(verbatim: relay.title)
                .font(Theme.rounded(.title2, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                pill(icon: "flag.checkered", text: Text("relay.legs \(relay.legs.count)"))
                pill(icon: "point.topleft.down.to.point.bottomright.curvepath.fill", text: Text(verbatim: LocaleFormatter.distance(meters: relay.distance)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard()
    }

    private func pill(icon: String, text: Text) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(RelayStyle.orange)
            text
        }
        .font(Theme.rounded(.footnote, weight: .bold))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassCapsule()
    }

    @ViewBuilder
    private var statusCard: some View {
        HStack(spacing: 12) {
            switch relay.status {
            case .active:
                if let holder = relay.holder {
                    AvatarBadge(user: holder.profile, size: 46)
                        .overlay(alignment: .bottomTrailing) {
                            Text(verbatim: "🏃").font(.system(size: 16)).offset(x: 4, y: 4)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Group {
                            if holder.id == me {
                                Text("relay.status.yourTurn")
                            } else {
                                Text("relay.status.turnOf \(holder.firstName)")
                            }
                        }
                        .font(Theme.text(.headline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text("relay.status.left \(RelayStyle.remaining(until: relay.deadline, now: context.date))")
                                .font(Theme.text(.subheadline, weight: .semibold))
                                .foregroundStyle(RelayStyle.orange)
                        }
                    }
                }
            case .broken:
                Text(verbatim: "💥")
                    .font(.system(size: 30))
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("relay.status.broken")
                        .font(Theme.text(.headline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if let culprit = relay.brokenBy {
                        Group {
                            if culprit.id == me {
                                Text("relay.status.brokenByYou")
                            } else {
                                Text("relay.status.brokenBy \(culprit.displayName)")
                            }
                        }
                        .font(Theme.text(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                    }
                }
            case .finished:
                Text(verbatim: "🏁")
                    .font(.system(size: 30))
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("relay.status.finished")
                        .font(Theme.text(.headline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if let last = relay.lastLeg {
                        Text("relay.status.finishedBy \(last.runner.displayName)")
                            .font(Theme.text(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.emerald)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard()
    }

    private var legsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("relay.timeline")
                .font(Theme.text(.headline, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            ForEach(relay.legs.reversed()) { leg in
                RelayLegRow(leg: leg, isLast: leg.id == relay.lastLeg?.id && relay.status == .active)
                    .onTapGesture {
                        HapticManager.shared.selection()
                        dismiss()
                        appState.focusMap(on: leg.location, spanMeters: 700)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A leg in the relay timeline: photo, runner, place and time.
private struct RelayLegRow: View {
    let leg: RelayLeg
    let isLast: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.ink.opacity(0.06))
                if let image = appState.social.image(for: leg.thumbKey) ?? appState.social.image(for: leg.imageKey) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .frame(width: 60, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text(verbatim: "\(leg.seq)")
                    .font(Theme.roundedFixed(11, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(isLast ? AnyShapeStyle(RelayStyle.gradient) : AnyShapeStyle(Theme.ink.opacity(0.8))))
                    .offset(x: -5, y: -5)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    AvatarBadge(user: leg.runner.profile, size: 20)
                    Text(verbatim: leg.runner.displayName)
                        .font(Theme.text(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                if let place = leg.placeName, !place.isEmpty {
                    Label {
                        Text(verbatim: place)
                    } icon: {
                        Image(systemName: "mappin")
                    }
                    .font(Theme.text(.caption, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                }
                if !leg.caption.isEmpty {
                    Text(verbatim: "“\(leg.caption)”")
                        .font(Theme.text(.caption))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                }
                Text(verbatim: LocaleFormatter.relativeTimestamp(leg.createdAt, relativeTo: .now))
                    .font(Theme.text(.caption2))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .glassCard()
        .onAppear {
            appState.social.loadImage(leg.thumbKey)
        }
    }
}
