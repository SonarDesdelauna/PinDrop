import SwiftUI
import UIKit

/// "Recap della serata": statistics of your evening and a 9:16 story card to share on
/// Instagram, TikTok or WhatsApp with one tap.
struct NightRecapSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var renderedImage: UIImage?
    @State private var shareURL: URL?
    @State private var isRendering = false

    private var summary: TrailSummary {
        appState.recapSummary
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if summary.isEmpty {
                        emptyState
                    } else {
                        statsGrid
                        preview
                        shareButton
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(Text("recap.title"))
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
        }
        .preferredColorScheme(.light)
        .task {
            await render()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.accentGradient)
            Text("recap.empty.title")
                .font(Theme.text(.title3, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("recap.empty.body")
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                dismiss()
                appState.presentCamera()
            } label: {
                Label("recap.empty.cta", systemImage: "camera.fill")
            }
            .buttonStyle(PrimaryGradientButtonStyle(fullWidth: false))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    private var statsGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                stat(icon: "point.topleft.down.to.point.bottomright.curvepath.fill", value: Text(verbatim: summary.distanceText), label: "recap.stat.distance")
                stat(icon: "mappin.and.ellipse", value: Text(summary.spotCount, format: .number), label: "recap.stat.spots")
            }
            HStack(spacing: 10) {
                stat(icon: "person.2.fill", value: Text(summary.friendsMet.count, format: .number), label: "recap.stat.friends")
                stat(
                    icon: "clock.fill",
                    value: Text("recap.timeRange \(Text(summary.startedAt, style: .time)) \(Text(summary.endedAt, style: .time))"),
                    label: "recap.stat.time"
                )
            }
        }
    }

    private func stat(icon: String, value: Text, label: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.neonPurple)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.neonPurple.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                value
                    .font(Theme.rounded(.headline, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(label)
                    .font(Theme.text(.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: Theme.Radius.control)
    }

    private var preview: some View {
        ZStack {
            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.surface)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(Color.white)
                            Text("recap.rendering")
                                .font(Theme.text(.footnote))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
            }
        }
        .frame(maxWidth: 300)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.electricViolet.opacity(0.35), radius: 24, x: 0, y: 12)
        .animation(Theme.spring, value: renderedImage != nil)
    }

    @ViewBuilder
    private var shareButton: some View {
        if let shareURL, let renderedImage {
            ShareLink(
                item: shareURL,
                preview: SharePreview(String(localized: "recap.share.preview"), image: Image(uiImage: renderedImage))
            ) {
                Label("recap.share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryGradientButtonStyle())
            .simultaneousGesture(TapGesture().onEnded { HapticManager.shared.tap() })
            Text("recap.share.hint")
                .font(Theme.text(.caption))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        } else {
            Button {} label: {
                Label("recap.share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryGradientButtonStyle())
            .disabled(true)
        }
    }

    private func render() async {
        guard !summary.isEmpty, !isRendering else { return }
        isRendering = true
        defer { isRendering = false }
        var photos: [UIImage] = []
        for pin in summary.pins.reversed().prefix(4) {
            await appState.loadFullImage(for: pin)
            if let source = appState.fullImage(for: pin), let image = UIImage(data: source.data) {
                photos.append(image)
            }
        }
        guard let image = await RecapCardRenderer.render(summary: summary, userName: appState.currentUser.firstName, photos: photos) else { return }
        renderedImage = image
        shareURL = RecapCardRenderer.writePNG(image)
    }
}
