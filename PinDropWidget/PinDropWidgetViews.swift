import SwiftUI
import UIKit
import WidgetKit

/// Routes to the view matching the widget family.
struct PinDropWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PinDropEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumPinDropWidgetView(entry: entry)
        case .accessoryCircular:
            CircularPinDropWidgetView(entry: entry)
        default:
            SmallPinDropWidgetView(entry: entry)
        }
    }
}

// MARK: - Small

struct SmallPinDropWidgetView: View {
    let entry: PinDropEntry

    var body: some View {
        let lead = entry.activeEntries.first
        let isLocked = !entry.isUnlocked

        ZStack(alignment: .bottomLeading) {
            if let lead {
                WidgetPhoto(entry: lead, isLocked: isLocked)
            } else {
                WidgetEmptyBackground()
            }

            Theme.photoScrim

            VStack(alignment: .leading, spacing: 4) {
                LiveCountPill(count: entry.liveFriendsCount)
                Spacer(minLength: 0)
                if let lead {
                    if isLocked {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                            Text("widget.locked")
                        }
                        .font(Theme.roundedFixed(12, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    }
                    Text(verbatim: lead.firstName)
                        .font(Theme.roundedFixed(16, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let distance = lead.distanceMeters {
                            Text(verbatim: LocaleFormatter.distance(meters: distance))
                            Text(verbatim: "·")
                        }
                        Text(lead.expiresAt, style: .relative)
                    }
                    .font(Theme.roundedFixed(11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                } else {
                    Text("widget.empty.title")
                        .font(Theme.roundedFixed(15, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text("widget.empty.subtitle")
                        .font(Theme.roundedFixed(11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
            }
            .padding(14)
        }
        .widgetURL(lead?.deepLink ?? URL(string: "pindrop://map"))
        .containerBackground(for: .widget) {
            Theme.obsidian
        }
    }
}

// MARK: - Medium

struct MediumPinDropWidgetView: View {
    let entry: PinDropEntry

    var body: some View {
        let entries = entry.activeEntries
        let isLocked = !entry.isUnlocked

        HStack(spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                if let lead = entries.first {
                    WidgetPhoto(entry: lead, isLocked: isLocked)
                    Theme.photoScrim
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: lead.firstName)
                            .font(Theme.roundedFixed(14, weight: .heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if let place = lead.placeName, !isLocked {
                            Text(verbatim: place)
                                .font(Theme.roundedFixed(10, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(10)
                } else {
                    WidgetEmptyBackground()
                }
            }
            .frame(width: 128)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.glassBorderGradient, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(Theme.accentGradient)
                    Text(verbatim: "PinDrop")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 4)
                    LiveCountPill(count: entry.liveFriendsCount)
                }
                .font(Theme.roundedFixed(14, weight: .heavy))

                if entries.isEmpty {
                    Spacer(minLength: 0)
                    Text("widget.empty.title")
                        .font(Theme.roundedFixed(14, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("widget.empty.subtitle")
                        .font(Theme.roundedFixed(11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                } else {
                    ForEach(entries.prefix(3)) { pinEntry in
                        if let url = pinEntry.deepLink {
                            Link(destination: url) {
                                WidgetPinRow(entry: pinEntry, date: entry.date, isLocked: isLocked)
                            }
                        } else {
                            WidgetPinRow(entry: pinEntry, date: entry.date, isLocked: isLocked)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if isLocked, !entries.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                        Text("widget.locked")
                    }
                    .font(Theme.roundedFixed(10, weight: .bold))
                    .foregroundStyle(Theme.neonPurple)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(12)
        .widgetURL(entries.first?.deepLink ?? URL(string: "pindrop://map"))
        .containerBackground(for: .widget) {
            ZStack {
                Theme.obsidian
                RadialGradient(
                    colors: [Theme.electricViolet.opacity(0.35), Theme.obsidian.opacity(0)],
                    center: .topTrailing,
                    startRadius: 4,
                    endRadius: 220
                )
            }
        }
    }
}

// MARK: - Lock Screen (accessoryCircular)

struct CircularPinDropWidgetView: View {
    let entry: PinDropEntry

    var body: some View {
        let fraction = entry.payload.ownRemainingFraction(at: entry.date)
        ZStack {
            AccessoryWidgetBackground()
            Circle()
                .stroke(Color.primary.opacity(0.25), lineWidth: 4)
                .padding(3)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
                .widgetAccentable()
            VStack(spacing: 0) {
                Image(systemName: entry.isUnlocked ? "mappin.and.ellipse" : "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(entry.liveFriendsCount, format: .number)
                    .font(Theme.roundedFixed(18, weight: .heavy))
                    .minimumScaleFactor(0.6)
            }
        }
        .widgetURL(entry.activeEntries.first?.deepLink ?? URL(string: "pindrop://map"))
        .containerBackground(for: .widget) {
            Color.clear
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("widget.liveCount \(entry.liveFriendsCount)"))
    }
}

// MARK: - Components

/// Pin photo for widgets; frosted when the map is locked.
struct WidgetPhoto: View {
    let entry: WidgetPayload.PinEntry
    let isLocked: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let data = entry.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: isLocked ? 18 : 0, opaque: true)
                } else {
                    LinearGradient(
                        colors: [Color(hexString: entry.avatarColorHex), Theme.obsidian],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(verbatim: entry.initials)
                        .font(Theme.roundedFixed(34, weight: .heavy))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .blur(radius: isLocked ? 6 : 0)
                }
                if isLocked {
                    Color.black.opacity(0.25)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct WidgetEmptyBackground: View {
    var body: some View {
        ZStack {
            Theme.obsidian
            RadialGradient(
                colors: [Theme.electricViolet.opacity(0.55), Theme.obsidian.opacity(0)],
                center: .topLeading,
                startRadius: 4,
                endRadius: 200
            )
            Image(systemName: "camera.aperture")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Theme.accentGradient)
                .opacity(0.6)
                .offset(x: 30, y: -24)
        }
    }
}

struct LiveCountPill: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(count > 0 ? Theme.emerald : Theme.textSecondary)
                .frame(width: 6, height: 6)
            Text("widget.liveShort \(count)")
                .lineLimit(1)
        }
        .font(Theme.roundedFixed(10, weight: .bold))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
    }
}

struct WidgetPinRow: View {
    let entry: WidgetPayload.PinEntry
    let date: Date
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.001, entry.remainingFraction(at: date)))
                    .stroke(Theme.ringGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Group {
                    if let data = entry.thumbnail, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: isLocked ? 6 : 0, opaque: true)
                    } else {
                        ZStack {
                            Color(hexString: entry.avatarColorHex)
                            Text(verbatim: entry.initials)
                                .font(Theme.roundedFixed(10, weight: .bold))
                                .foregroundStyle(Color.white)
                        }
                    }
                }
                .frame(width: 24, height: 24)
                .clipShape(Circle())
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.firstName)
                    .font(Theme.roundedFixed(12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if let distance = entry.distanceMeters {
                        Text(verbatim: LocaleFormatter.distance(meters: distance))
                        Text(verbatim: "·")
                    }
                    Text(entry.createdAt, style: .relative)
                }
                .font(Theme.roundedFixed(10, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
