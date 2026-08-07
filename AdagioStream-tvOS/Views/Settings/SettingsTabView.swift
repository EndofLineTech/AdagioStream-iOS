import SwiftUI

struct SettingsTabView: View {
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    bufferDurationRow
                }
                Section("Diagnostics") {
                    Toggle("Debug Logging", isOn: debugLoggingBinding)
                }
                Section("About") {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var bufferDurationRow: some View {
        Picker("Buffer", selection: bufferBinding) {
            ForEach(1...15, id: \.self) { seconds in
                Text("\(seconds) s").tag(seconds)
            }
        }
    }

    private var bufferBinding: Binding<Int> {
        Binding(
            get: { Int(settingsViewModel.settings.bufferDuration) },
            set: { newValue in
                Task { await settingsViewModel.updateBufferDuration(Double(newValue)) }
            }
        )
    }

    private var debugLoggingBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.settings.debugLoggingEnabled },
            set: { newValue in
                Task { await settingsViewModel.updateDebugLogging(newValue) }
            }
        )
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
