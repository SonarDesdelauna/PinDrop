import SwiftUI
import UIKit

/// A freshly captured live photo, waiting to be dropped.
struct CapturedShot: Identifiable {
    let id = UUID()
    let previewImage: UIImage
    let processed: ProcessedImage
    /// The GPS fix taken at the instant of the shot. `nil` when location access is denied.
    let location: GeoPoint?
    let capturedAt: Date
}

/// Post-capture preview: short caption (max 40 characters) and the Drop button.
struct PostCaptureSheet: View {
    static let captionLimit = 40

    let shot: CapturedShot
    let onRetake: () -> Void
    let onDropped: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(LocationService.self) private var locationService

    @State private var caption = ""
    @State private var placeName: String?
    @State private var isResolvingPlace = true
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @FocusState private var isCaptionFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                photo
                captionField
                privacyNote
                if shot.location == nil {
                    locationWarning
                }
                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(Theme.text(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.obsidian.ignoresSafeArea())
        .task {
            await resolvePlace()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 4) {
            Text("post.title")
                .font(Theme.text(.title2, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("post.subtitle")
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var photo: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                Image(uiImage: shot.previewImage)
                    .resizable()
                    .scaledToFill()
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.photo, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.photo, style: .continuous)
                    .strokeBorder(Theme.glassBorderGradient, lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                placePill
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text("camera.sixHours")
                }
                .font(Theme.rounded(.caption, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassCapsule()
                .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                if !caption.isEmpty {
                    Text(verbatim: caption)
                        .font(Theme.text(.headline, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .shadow(color: Color.black.opacity(0.6), radius: 6)
                        .padding(16)
                        .transition(.opacity)
                }
            }
            .shadow(color: Theme.electricViolet.opacity(0.25), radius: 24, x: 0, y: 12)
            .animation(Theme.spring, value: caption.isEmpty)
    }

    @ViewBuilder
    private var placePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(Theme.emerald)
            if isResolvingPlace {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color.white)
            } else if let placeName {
                Text(verbatim: placeName)
                    .lineLimit(1)
            } else if shot.location != nil {
                Text("post.place.unknown")
            } else {
                Text("post.place.missing")
            }
        }
        .font(Theme.text(.caption, weight: .semibold))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCapsule()
    }

    private var captionField: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(Theme.neonPurple)
            TextField("post.caption.placeholder", text: $caption)
                .font(Theme.text(.body))
                .foregroundStyle(Theme.textPrimary)
                .focused($isCaptionFocused)
                .submitLabel(.done)
                .textInputAutocapitalization(.sentences)
                .onSubmit { isCaptionFocused = false }
            Text(verbatim: "\(caption.count)/\(Self.captionLimit)")
                .font(Theme.rounded(.caption, weight: .bold))
                .foregroundStyle(caption.count >= Self.captionLimit ? Theme.warning : Theme.textSecondary)
                .monospacedDigit()
        }
        .padding(14)
        .glassCard(cornerRadius: Theme.Radius.control)
        .onChange(of: caption) { _, newValue in
            if newValue.count > Self.captionLimit {
                caption = String(newValue.prefix(Self.captionLimit))
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(Theme.emerald)
            Text("post.privacy")
                .font(Theme.text(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var locationWarning: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "location.slash.fill")
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("post.location.title")
                        .font(Theme.text(.subheadline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("post.location.body")
                        .font(Theme.text(.footnote))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                SystemSettings.openAppSettings()
            } label: {
                Text("common.openSettings")
            }
            .buttonStyle(GlassButtonStyle())
        }
        .padding(14)
        .glassCard(cornerRadius: Theme.Radius.control)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                drop()
            } label: {
                HStack(spacing: 8) {
                    if isPublishing {
                        ProgressView()
                            .tint(Color.white)
                        Text("post.dropping")
                    } else {
                        Image(systemName: "mappin.and.ellipse")
                        Text("post.drop")
                    }
                }
            }
            .buttonStyle(PrimaryGradientButtonStyle())
            .disabled(shot.location == nil || isPublishing)

            Button {
                HapticManager.shared.tap()
                onRetake()
            } label: {
                Text("post.retake")
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(isPublishing)
        }
    }

    // MARK: - Logic

    private func resolvePlace() async {
        guard let location = shot.location else {
            isResolvingPlace = false
            return
        }
        placeName = await locationService.placeName(for: location)
        isResolvingPlace = false
    }

    private func drop() {
        guard let location = shot.location, !isPublishing else { return }
        isCaptionFocused = false
        isPublishing = true
        errorMessage = nil
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await appState.publish(
                    processed: shot.processed,
                    location: location,
                    placeName: placeName,
                    caption: trimmedCaption,
                    capturedAt: shot.capturedAt
                )
                isPublishing = false
                onDropped()
            } catch {
                HapticManager.shared.error()
                errorMessage = error.localizedDescription
                isPublishing = false
            }
        }
    }
}
