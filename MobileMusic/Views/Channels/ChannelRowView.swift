import SwiftUI

struct ChannelRowView: View {
    let channel: Channel
    let onTap: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Channel logo
            if let logoURL = channel.logoURL {
                AsyncImage(url: logoURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    Image(systemName: "radio")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "radio")
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.secondary)
            }

            // Channel name
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(channel.group)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Favorite button
            Button {
                onToggleFavorite()
            } label: {
                Image(systemName: channel.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(channel.isFavorite ? .yellow : .secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
