import SwiftUI
import UIKit

struct AdagioStartupView: View {

    @State private var textOpacity: Double = 0
    @State private var glowIntensity: Double = 0.0

    var body: some View {
        GeometryReader { proxy in
            if let uiImage = UIImage(named: "AdagioSplash") {
                ZStack {
                    // Base image
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)

                    // Glow layer — brightens only the light parts (notes)
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 10)
                        .blendMode(.screen)
                        .opacity(glowIntensity)

                    // Second glow layer for extra intensity
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 20)
                        .blendMode(.screen)
                        .opacity(glowIntensity * 0.6)
                }
                .scaleEffect(2.0)
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.65)
                .clipped()
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            Text("Adagio Stream")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.primary)
                .opacity(textOpacity)
                .padding(.bottom, 120)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.5)) {
                textOpacity = 1
            }
            withAnimation(
                .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: true)
            ) {
                glowIntensity = 0.4
            }
        }
    }
}
