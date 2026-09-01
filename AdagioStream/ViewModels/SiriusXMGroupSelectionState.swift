import Foundation

struct SiriusXMGroupSelectionState {
    static let settingsRowTitle = "SiriusXM Channel Groups"
    static let navigationTitle = "SiriusXM Groups"

    struct Row: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let channelCount: Int?
        let isSelected: Bool
        let isUnavailable: Bool

        var selectionLabel: String {
            isSelected ? "Selected" : "Not Selected"
        }
    }

    let inventory: [String: Int]
    let selectedNames: Set<String>
    var inventoryIsComplete = true
    var searchText = ""

    var availableRows: [Row] {
        inventory.map { name, count in
            Row(
                name: name,
                channelCount: count,
                isSelected: selectedNames.contains(name),
                isUnavailable: false
            )
        }
        .filter(matchesSearch)
        .sorted(by: rowComesBefore)
    }

    var unavailableRows: [Row] {
        unavailableNames.map { name in
            Row(name: name, channelCount: nil, isSelected: true, isUnavailable: true)
        }
        .filter(matchesSearch)
        .sorted(by: rowComesBefore)
    }

    var summary: String {
        let selectedCount = selectedNames.count
        guard selectedCount > 0 else { return "None" }
        let base = selectedCount == 1 ? "1 Selected" : "\(selectedCount) Selected"
        let unavailableCount = unavailableNames.count
        guard unavailableCount > 0 else { return base }
        return "\(base) (\(unavailableCount) Unavailable)"
    }

    var hasUnfilteredRows: Bool {
        !inventory.isEmpty || !unavailableNames.isEmpty
    }

    func selection(toggling name: String) -> Set<String> {
        var selection = selectedNames
        if !selection.insert(name).inserted {
            selection.remove(name)
        }
        return selection
    }

    private func matchesSearch(_ row: Row) -> Bool {
        searchText.isEmpty || row.name.localizedCaseInsensitiveContains(searchText)
    }

    private var unavailableNames: Set<String> {
        guard inventoryIsComplete else { return [] }
        return selectedNames.subtracting(inventory.keys)
    }

    private func rowComesBefore(_ lhs: Row, _ rhs: Row) -> Bool {
        let caseInsensitiveOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if caseInsensitiveOrder == .orderedSame {
            return lhs.name < rhs.name
        }
        return caseInsensitiveOrder == .orderedAscending
    }
}
