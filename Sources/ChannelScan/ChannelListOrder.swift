import Foundation

/// User-defined ordering of the scanned channel list.
///
/// The order is stored as a list of entry IDs. IDs not in it (e.g. found by a later scan) keep
/// their natural (scan) order after the known ones; IDs no longer present are ignored.
public enum ChannelListOrder {
    /// `items` sorted by `order`, unknown ones last in their original order.
    public static func sorted<T>(_ items: [T], order: [String], id: (T) -> String) -> [T] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated()
            .sorted { (rank[id($0.element)] ?? Int.max, $0.offset) < (rank[id($1.element)] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// Move rows of a displayed sub-list (`displayed`: e.g. one tuning space with hidden entries
    /// left out) and return the new full order. Entries not in `displayed` keep their positions.
    /// `source`/`destination` follow SwiftUI's `onMove` (destination is an insertion index).
    public static func move(_ displayed: [String], from source: IndexSet, to destination: Int, in full: [String]) -> [String] {
        var moved = displayed
        let picked = source.sorted().filter { $0 < moved.count }.map { moved[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) where i < moved.count { moved.remove(at: i) }
        moved.insert(contentsOf: picked, at: min(max(0, destination - before), moved.count))

        var result = full
        let shown = Set(displayed)
        let slots = result.indices.filter { shown.contains(result[$0]) }
        for (slot, id) in zip(slots, moved) { result[slot] = id }
        return result
    }
}
