import AdagioStreamCore
import SwiftUI

struct SavedSongsView: View {
    @EnvironmentObject var savedSongsManager: SavedSongsManager
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            Group {
                if savedSongsManager.songs.isEmpty {
                    EmptyStateView(
                        title: "No Loved Songs",
                        systemImage: "heart",
                        description: "Tap the heart in Now Playing to save songs."
                    )
                } else {
                    List {
                        ForEach(savedSongsManager.songs) { song in
                            SavedSongRowView(song: song)
                        }
                        .onMove { savedSongsManager.moveSong(from: $0, to: $1) }
                        .onDelete { savedSongsManager.removeSongs(at: $0) }
                    }
                }
            }
            .navigationTitle("Loved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
            .environment(\.editMode, $editMode)
        }
    }
}
