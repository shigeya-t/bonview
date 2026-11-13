@testable import ChannelScan
import Foundation
import Testing

@Suite struct ChannelListOrderTests {
    @Test func sortsByOrderKeepingUnknownLast() {
        let items = ["a", "b", "c", "d"]
        #expect(ChannelListOrder.sorted(items, order: ["c", "a", "x"], id: { $0 }) == ["c", "a", "b", "d"])
        #expect(ChannelListOrder.sorted(items, order: [], id: { $0 }) == items)
    }

    // SwiftUI onMove semantics: destination is the insertion index before removal.
    @Test func moveDown() {
        #expect(ChannelListOrder.move(["a", "b", "c"], from: [0], to: 3, in: ["a", "b", "c"]) == ["b", "c", "a"])
        #expect(ChannelListOrder.move(["a", "b", "c"], from: [0], to: 2, in: ["a", "b", "c"]) == ["b", "a", "c"])
    }

    @Test func moveUp() {
        #expect(ChannelListOrder.move(["a", "b", "c"], from: [2], to: 0, in: ["a", "b", "c"]) == ["c", "a", "b"])
    }

    @Test func multipleRows() {
        #expect(ChannelListOrder.move(["a", "b", "c", "d"], from: [0, 2], to: 4, in: ["a", "b", "c", "d"]) == ["b", "d", "a", "c"])
    }

    @Test func hiddenAndOtherSpacesStayInPlace() {
        // Full order: BS entry "x" first, hidden "h" between visible UHF entries.
        let full = ["x", "a", "h", "b", "c"]
        // Displayed UHF list (hidden left out): a, b, c → move c to the top.
        #expect(ChannelListOrder.move(["a", "b", "c"], from: [2], to: 0, in: full) == ["x", "c", "h", "a", "b"])
    }
}
