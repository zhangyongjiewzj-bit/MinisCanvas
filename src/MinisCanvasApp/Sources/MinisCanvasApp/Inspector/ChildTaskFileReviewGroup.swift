import Foundation

/// Groups only admitted projection rows. Never re-identifies a child by path,
/// and never collapses repeated edits to the same file or rewrites diff lines.
struct ChildTaskFileReviewGroup: Identifiable, Equatable {
    let childTaskID: String?
    var changes: [TurnFileChange]

    // Namespaced IDs keep a real child named "parent" distinct from the parent.
    var id: String { childTaskID.map { "child:\($0)" } ?? "parent" }
    var title: String { childTaskID.map { "子任务 \($0)" } ?? "主任务" }

    static func capture(_ changes: [TurnFileChange], turnID: Int?) -> [Self] {
        guard let turnID else { return [] }
        var groups: [Self] = []
        for change in changes where change.turnID == turnID {
            if let index = groups.firstIndex(where: { $0.childTaskID == change.childTaskID }) {
                groups[index].changes.append(change)
            } else {
                groups.append(Self(childTaskID: change.childTaskID, changes: [change]))
            }
        }
        return groups
    }
}
