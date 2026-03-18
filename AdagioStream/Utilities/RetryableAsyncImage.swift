import SwiftUI
import UIKit

struct RetryableAsyncImage: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    /// When false, uses memory-only caching (for ephemeral images like album art).
    var persistent: Bool = true

    @State private var retryID = 0
    @State private var loadedImage: UIImage?
    @State private var backgroundColor: Color = .clear
    @State private var hasFailed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(backgroundColor)

            if let uiImage = loadedImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if hasFailed {
                placeholder
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .background(Circle().fill(.black.opacity(0.5)))
                            .padding(4)
                    }
                    .onTapGesture { retryID += 1 }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: retryID) {
            await loadImage()
        }
        .onChange(of: url) {
            retryID += 1
        }
    }

    private var placeholder: some View {
        Image(systemName: "radio")
            .foregroundStyle(.secondary)
    }

    private func loadImage() async {
        hasFailed = false

        let cache = ImageCacheService.shared
        guard let uiImage = await (persistent ? cache.image(for: url) : cache.ephemeralImage(for: url)) else {
            hasFailed = true
            return
        }
        let color = averageEdgeColor(of: uiImage)
        // Suppress implicit animation so the list doesn't jump
        // when images finish loading at different times
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            loadedImage = uiImage
            backgroundColor = color
        }
    }

    private func averageEdgeColor(of image: UIImage) -> Color {
        guard let cgImage = image.cgImage else { return .clear }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return .clear }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .clear }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sample pixels along the edges
        var totalR: Double = 0
        var totalG: Double = 0
        var totalB: Double = 0
        var count: Double = 0

        func sample(_ x: Int, _ y: Int) {
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)
            let a = Double(pixelData[offset + 3]) / 255.0
            guard a > 0.1 else { return } // skip transparent pixels
            totalR += Double(pixelData[offset]) / 255.0
            totalG += Double(pixelData[offset + 1]) / 255.0
            totalB += Double(pixelData[offset + 2]) / 255.0
            count += 1
        }

        let step = max(1, max(width, height) / 20)

        // Top and bottom edges
        for x in stride(from: 0, to: width, by: step) {
            sample(x, 0)
            sample(x, height - 1)
        }
        // Left and right edges
        for y in stride(from: 0, to: height, by: step) {
            sample(0, y)
            sample(width - 1, y)
        }

        guard count > 0 else { return .clear }

        let r = totalR / count
        let g = totalG / count
        let b = totalB / count

        return Color(red: r, green: g, blue: b)
    }
}
