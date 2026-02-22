import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @StateObject private var viewModel: SettingsViewModel

    init() {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(audioPlayer: AudioPlayerService.shared))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Buffer Duration")
                            Spacer()
                            Text("\(Int(viewModel.settings.bufferDuration))s")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $viewModel.settings.bufferDuration,
                            in: 2...60,
                            step: 1
                        ) {
                            Text("Buffer Duration")
                        }
                        .onChange(of: viewModel.settings.bufferDuration) { newValue in
                            Task { await viewModel.updateBufferDuration(newValue) }
                        }
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("App")
                        Spacer()
                        Text(Constants.appName)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
