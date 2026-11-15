import SwiftUI
import UIKit

/// Two simultaneous points of view in one 3:4 card, split 50/50 by a glowing seam and signed
/// "Luca × Marco". Interactive cards can swap the two POVs and switch between side by side and
/// stacked.
struct SyncShotCardView: View {
    enum Layout {
        case sideBySide
        case stacked
    }

    let first: UIImage?
    let second: UIImage?
    let firstName: String
    let secondName: String
    var firstLocked = false
    var secondLocked = false
    var isInteractive = true
    var cornerRadius: CGFloat = Theme.Radius.card

    @State private var layout: Layout = .sideBySide
    @State private var isSwapped = false

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let leading = isSwapped ? (second, secondLocked) : (first, firstLocked)
                    let trailing = isSwapped ? (first, firstLocked) : (second, secondLocked)
                    ZStack {
                        if layout == .sideBySide {
                            HStack(spacing: 0) {
                                half(leading.0, locked: leading.1)
                                    .frame(width: proxy.size.width / 2, height: proxy.size.height)
                                half(trailing.0, locked: trailing.1)
                                    .frame(width: proxy.size.width / 2, height: proxy.size.height)
                            }
                            seam(vertical: true, length: proxy.size.height)
                        } else {
                            VStack(spacing: 0) {
                                half(leading.0, locked: leading.1)
                                    .frame(width: proxy.size.width, height: proxy.size.height / 2)
                                half(trailing.0, locked: trailing.1)
                                    .frame(width: proxy.size.width, height: proxy.size.height / 2)
                            }
                            seam(vertical: false, length: proxy.size.width)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Theme.electricViolet, Theme.emerald], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.5
                    )
            }
            .overlay(alignment: .bottom) {
                signature
                    .padding(.bottom, 14)
            }
            .overlay(alignment: .topTrailing) {
                if isInteractive {
                    controls
                        .padding(12)
                }
            }
            .animation(Theme.spring, value: layout)
            .animation(Theme.spring, value: isSwapped)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("sync.card.a11y \(firstName) \(secondName)"))
    }

    private func half(_ image: UIImage?, locked: Bool) -> some View {
        ZStack {
            Theme.surface
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: locked ? 16 : 0, opaque: true)
            } else {
                ProgressView()
                    .tint(Color.white)
            }
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.white)
                    .glow(Theme.neonPurple, radius: 14)
            }
        }
        .clipped()
    }

    private func seam(vertical: Bool, length: CGFloat) -> some View {
        let gradient = LinearGradient(
            colors: [Theme.electricViolet, Theme.emerald, Theme.neonPurple],
            startPoint: vertical ? .top : .leading,
            endPoint: vertical ? .bottom : .trailing
        )
        return ZStack {
            Rectangle()
                .fill(gradient)
                .frame(width: vertical ? 10 : length, height: vertical ? length : 10)
                .blur(radius: 8)
                .opacity(0.8)
            Rectangle()
                .fill(gradient)
                .frame(width: vertical ? 3 : length, height: vertical ? length : 3)
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(gradient))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                .shadow(color: Theme.emerald.opacity(0.6), radius: 10)
        }
        .allowsHitTesting(false)
    }

    private var signature: some View {
        HStack(spacing: 6) {
            Text(verbatim: isSwapped ? secondName : firstName)
            Text(verbatim: "×")
                .foregroundStyle(Theme.emeraldLight)
            Text(verbatim: isSwapped ? firstName : secondName)
        }
        .font(Theme.rounded(.subheadline, weight: .heavy))
        .foregroundStyle(Color.white)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassCapsule()
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Button {
                HapticManager.shared.selection()
                isSwapped.toggle()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(CircleGlassButtonStyle(diameter: 38))
            .accessibilityLabel(Text("sync.card.swap"))

            Button {
                HapticManager.shared.selection()
                layout = layout == .sideBySide ? .stacked : .sideBySide
            } label: {
                Image(systemName: layout == .sideBySide ? "rectangle.split.1x2" : "rectangle.split.2x1")
            }
            .buttonStyle(CircleGlassButtonStyle(diameter: 38))
            .accessibilityLabel(Text("sync.card.layout"))
        }
    }
}
