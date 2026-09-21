import Foundation
import Testing

import HEYCliKit

@Suite("Non empty set")
struct NonEmptySetTests {
    @Test("The variadic init keeps the order it was written in and drops duplicates")
    func variadicInitKeepsOrderAndDropsDuplicates() {
        let set = NonEmptySet(3, 1, 3, 2, 1)

        #expect(set.elements == [3, 1, 2])
        #expect(set.count == 3)
        #expect(set.first == 3)
    }

    @Test("A sequence with members builds a set, an empty one builds nothing")
    func sequenceInitRefusesAnEmptySequence() throws {
        let set = try #require(NonEmptySet(elements: [1, 2, 2, 3]))

        #expect(set.elements == [1, 2, 3])
        #expect(NonEmptySet<Int>(elements: []) == nil)
    }

    @Test("Two sets of the same members in another order are the same value")
    func equalityIsOnTheMembersAlone() {
        let written = NonEmptySet(1, 2)
        let reversed = NonEmptySet(2, 1)

        #expect(written == reversed)
        #expect(written.hashValue == reversed.hashValue)
        // Each one still reaches the command line in the order it was written in.
        #expect(written.elements == [1, 2])
        #expect(reversed.elements == [2, 1])
    }
}
