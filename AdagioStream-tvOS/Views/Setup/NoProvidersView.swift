import SwiftUI

struct NoProvidersView: View {
    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)

            Text("No Providers Configured")
                .font(.title)

            VStack(spacing: 8) {
                Text("Add providers on your iPhone or iPad.")
                Text("They'll sync to this Apple TV via iCloud Keychain.")
            }
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(80)
    }
}
