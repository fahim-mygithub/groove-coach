import SwiftUI

/// Courses > gear: turn the calibration Debug Link on, set the PC address and test it.
struct DebugLinkSettingsView: View {
    @AppStorage(DebugLinkSettings.enabledKey) private var enabled = false
    @AppStorage(DebugLinkSettings.hostKey) private var host = ""
    @ObservedObject private var link = DebugLink.shared
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: String?
    @State private var testing = false

    init() {}

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Debug Link", isOn: $enabled)
                    TextField("192.168.4.47:8765", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("Sends calibration readings and small camera pictures to `tools/debuglink/server.py` on your computer, and re-reads its tuning.json every 2 s. Same Wi-Fi only; plain http, no password. Off by default.")
                }

                Section("Connection") {
                    Button {
                        testing = true
                        testResult = nil
                        Task {
                            testResult = await link.testConnection(host: host)
                            testing = false
                        }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing || host.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let testResult {
                        Text(testResult).font(.footnote)
                    }
                    if let url = DebugLinkSettings.baseURL(from: host) {
                        LabeledContent("Server", value: url.absoluteString)
                            .font(.footnote)
                    }
                }

                Section("Status") {
                    LabeledContent("Connected", value: enabled && link.connected ? "yes" : "no")
                    LabeledContent("Tuning", value: link.tuningHash.map { "tuning \($0)" } ?? "defaults")
                    Text(link.lastSent).font(.footnote).foregroundStyle(.secondary)
                    if let err = link.lastError {
                        Text(err).font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Debug Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: enabled) { _, _ in link.settingsChanged() }
            .onChange(of: host) { _, _ in link.settingsChanged() }
        }
    }
}
