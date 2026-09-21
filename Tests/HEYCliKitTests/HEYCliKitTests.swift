import Foundation
import Testing

import HEYCliKitTestSupport

@Test("The fixtures README is shipped alongside the fixtures it documents")
func fixturesREADMEIsShipped() throws {
    let readme = String(decoding: try HEYFixtures.data(named: "README.md"), as: UTF8.self)

    #expect(readme.contains("Scrub before committing"))
}
