import SwiftUI

struct LicensesView: View {
    var body: some View {
        List {
            Section("Dependencies") {
                NavigationLink {
                    LicenseDetailView(
                        name: "VLCKit",
                        description: "A multimedia framework based on the VLC media player, providing audio and video playback capabilities.",
                        repoURL: URL(string: "https://code.videolan.org/videolan/VLCKit")!,
                        licenseFilename: "LGPL-2.1"
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VLCKit")
                        Text("LGPL 2.1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicenseDetailView: View {
    let name: String
    let description: String
    let repoURL: URL
    let licenseFilename: String

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: licenseFilename, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text not found."
        }
        return text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Link(destination: repoURL) {
                    Label("Source Repository", systemImage: "arrow.up.right.square")
                        .font(.subheadline)
                }

                Divider()

                Text(licenseText)
                    .font(.caption)
                    .monospaced()
            }
            .padding()
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
