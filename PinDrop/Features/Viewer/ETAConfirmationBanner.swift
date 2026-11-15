import SwiftUI

/// Interactive "On my way" banner: computes the walking time with `MKDirections` and sends an
/// IRL ping to the friend (e.g. "Luca is on the way • 6 min walk").
struct ETAConfirmationBanner: View {
    let pin: PhotoPin
    let onClose: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(LocationService.self) private var locationService
    @State private var phase: Phase = .calculating

    enum Phase: Equatable {
        case calculating
        case ready(TimeInterval)
        case sending(TimeInterval)
        case sent(TimeInterval)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.emeraldGradient)
                        .frame(width: 42, height: 42)
                    Image(systemName: "figure.walk")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("eta.title")
                        .font(Theme.text(.headline, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("eta.subtitle \(pin.author.firstName)")
                        .font(Theme.text(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    HapticManager.shared.tap()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(CircleGlassButtonStyle(diameter: 34))
                .accessibilityLabel(Text("common.close"))
            }

            phaseContent
        }
        .padding(16)
        .glassCard(cornerRadius: 26)
        .task {
            await calculate()
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .calculating:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(Theme.emerald)
                Text("eta.calculating")
                    .font(Theme.text(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .ready(let eta):
            readyContent(eta: eta, isSending: false)
        case .sending(let eta):
            readyContent(eta: eta, isSending: true)
        case .sent:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.emerald)
                Text("eta.sent \(pin.author.firstName)")
                    .font(Theme.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.scale.combined(with: .opacity))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: message)
                    .font(Theme.text(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        Task { await calculate() }
                    } label: {
                        Text("common.retry")
                    }
                    .buttonStyle(GlassButtonStyle())
                    if !locationService.isAuthorized {
                        Button {
                            SystemSettings.openAppSettings()
                        } label: {
                            Text("common.openSettings")
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                }
            }
        }
    }

    private func readyContent(eta: TimeInterval, isSending: Bool) -> some View {
        let duration = LocaleFormatter.walkingDuration(seconds: eta)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: duration)
                    .font(Theme.rounded(.largeTitle, weight: .heavy))
                    .foregroundStyle(Theme.emerald)
                    .contentTransition(.numericText())
                Text("eta.walkLabel")
                    .font(Theme.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .foregroundStyle(Theme.neonPurple)
                Text("eta.preview \(appState.currentUser.firstName) \(duration)")
                    .font(Theme.text(.footnote, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))

            Button {
                send(eta: eta)
            } label: {
                HStack(spacing: 8) {
                    if isSending {
                        ProgressView()
                            .tint(Color.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text("eta.send")
                }
            }
            .buttonStyle(PrimaryGradientButtonStyle())
            .disabled(isSending)
        }
    }

    private func calculate() async {
        phase = .calculating
        do {
            let eta = try await locationService.walkingETA(to: pin.location)
            withAnimation(Theme.spring) {
                phase = .ready(max(60, eta))
            }
        } catch {
            withAnimation(Theme.spring) {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func send(eta: TimeInterval) {
        phase = .sending(eta)
        Task {
            do {
                try await appState.sendOnMyWay(to: pin, etaSeconds: eta)
                withAnimation(Theme.spring) {
                    phase = .sent(eta)
                }
                try? await Task.sleep(for: .seconds(1.4))
                onClose()
            } catch {
                HapticManager.shared.error()
                withAnimation(Theme.spring) {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }
}
