import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $viewModel.settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.settings.appearanceMode) { _, newValue in
                    Task { await viewModel.updateAppearance(newValue) }
                }
            } header: {
                Text("Theme")
            }

            Section {
                Picker("Text Size", selection: $viewModel.settings.textSizeMode) {
                    ForEach(TextSizeMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: viewModel.settings.textSizeMode) { _, newValue in
                    Task { await viewModel.updateTextSize(newValue) }
                }
                Text("Preview: The quick brown fox")
                    .font(.body)
            } header: {
                Text("Text Size")
            } footer: {
                Text("System follows your device's text size setting.")
            }

            Section {
                Picker("Artwork Display", selection: artworkDisplayBinding) {
                    ForEach(ArtworkDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Artwork")
            } footer: {
                Text("Choose whether to display track cover art or the channel logo in the player and CarPlay.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var artworkDisplayBinding: Binding<ArtworkDisplayMode> {
        Binding(
            get: { viewModel.settings.artworkDisplayMode },
            set: { newValue in
                Task { await viewModel.updateArtworkDisplayMode(newValue) }
            }
        )
    }
}
