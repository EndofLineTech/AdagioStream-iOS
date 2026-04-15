import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        List {
            Section {
                Text("Adagio Stream does not collect, store, or transmit any personal data to us. The app does not include analytics, advertising, crash reporting, or tracking of any kind.")
            } header: {
                Text("Overview")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    dataItem(
                        title: "Provider Credentials",
                        detail: "Server URLs, usernames, and passwords you enter for Xtream Codes or M3U providers are stored securely in the iOS Keychain on your device."
                    )
                    dataItem(
                        title: "Favorites and Playlists",
                        detail: "Your favorited channels, saved songs, custom playlists, and favorite groups are stored locally."
                    )
                    dataItem(
                        title: "Preferences",
                        detail: "App settings including appearance, sort order, buffer duration, text size, and last played channel."
                    )
                    dataItem(
                        title: "Cached Images",
                        detail: "Channel logos and artwork are cached on your device to improve performance."
                    )
                    dataItem(
                        title: "Debug Logs",
                        detail: "When enabled by you in Settings, the app writes diagnostic logs to your device. These logs automatically redact credentials. Logs may contain channel names and server hostnames. Debug logging is off by default and logs are never transmitted unless you explicitly share them."
                    )
                }
                .padding(.vertical, 4)
            } header: {
                Text("Data Stored on Your Device")
            } footer: {
                Text("All data is stored locally on your device and is never transmitted to us. We have no access to it.")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    dataItem(
                        title: "Streaming Providers",
                        detail: "The app connects to streaming servers that you configure. Your credentials are sent directly to these servers to authenticate. We do not operate, control, or have access to these servers."
                    )
                    dataItem(
                        title: "ESPN.com API",
                        detail: "Used to retrieve live sports scores for matched sports channels. Only public scoreboard endpoints are queried. No user data is sent."
                    )
                    dataItem(
                        title: "xmplaylist.com API",
                        detail: "Used to retrieve track metadata (song titles, artist names, artwork) for SiriusXM channels. Only channel identifiers are sent. No user data is included."
                    )
                }
                .padding(.vertical, 4)
            } header: {
                Text("External Services")
            } footer: {
                Text("All third-party API requests include only a generic app user-agent header. No cookies, device identifiers, or personal information are transmitted.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No analytics or telemetry SDKs are included.")
                    Text("No advertising SDKs are included.")
                    Text("No device identifiers are collected or transmitted.")
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            } header: {
                Text("Tracking and Analytics")
            }

            Section {
                Text("We do not collect, sell, share, or transfer any personal data to third parties.")
                    .font(.subheadline)
            } header: {
                Text("Data Sharing")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    dataItem(
                        title: "Access",
                        detail: "All your data is stored locally. You can view your accounts, favorites, playlists, and settings directly in the app."
                    )
                    dataItem(
                        title: "Data Portability",
                        detail: "You can export all your data from Settings."
                    )
                    dataItem(
                        title: "Erasure",
                        detail: "You can delete all app data from Settings, or by uninstalling the app."
                    )
                    dataItem(
                        title: "Rectification",
                        detail: "You can edit or update your provider accounts, favorites, and preferences at any time."
                    )
                }
                .padding(.vertical, 4)
            } header: {
                Text("Your Data Rights")
            }

            Section {
                Text("All data is stored on your device only. There is no cloud sync, no server-side storage, and no backups of sensitive data. Data persists until you delete it or uninstall the app.")
                    .font(.subheadline)
            } header: {
                Text("Data Retention")
            }

            Section {
                Text("Adagio Stream does not knowingly collect any personal information from children.")
                    .font(.subheadline)
            } header: {
                Text("Children's Privacy")
            }

            Section {
                Link(destination: URL(string: "mailto:curt@lecaptain.org")!) {
                    Label("curt@lecaptain.org", systemImage: "envelope")
                }
            } header: {
                Text("Contact")
            } footer: {
                Text("Last updated April 15, 2026")
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func dataItem(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
