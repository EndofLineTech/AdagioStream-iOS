import SwiftUI

struct CustomPlaylistEntryRowView: View {
    let entry: CustomPlaylistEntry
    let onTap: () -> Void

    var body: some View {
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
                Text(entry.streamURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
