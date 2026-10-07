import SwiftUI

private struct ServerGroup: Identifiable {
    let title: String
    let kinds: [ServerKind]
    var id: String { title }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var store: ServerStore
    @State private var editing: ServerProfile?

    private let groups = [
        ServerGroup(title: "Downloaders", kinds: [.sabnzbd, .nzbget]),
        ServerGroup(title: "Sonarr", kinds: [.sonarr]),
        ServerGroup(title: "Radarr", kinds: [.radarr]),
        ServerGroup(title: "NZB Indexers", kinds: [.indexer])
    ]

    var body: some View {
        NavigationStack {
            List {
                if store.profiles.isEmpty {
                    Section {
                        Text("Add your servers to get started. Tap + and pick SABnzbd, NZBGet, Sonarr, Radarr, or an NZB indexer.")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(groups) { group in
                    let members = store.profiles.filter { group.kinds.contains($0.kind) }
                    if !members.isEmpty {
                        Section(group.title) {
                            ForEach(members) { profile in
                                Button {
                                    editing = profile
                                } label: {
                                    ServerRow(profile: profile)
                                }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        store.delete(profile)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }

                if store.downloaders.count > 1 {
                    Section("Send downloads to") {
                        Picker("Active downloader", selection: $store.activeDownloaderID) {
                            ForEach(store.downloaders) { downloader in
                                Text(downloader.name).tag(Optional(downloader.id))
                            }
                        }
                    }
                }

                Section {
                    Text("Parcel is an independent app. It isn't affiliated with Sonarr, Radarr, SABnzbd or NZBGet. API keys and passwords are kept in the iOS Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(ServerKind.allCases) { kind in
                            Button {
                                editing = ServerProfile(kind: kind, name: kind.title, baseURL: "")
                            } label: {
                                Label(kind.title, systemImage: kind.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add server")
                }
            }
            .sheet(item: $editing) { profile in
                ServerEditView(
                    profile: profile,
                    secret: store.secret(for: profile),
                    isNew: !store.profiles.contains(where: { $0.id == profile.id })
                )
            }
        }
    }
}

private struct ServerRow: View {
    let profile: ServerProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.kind.systemImage)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.body)
                Text(profile.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

@MainActor
private struct ServerEditView: View {
    let isNew: Bool

    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ServerProfile
    @State private var secret: String
    @State private var testResult: String?
    @State private var testFailed = false
    @State private var testing = false

    init(profile: ServerProfile, secret: String, isNew: Bool) {
        _profile = State(initialValue: profile)
        _secret = State(initialValue: secret)
        self.isNew = isNew
    }

    private var trimmedURL: String {
        profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    if isNew {
                        Picker("Type", selection: $profile.kind) {
                            ForEach(ServerKind.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    TextField("Name", text: $profile.name)
                    TextField(profile.kind.urlPlaceholder, text: $profile.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if profile.kind.usesUsername {
                        TextField("Username", text: $profile.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    SecureField(profile.kind.secretLabel, text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle("Allow self-signed certificate", isOn: $profile.allowSelfSignedCertificate)
                } footer: {
                    Text("Turn this on only for servers on your own network that use a self-signed HTTPS certificate.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            if testing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(testing || trimmedURL.isEmpty)

                    if let testResult {
                        Label(testResult, systemImage: testFailed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .foregroundStyle(testFailed ? Color.red : Color.green)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(isNew ? "Add Server" : profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedURL.isEmpty)
                }
            }
            .onChange(of: profile.kind) { _, newKind in
                let isDefaultName = profile.name.isEmpty || ServerKind.allCases.contains { $0.title == profile.name }
                if isDefaultName { profile.name = newKind.title }
            }
        }
    }

    private func cleanedProfile() -> ServerProfile {
        var cleaned = profile
        cleaned.baseURL = trimmedURL
        cleaned.name = profile.name.trimmingCharacters(in: .whitespaces).isEmpty ? profile.kind.title : profile.name
        cleaned.username = profile.username.trimmingCharacters(in: .whitespaces)
        return cleaned
    }

    private func save() {
        store.save(cleanedProfile(), secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }

    private func test() async {
        testing = true
        testResult = nil
        do {
            let message = try await ServiceFactory.test(
                cleanedProfile(),
                secret: secret.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            testResult = message
            testFailed = false
        } catch {
            testResult = error.localizedDescription
            testFailed = true
        }
        testing = false
    }
}
