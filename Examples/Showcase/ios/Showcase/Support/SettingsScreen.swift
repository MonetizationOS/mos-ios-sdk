import SwiftUI

/// Mode, key, host and endpoint namespace, kept across launches. Saving a new mode, key or host
/// rebuilds the MOS instance.
struct SettingsScreen: View {
    @Environment(Showcase.self) private var showcase
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ShowcaseSettings.defaults
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $draft.mode) {
                        Text("Fixture").tag(ShowcaseSettings.Mode.fixture)
                        Text("Live").tag(ShowcaseSettings.Mode.live)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.mode")
                } footer: {
                    Text(draft.mode == .fixture
                        ? "Fixture mode answers every request from the bundled fixtures. No key, no network."
                        : "Live mode talks to your org. See the README for what the org needs.")
                }
                Section("Live org") {
                    TextField("Public key (pk_…)", text: $draft.publicKey)
                        .accessibilityIdentifier("settings.publicKey")
                    TextField("API base URL", text: $draft.apiBaseUrl)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("settings.apiBaseUrl")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Section("App endpoints") {
                    TextField("Namespace", text: $draft.namespace)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.namespace")
                }
                Section {
                    Button("Reset identity", role: .destructive) {
                        Task {
                            await showcase.resetIdentity()
                            note = "A new anonymous reader. The cache and the queue are empty."
                        }
                    }
                    .accessibilityIdentifier("settings.resetIdentity")
                } footer: {
                    if let note { Text(note).accessibilityIdentifier("settings.note") }
                }
                if let error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("settings.error")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            error = await showcase.apply(draft)
                            if error == nil { dismiss() }
                        }
                    }
                    .accessibilityIdentifier("settings.save")
                }
            }
            .onAppear { draft = showcase.settings }
        }
    }
}
