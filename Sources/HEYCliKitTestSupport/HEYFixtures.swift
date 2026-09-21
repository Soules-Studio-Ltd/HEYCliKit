import Foundation

/// Why a fixture could not be read.
public enum HEYFixtureError: Error, Sendable, Hashable {
    /// No fixture with this file name is shipped in the test support bundle.
    case missing(String)
}

extension HEYFixtureError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .missing(name):
            "There is no fixture named \"\(name)\" in the HEYCliKitTestSupport bundle."
        }
    }
}

/// The captured CLI fixtures this package ships, read by file name.
///
/// The fixtures are copied into the test support bundle as a folder, so a test
/// never has to know how a resource bundle is named or where it sits. File names
/// are the way a fixture is asked for, and after 1.0 they are part of the public
/// API: a rename goes in the changelog.
public enum HEYFixtures {
    /// The folder every fixture is read from.
    private static var folder: URL? {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)
    }

    /// The location of one fixture on disk.
    ///
    /// Where a fixture sits is the bundle's business, so a fixture is only ever
    /// handed out as bytes.
    private static func url(named name: String) throws -> URL {
        guard
            let location = folder?.appending(path: name),
            FileManager.default.fileExists(atPath: location.path)
        else {
            throw HEYFixtureError.missing(name)
        }

        return location
    }

    /// The bytes of one fixture, exactly as the CLI printed them.
    public static func data(named name: String) throws -> Data {
        try Data(contentsOf: url(named: name))
    }
}
