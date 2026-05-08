import SwiftUI

struct EPGView: View {
    let channelID: String
    @EnvironmentObject var providerManager: ProviderManager

    var body: some View {
        List {
            if entries.isEmpty {
                EmptyStateView(
                    title: "No EPG Data",
                    systemImage: "calendar",
                    description: "No program guide data available for this channel."
                )
            } else {
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
}
