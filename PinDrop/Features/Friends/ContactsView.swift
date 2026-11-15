import Contacts
import CryptoKit
import MessageUI
import SwiftUI

/// Links used when inviting people.
enum AppLinks {
    /// App Store page of PinDrop. Replace with the real link once the app is published.
    static let appStoreURL = URL(string: "https://apps.apple.com/app/pindrop")!
}

/// Hashing used to match contacts without uploading them in clear text.
enum ContactHasher {
    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func emailHash(_ email: String) -> String? {
        let cleaned = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.contains("@") else { return nil }
        return sha256(cleaned)
    }

    /// Digits only, last 10 digits (ignores country prefixes), so `+39 333 1234567` and
    /// `3331234567` match.
    static func normalizedPhone(_ phone: String) -> String? {
        let digits = phone.filter(\.isASCII).filter(\.isNumber)
        guard digits.count >= 6 else { return nil }
        return String(digits.suffix(10))
    }

    static func phoneHash(_ phone: String) -> String? {
        normalizedPhone(phone).map(sha256)
    }
}

/// A contact from the address book, reduced to what the screen needs.
struct AddressBookContact: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let phones: [String]
    let emails: [String]

    var hashes: [String] {
        phones.compactMap(ContactHasher.phoneHash) + emails.compactMap(ContactHasher.emailHash)
    }

    var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// "Find friends from contacts": who already uses PinDrop (Add) and who to invite (SMS).
struct ContactsView: View {
    private enum LoadState: Equatable {
        case idle
        case loading
        case denied
        case loaded
        case failed
    }

    private struct SMSDraft: Identifiable {
        let id = UUID()
        let recipient: String
        let body: String
    }

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var loadState: LoadState = .idle
    @State private var contacts: [AddressBookContact] = []
    /// Contact id → PinDrop profile.
    @State private var matches: [String: UserProfile] = [:]
    @State private var requested: Set<UUID> = []
    @State private var search = ""
    @State private var smsDraft: SMSDraft?
    @State private var phoneNumber = ""
    @State private var hasPhone = false
    @State private var isSavingPhone = false

    private var filtered: [AddressBookContact] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return contacts }
        return contacts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var onApp: [AddressBookContact] {
        filtered.filter { matches[$0.id] != nil }
    }

    private var toInvite: [AddressBookContact] {
        filtered.filter { matches[$0.id] == nil && (!$0.phones.isEmpty || !$0.emails.isEmpty) }
    }

    private var inviteMessage: String {
        String(localized: "contacts.invite.message \(appState.currentUser.inviteCode) \(AppLinks.appStoreURL.absoluteString)")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                phoneCard
                switch loadState {
                case .idle, .loading:
                    ProgressView()
                        .tint(Theme.textPrimary)
                        .padding(30)
                case .denied:
                    deniedCard
                case .failed:
                    messageCard(systemImage: "exclamationmark.triangle.fill", text: Text("contacts.error"))
                case .loaded:
                    if contacts.isEmpty {
                        messageCard(systemImage: "person.crop.circle.badge.questionmark", text: Text("contacts.empty"))
                    } else {
                        section(title: Text("contacts.onApp \(onApp.count)"), items: onApp)
                        section(title: Text("contacts.invite.section"), items: toInvite)
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $search, prompt: Text("contacts.search"))
        .navigationTitle(Text("contacts.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            hasPhone = await appState.dataService.hasPhoneHash()
            if loadState == .idle {
                await load()
            }
        }
        .sheet(item: $smsDraft) { draft in
            MessageComposer(recipients: [draft.recipient], body: draft.body) {
                smsDraft = nil
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Sections

    private var phoneCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "phone.fill")
                    .foregroundStyle(Theme.emerald)
                Text("contacts.phone.title")
                    .font(Theme.text(.subheadline, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            if hasPhone {
                HStack {
                    Label("contacts.phone.saved", systemImage: "checkmark.circle.fill")
                        .font(Theme.text(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.emerald)
                    Spacer(minLength: 8)
                    Button {
                        Task {
                            try? await appState.dataService.setPhoneHash(nil)
                            hasPhone = false
                        }
                    } label: {
                        Text("contacts.phone.remove")
                    }
                    .buttonStyle(SmallPillButtonStyle(isProminent: false))
                }
            } else {
                HStack(spacing: 8) {
                    TextField("contacts.phone.placeholder", text: $phoneNumber)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .font(Theme.text(.body, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(12)
                        .glassCard(cornerRadius: Theme.Radius.control)
                    Button {
                        savePhone()
                    } label: {
                        if isSavingPhone {
                            ProgressView().tint(Color.white)
                        } else {
                            Text("contacts.phone.save")
                        }
                    }
                    .buttonStyle(SmallPillButtonStyle(isProminent: true))
                    .disabled(ContactHasher.normalizedPhone(phoneNumber) == nil || isSavingPhone)
                }
            }
            Text("contacts.phone.hint")
                .font(Theme.text(.caption2))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .glassCard()
    }

    private var deniedCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
            Text("contacts.denied")
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Text("contacts.openSettings")
            }
            .buttonStyle(PrimaryGradientButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard()
    }

    private func messageCard(systemImage: String, text: Text) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            text
                .font(Theme.text(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassCard()
    }

    @ViewBuilder
    private func section(title: Text, items: [AddressBookContact]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                title
                    .font(Theme.text(.headline, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 4)
                LazyVStack(spacing: 0) {
                    ForEach(items) { contact in
                        row(contact)
                        if contact.id != items.last?.id {
                            Divider()
                                .overlay(Color.white.opacity(0.06))
                                .padding(.leading, 66)
                        }
                    }
                }
                .glassCard()
            }
        }
    }

    private func row(_ contact: AddressBookContact) -> some View {
        let profile = matches[contact.id]
        return HStack(spacing: 12) {
            if let profile {
                AvatarBadge(user: profile, size: 42)
            } else {
                Text(verbatim: contact.initials)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: contact.name)
                    .font(Theme.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(verbatim: profile?.handle ?? contact.phones.first ?? contact.emails.first ?? "")
                    .font(Theme.rounded(.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let profile {
                friendAction(profile)
            } else {
                inviteAction(contact)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func friendAction(_ profile: UserProfile) -> some View {
        let snapshot = appState.friendsSnapshot
        if snapshot.friendshipIDs[profile.id] != nil {
            Label("contacts.friends", systemImage: "checkmark")
                .font(Theme.text(.caption, weight: .bold))
                .foregroundStyle(Theme.emerald)
                .labelStyle(.titleAndIcon)
        } else if requested.contains(profile.id) || snapshot.outgoing.contains(where: { $0.addresseeID == profile.id }) {
            Text("contacts.requested")
                .font(Theme.text(.caption, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
        } else if let request = snapshot.incoming.first(where: { $0.requesterID == profile.id }) {
            Button {
                Task { await appState.respond(to: request, accept: true) }
            } label: {
                Text("friends.requests.accept")
            }
            .buttonStyle(SmallPillButtonStyle(isProminent: true))
        } else {
            Button {
                HapticManager.shared.tap()
                requested.insert(profile.id)
                Task {
                    let result = await appState.sendFriendRequest(to: profile.username)
                    if result?.isSuccess != true {
                        requested.remove(profile.id)
                    }
                }
            } label: {
                Label("contacts.add", systemImage: "person.badge.plus")
            }
            .buttonStyle(SmallPillButtonStyle(isProminent: true))
        }
    }

    @ViewBuilder
    private func inviteAction(_ contact: AddressBookContact) -> some View {
        if let phone = contact.phones.first {
            Button {
                HapticManager.shared.tap()
                invite(phone: phone)
            } label: {
                Label("contacts.invite", systemImage: "message.fill")
            }
            .buttonStyle(SmallPillButtonStyle(isProminent: false))
        } else {
            ShareLink(item: inviteMessage) {
                Label("contacts.invite", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SmallPillButtonStyle(isProminent: false))
        }
    }

    // MARK: - Actions

    private func invite(phone: String) {
        if MFMessageComposeViewController.canSendText() {
            smsDraft = SMSDraft(recipient: phone, body: inviteMessage)
            return
        }
        let number = phone.filter { $0.isNumber || $0 == "+" }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?")
        let body = inviteMessage.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        if let url = URL(string: "sms:\(number)&body=\(body)") {
            openURL(url)
        }
    }

    private func savePhone() {
        guard let hash = ContactHasher.phoneHash(phoneNumber) else { return }
        isSavingPhone = true
        Task {
            do {
                try await appState.dataService.setPhoneHash(hash)
                hasPhone = true
                phoneNumber = ""
                HapticManager.shared.success()
            } catch {
                HapticManager.shared.error()
            }
            isSavingPhone = false
        }
    }

    private func load() async {
        loadState = .loading
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        let newStatus = CNContactStore.authorizationStatus(for: .contacts)
        guard newStatus == .authorized || newStatus == .limited else {
            loadState = .denied
            return
        }

        let fetched: [AddressBookContact]
        do {
            fetched = try await Task.detached(priority: .userInitiated) {
                try ContactsView.readContacts()
            }.value
        } catch {
            loadState = .failed
            return
        }
        contacts = fetched

        var hashToContacts: [String: [String]] = [:]
        var emailHashes: Set<String> = []
        var phoneHashes: Set<String> = []
        for contact in fetched {
            for phone in contact.phones {
                if let hash = ContactHasher.phoneHash(phone) {
                    phoneHashes.insert(hash)
                    hashToContacts[hash, default: []].append(contact.id)
                }
            }
            for email in contact.emails {
                if let hash = ContactHasher.emailHash(email) {
                    emailHashes.insert(hash)
                    hashToContacts[hash, default: []].append(contact.id)
                }
            }
        }

        do {
            let found = try await appState.dataService.matchContacts(emailHashes: Array(emailHashes), phoneHashes: Array(phoneHashes))
            let profiles = try await appState.dataService.fetchProfiles(Array(Set(found.map(\.profileID))))
            let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var result: [String: UserProfile] = [:]
            for match in found {
                guard let profile = byID[match.profileID] else { continue }
                for contactID in hashToContacts[match.matchedHash] ?? [] {
                    result[contactID] = profile
                }
            }
            withAnimation(Theme.spring) {
                matches = result
            }
        } catch {
            // Matching failed: still show everyone as "invite".
        }
        loadState = .loaded
    }

    nonisolated static func readContacts() throws -> [AddressBookContact] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var result: [AddressBookContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let name = CNContactFormatter.string(from: contact, style: .fullName)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let phones = contact.phoneNumbers.map(\.value.stringValue)
            let emails = contact.emailAddresses.map { String($0.value) }
            guard !name.isEmpty || !phones.isEmpty else { return }
            result.append(AddressBookContact(
                id: contact.identifier,
                name: name.isEmpty ? (phones.first ?? "") : name,
                phones: phones,
                emails: emails
            ))
        }
        return result
    }
}

/// System SMS composer, prefilled with the invite.
struct MessageComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish()
        }
    }
}
