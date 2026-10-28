import SwiftUI

struct ContentView: View {
    @State private var showSettings = false
    @State private var loadFailed = false
    @State private var reloadToken = 0

    var body: some View {
        ZStack {
            InstagramWebView(loadFailed: $loadFailed, reloadToken: reloadToken)
                .ignoresSafeArea()
                .id("instagram-webview")

            if loadFailed {
                VStack(spacing: 12) {
                    Text("Couldn't load Instagram")
                        .font(.headline)
                    Button("Retry") {
                        loadFailed = false
                        reloadToken += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Retry loading Instagram")
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }

            VStack {
                HStack {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Settings")
                    .padding()
                    Spacer()
                }
                Spacer()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("rulesURL") private var rulesURL = "https://raw.githubusercontent.com/Spharax/konvo-dms-clone/main/rules.json"
    @AppStorage("enableScreenTime") private var enableScreenTime = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Remote Rules")) {
                    TextField("Rules JSON URL", text: $rulesURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit {
                            NotificationCenter.default.post(name: InstagramWebView.Coordinator.rulesDidChangeNotification, object: nil)
                        }
                    Text("Must be an https URL.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Screen Time (Optional)")) {
                    Toggle("Block Official Instagram App", isOn: $enableScreenTime)
                        .disabled(true) // not wired to ScreenTimeManager yet
                    Text("Not implemented yet. Would use FamilyControls / ManagedSettings, which needs a special entitlement and Apple approval.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button("Done") {
                        NotificationCenter.default.post(name: InstagramWebView.Coordinator.rulesDidChangeNotification, object: nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
