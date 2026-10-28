import SwiftUI

struct ContentView: View {
    @State private var showSettings = false

    var body: some View {
        ZStack {
            InstagramWebView()
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding()
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
