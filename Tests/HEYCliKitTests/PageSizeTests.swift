import Foundation
import Testing

import HEYCliKit

/// The page size is checked at construction and never at a spawn, so nothing here
/// builds a client: an invalid size cannot become a command line in the first place.
@Suite("Page size")
struct PageSizeTests {
    @Test("HEY's own page sizes are accepted", arguments: [30, 40, 50, 60, 100, 1000])
    func acceptsBoundarySizes(count: Int) {
        #expect(PageSize(count)?.count == count)
    }

    @Test("Anything below 30 or off the ten boundary is rejected", arguments: [10, 20, 25, 35, 29, 0, -30])
    func rejectsEverythingElse(count: Int) {
        #expect(PageSize(count) == nil)
    }

    @Test("The minimum is the first page HEY serves")
    func minimumIsThirty() {
        #expect(PageSize.minimum.count == 30)
        #expect(PageSize.minimum == PageSize(30))
    }
}
