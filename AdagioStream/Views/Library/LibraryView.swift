import SwiftUI

/// LibraryView — hosts Favorites and Loved (SavedSongs) under a single tab
/// using a segmented Picker.  Both underlying views are reused unchanged.
struct LibraryView: View {
    enum Segment: String, CaseIterable {
        case favorites = "Favorites"
        case loved = "Loved"
    }

    @State private var selectedSegment: Segment = .favorites

    var body: some View {
        // Each sub-view owns its own NavigationStack, so we don't wrap them
        // here.  The Picker sits above the content in a VStack overlay so the
        // sub-views' nav bars remain unobstructed.
        ZStack(alignment: .top) {
            switch selectedSegment {
            case .favorites:
                FavoritesView()
            case .loved:
                SavedSongsView()
            }

            // Segmented control injected into the visual space below the
            // navigation bar via safeAreaInset so it doesn't fight the nav bar.
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Library", selection: $selectedSegment) {
                ForEach(Segment.allCases, id: \.self) { segment in
                    Text(segment.rawValue).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityLabel("Library segment")
        }
    }
}
