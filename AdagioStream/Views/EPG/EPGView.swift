import SwiftUI

struct EPGView: View {
    let channelID: String
    @EnvironmentObject var providerManager: ProviderManager

    var body: some View {
        LoadableContent(
            state: loadState,
            loadingText: "Loading program guide…",
            emptyTitle: "No EPG Data",
            emptySystemImage: "calendar",
            emptyDescription: "No program guide data available for this channel.",
            errorTitle: "Couldn't Load Program Guide",
            retry: { Task { await providerManager.loadChannels() } }
        ) {
            List {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.title)
                                .font(.headline)
                            Spacer()
                            if entry.isCurrentlyAiring {
                                Text("LIVE")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.red, in: Capsule())
                            } else if !entry.isUpcoming {
                                // uxd.5: past entries were signaled by opacity
                                // alone — invisible to VoiceOver and to anyone
                                // who can't distinguish the dimmed shade.
                                Text("Ended")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.15), in: Capsule())
                            }
                        }

                        Text("\(entry.start.shortTimeString) - \(entry.end.shortTimeString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let description = entry.description {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                    .opacity(entry.isUpcoming || entry.isCurrentlyAiring ? 1.0 : 0.6)
                }
            }
        }
        .navigationTitle("Program Guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var entries: [EPGEntry] {
        (providerManager.epgData[channelID] ?? []).sorted { $0.start < $1.start }
    }

    /// EPG data is fetched inline as part of `ProviderManager.loadChannels()`
    /// (the same XMLTV/M3U-EPG parse that populates `epgData`), so its
    /// `isLoading`/`error` are the parent channel-load state (uxc.5) — this
    /// view has no dedicated EPG fetch of its own to track loading/error for.
    /// Distinguishes "still loading" and "failed" from "genuinely no guide
    /// data for this channel", which the bare `entries.isEmpty` check before
    /// this fix couldn't tell apart.
    private var loadState: LoadState {
        if providerManager.isLoading { return .loading }
        if let error = providerManager.error { return .error(error) }
        return entries.isEmpty ? .empty : .loaded
    }
}
