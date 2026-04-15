import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var providerManager: ProviderManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        Label("Appearance", systemImage: "paintbrush")
                    }
                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        Label("Playback", systemImage: "play.circle")
                    }
                    NavigationLink {
                        ChannelsAccountsSettingsView()
                    } label: {
                        Label("Accounts & Channels", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                Section {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Label("Advanced", systemImage: "gearshape.2")
                    }
                }

                Section {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
