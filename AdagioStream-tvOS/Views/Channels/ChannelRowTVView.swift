import SwiftUI

struct ChannelRowTVView: View {
    let channel: Channel
    let isCurrent: Bool
    let isPlaying: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 20) {
                logo
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.title3)
                        .foregroundStyle(.primary)
                    Text(channel.group)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .foregroundStyle(.tint)
                        .font(.title2)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var logo: some View {
        if let url = channel.logoURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "radio")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "radio")
                .font(.system(size: 36))
                .frame(width: 64, height: 64)
                .foregroundStyle(.secondary)
        }
    }
}
