import Foundation
import Testing

import HEYCliKitTestSupport

@Suite("Fixture loader")
struct FixtureLoaderTests {
    @Test("A fixture is read from the test support bundle by file name")
    func readsAFixtureByName() throws {
        let readme = String(decoding: try HEYFixtures.data(named: "README.md"), as: UTF8.self)

        #expect(readme.hasPrefix("# Fixtures"))
    }

    @Test("An unknown fixture name fails with the name it was asked for")
    func unknownNameFails() throws {
        #expect(throws: HEYFixtureError.missing("no-such-fixture.json")) {
            try HEYFixtures.data(named: "no-such-fixture.json")
        }
    }
}
