import SwiftUI

struct CustomPlaylistEntryRowView: View {
    let entry: CustomPlaylistEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let logoURL = entry.logoURL {
                    RetryableAsyncImage(url: logoURL, width: 40, height: 40, cornerRadius: 8)
                } else {
                    Image(systemName: "radio")
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    // uxd.4: the raw stream URL was read verbatim by VoiceOver
                    // (e.g. "h t t p s colon slash slash..."); it's visual-only
                    // context, not part of the row's accessible name.
                    Text(entry.streamURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.name)
        .accessibilityHint("Double tap to play")
    }
}
