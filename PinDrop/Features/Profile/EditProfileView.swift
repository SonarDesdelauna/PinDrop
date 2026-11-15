import PhotosUI
import SwiftUI

/// Fully customizable profile: photo, color, display name, username, bio and status emoji.
/// Used both for first-time setup after sign-up and for later edits.
struct EditProfileView: View {
    enum Mode {
        case setup
        case edit
    }

    static let displayNameLimit = 40
    static let bioLimit = 160

    let mode: Mode

    @Environment(AppState.self) private var appState
    @Environment(AuthService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    @State private var draft: UserProfile = .placeholder
    @State private var didLoadDraft = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var newAvatarData: Data?
    @State private var newAvatarImage: UIImage?
    @State private var removeAvatar = false
    @State private var usernameState: UsernameState = .unchanged
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case displayName
        case username
        case bio
    }

    private enum UsernameState: Equatable {
        case unchanged
        case invalid
        case checking
        case available
        case taken
    }

    private var trimmedDisplayName: String {
        draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var previewProfile: UserProfile {
        var preview = draft
        if removeAvatar {
            preview.avatarPath = nil
        }
        return preview
    }

    private var canSave: Bool {
        !isSaving
            && !trimmedDisplayName.isEmpty
            && (usernameState == .unchanged || usernameState == .available)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if mode == .setup {
                        setupHeader
                    }
                    avatarSection
                    colorSection
                    fieldsSection
                    statusSection
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.text(.footnote, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }
                    saveButton
                    if mode == .setup {
                        Button {
                            Task { await authService.signOut() }
                        } label: {
                            Text("auth.signOut")
                                .font(Theme.text(.footnote, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.obsidian.ignoresSafeArea())
            .navigationTitle(mode == .setup ? Text("profile.setup.title") : Text("profile.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if mode == .edit {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Text("common.cancel")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            guard !didLoadDraft else { return }
            didLoadDraft = true
            draft = appState.currentUser
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadAvatar(from: item) }
        }
        .task(id: draft.username) {
            await validateUsername()
        }
        .animation(Theme.spring, value: errorMessage)
        .animation(Theme.spring, value: usernameState)
    }

    // MARK: - Sections

    private var setupHeader: some View {
        VStack(spacing: 8) {
            Text("profile.setup.headline")
                .font(Theme.text(.title2, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
            Text("profile.setup.body")
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
        }
        .multilineTextAlignment(.center)
    }

    private var avatarSection: some View {
        VStack(spacing: 12) {
            ZStack {
                if let newAvatarImage {
                    Image(uiImage: newAvatarImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 112, height: 112)
                        .clipShape(Circle())
                } else {
                    AvatarBadge(user: previewProfile, size: 112)
                }
            }
            .padding(4)
            .overlay {
                Circle().strokeBorder(Theme.accentGradient, lineWidth: 3)
            }
            .shadow(color: Color(hexString: draft.avatarColorHex).opacity(0.5), radius: 18)

            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Label("profile.photo.choose", systemImage: "photo.on.rectangle")
                        .font(Theme.text(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassCapsule()
                }
                if newAvatarData != nil || (draft.avatarPath != nil && !removeAvatar) {
                    Button {
                        HapticManager.shared.selection()
                        withAnimation(Theme.spring) {
                            newAvatarData = nil
                            newAvatarImage = nil
                            pickerItem = nil
                            removeAvatar = true
                        }
                    } label: {
                        Label("profile.photo.remove", systemImage: "trash")
                            .font(Theme.text(.footnote, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .glassCapsule()
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("profile.color")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(UserProfile.avatarPalette, id: \.self) { hex in
                    let isSelected = draft.avatarColorHex.uppercased() == hex.uppercased()
                    Button {
                        HapticManager.shared.selection()
                        withAnimation(Theme.spring) {
                            draft.avatarColorHex = hex
                        }
                    } label: {
                        Circle()
                            .fill(Color(hexString: hex))
                            .frame(height: 38)
                            .overlay {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .heavy))
                                        .foregroundStyle(Color.white)
                                }
                            }
                            .overlay {
                                Circle().strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0.15), lineWidth: isSelected ? 2.5 : 1)
                            }
                            .scaleEffect(isSelected ? 1.08 : 1)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(Text(verbatim: hex))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(14)
            .glassCard()
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("profile.displayName")
                TextField("profile.displayName.placeholder", text: $draft.displayName)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .displayName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .username }
                    .fieldStyle()
                    .onChange(of: draft.displayName) { _, value in
                        if value.count > Self.displayNameLimit {
                            draft.displayName = String(value.prefix(Self.displayNameLimit))
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("profile.username")
                HStack(spacing: 4) {
                    Text(verbatim: "@")
                        .foregroundStyle(Theme.textSecondary)
                    TextField("profile.username.placeholder", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .bio }
                        .onChange(of: draft.username) { _, value in
                            let sanitized = UserProfile.sanitizeUsername(value)
                            if sanitized != value {
                                draft.username = sanitized
                            }
                        }
                    usernameIndicator
                }
                .fieldStyle()
                usernameHint
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionTitle("profile.bio")
                    Spacer()
                    Text(verbatim: "\(draft.bio.count)/\(Self.bioLimit)")
                        .font(Theme.rounded(.caption2, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                TextField("profile.bio.placeholder", text: $draft.bio, axis: .vertical)
                    .lineLimit(3...5)
                    .focused($focusedField, equals: .bio)
                    .fieldStyle()
                    .onChange(of: draft.bio) { _, value in
                        if value.count > Self.bioLimit {
                            draft.bio = String(value.prefix(Self.bioLimit))
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var usernameIndicator: some View {
        switch usernameState {
        case .unchanged:
            EmptyView()
        case .checking:
            ProgressView()
                .controlSize(.small)
                .tint(Theme.textSecondary)
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.emerald)
        case .invalid, .taken:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Theme.danger)
        }
    }

    @ViewBuilder
    private var usernameHint: some View {
        switch usernameState {
        case .invalid:
            Text("profile.username.invalid")
                .font(Theme.text(.caption))
                .foregroundStyle(Theme.danger)
        case .taken:
            Text("profile.username.taken")
                .font(Theme.text(.caption))
                .foregroundStyle(Theme.danger)
        case .available:
            Text("profile.username.available")
                .font(Theme.text(.caption))
                .foregroundStyle(Theme.emerald)
        case .unchanged, .checking:
            Text("profile.username.rules")
                .font(Theme.text(.caption))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("profile.status")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(UserProfile.statusEmojiPalette, id: \.self) { emoji in
                    let isSelected = draft.statusEmoji == emoji
                    Button {
                        HapticManager.shared.selection()
                        withAnimation(Theme.spring) {
                            draft.statusEmoji = emoji
                        }
                    } label: {
                        ZStack {
                            if emoji.isEmpty {
                                Image(systemName: "nosign")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            } else {
                                Text(verbatim: emoji)
                                    .font(.system(size: 24))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isSelected ? Theme.electricViolet.opacity(0.35) : Color.white.opacity(0.05))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(isSelected ? Theme.neonPurple : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                        }
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(emoji.isEmpty ? Text("profile.status.none") : Text(verbatim: emoji))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(14)
            .glassCard()
        }
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView()
                        .tint(Color.white)
                }
                Text(mode == .setup ? "profile.setup.continue" : "profile.save")
            }
        }
        .buttonStyle(PrimaryGradientButtonStyle())
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.55)
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(Theme.text(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }

    // MARK: - Actions

    private func validateUsername() async {
        let username = draft.username
        if username == appState.currentUser.username {
            usernameState = .unchanged
            return
        }
        guard UserProfile.isValidUsername(username) else {
            usernameState = .invalid
            return
        }
        usernameState = .checking
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        let available = await appState.isUsernameAvailable(username)
        guard !Task.isCancelled, username == draft.username else { return }
        switch available {
        case .some(true): usernameState = .available
        case .some(false): usernameState = .taken
        case .none: usernameState = .available
        }
    }

    private func loadAvatar(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = String(localized: "profile.photo.error")
            return
        }
        let processed = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let decoded = ImageCompressor.downsample(data, maxPixelSize: 1_024) else { return nil }
            let square = ImageCompressor.cropAndResize(decoded, aspect: 1, longEdge: 512)
            return square.jpegData(compressionQuality: 0.82)
        }.value
        guard let processed, let image = UIImage(data: processed) else {
            errorMessage = String(localized: "profile.photo.error")
            return
        }
        withAnimation(Theme.spring) {
            newAvatarData = processed
            newAvatarImage = image
            removeAvatar = false
            errorMessage = nil
        }
    }

    private func save() {
        guard canSave else { return }
        focusedField = nil
        isSaving = true
        errorMessage = nil
        var profile = draft
        profile.displayName = trimmedDisplayName
        profile.bio = draft.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await appState.saveProfile(profile, newAvatar: newAvatarData, removeAvatar: removeAvatar)
                isSaving = false
                if mode == .edit {
                    dismiss()
                }
            } catch {
                isSaving = false
                HapticManager.shared.error()
                if let dataError = error as? DataServiceError, dataError == .usernameTaken {
                    usernameState = .taken
                }
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension View {
    func fieldStyle() -> some View {
        self
            .font(Theme.text(.body, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(14)
            .glassCard(cornerRadius: Theme.Radius.control)
    }
}
