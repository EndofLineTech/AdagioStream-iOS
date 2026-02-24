import SwiftUI

struct RetryableAsyncImage: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    @State private var retryID = 0

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .failure:
                placeholder
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .background(Circle().fill(.black.opacity(0.5)))
                            .padding(4)
                    }
                    .onTapGesture { retryID += 1 }
            default:
                placeholder
            }
        }
        .id(retryID)
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        Image(systemName: "radio")
            .foregroundStyle(.secondary)
    }
}
