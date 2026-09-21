import Foundation
import Testing

import HEYCliKit
import HEYCliKitTestSupport

/// The box kinds are checked against the captured box list rather than against a
/// list written out here, so a kind the CLI stops printing, or starts printing,
/// shows up as a failure instead of as a comment nobody reads.
@Suite("Box kind")
struct BoxKindTests {
    /// One row of the captured box list, read through `BoxKind`'s own decoding so
    /// the test exercises the conformance an app's decoding would go through.
    private struct Row: Decodable {
        let kind: BoxKind
    }

    private struct RowEnvelope: Decodable {
        let data: [Row]
    }

    @Test("The captured box list holds exactly the six kinds the package knows")
    func capturedBoxListMapsToEveryKind() throws {
        let envelope = try JSONDecoder().decode(
            RowEnvelope.self,
            from: try HEYFixtures.data(named: "boxes.json")
        )

        #expect(Set(envelope.data.map(\.kind)) == Set(BoxKind.allCases))
    }

    @Test("A display name the user sees is not a kind")
    func aDisplayNameIsNotAKind() {
        // The CLI names The Feed `feedbox`, and `feed` is what an app reaches for
        // when it passes a name instead of a kind.
        #expect(BoxKind(rawValue: "feed") == nil)
    }
}
