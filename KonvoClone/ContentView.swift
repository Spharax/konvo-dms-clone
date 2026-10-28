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
        NavigationView {
            Form {
                Section(header: Text("Remote Rules")) {
                    TextField("Rules JSON URL", text: $rulesURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                
                Section(header: Text("Screen Time (Optional)")) {
                    Toggle("Block Official Instagram App", isOn: $enableScreenTime)
                    Text("Uses FamilyControls / ManagedSettings. Requires special entitlements and Apple approval for personal devices. Off by default.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    Button("Done") { dismiss() }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
