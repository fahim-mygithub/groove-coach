import SwiftUI

/// Courses > gear: the Debug Link (on by default). The PC is found automatically; a typed address overrides that.
struct DebugLinkSettingsView: View {
    @AppStorage(DebugLinkSettings.enabledKey) private var enabled = DebugLinkSettings.enabledByDefault
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
                    TextField("automatic (or 192.168.4.47:8765)", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("Shares the screen (about 1 frame/s), the app log, events and crash reports with `tools/debuglink/start.ps1` on your computer, plus calibration readings and tuning. The computer is found automatically on the same Wi-Fi; leave the address empty unless that fails. Plain http, no password.")
                }

                Section("Connection") {
                    LabeledContent("Server", value: link.serverDescription)
                        .font(.footnote)
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
                    .disabled(testing || !enabled)

                    Button("Find the computer again") {
                        testResult = nil
                        link.findAgain()
                    }
                    .disabled(!enabled || !host.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let testResult {
                        Text(testResult).font(.footnote)
                    }
                }

                Section("Status") {
                    LabeledContent("Connected", value: enabled && link.connected ? "yes" : "no")
                    LabeledContent("Screen", value: link.currentScreen)
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
