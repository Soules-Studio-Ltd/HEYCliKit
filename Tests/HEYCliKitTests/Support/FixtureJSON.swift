import Foundation

import HEYCliKitTestSupport

/// One step into a JSON document: a key of an object, or an index of an array.
///
/// A place is written as a literal list, such as `["data", "postings", 0]`, so a
/// test names where it mutates rather than parsing and serialising for itself.
enum JSONPathStep: Sendable {
    case key(String)
    case index(Int)
}

extension JSONPathStep: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self = .key(value)
    }
}

extension JSONPathStep: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self = .index(value)
    }
}

extension JSONPathStep: CustomStringConvertible {
    var description: String {
        switch self {
        case let .key(key): key
        case let .index(index): String(index)
        }
    }
}

extension [JSONPathStep] {
    /// The first posting of the captured Imbox, which is a single posting.
    static let firstSinglePosting: [JSONPathStep] = ["data", "postings", 0]
    /// Who the first posting of the captured Imbox is from.
    static let firstSinglePostingCreator: [JSONPathStep] = ["data", "postings", 0, "creator"]
    /// The first bundle of the captured Imbox, which is its tenth posting.
    static let firstBundle: [JSONPathStep] = ["data", "postings", 9]
    /// The last posting of the captured Imbox, its fiftieth, which is a single
    /// posting.
    static let lastImboxPosting: [JSONPathStep] = ["data", "postings", 49]
    /// The postings of a captured box page, the list itself.
    static let boxPagePostings: [JSONPathStep] = ["data", "postings"]
    /// The data of a captured box page, for a key it carries beside its postings.
    static let boxPageData: [JSONPathStep] = ["data"]
    /// The first entry of the captured Screener list, whose data is the list itself.
    static let firstScreenerEntry: [JSONPathStep] = ["data", 0]
    /// The posting one captured watch line carries.
    static let watchLinePosting: [JSONPathStep] = ["posting"]
    /// The watch line itself, for a key the line carries beside its posting.
    static let watchLine: [JSONPathStep] = []
}

extension Int {
    /// The first `added` line of `watch-session.ndjson`: the captured arrival of
    /// a new mail, posting 100002 on thread 100003.
    static let newMailArrival = 7
}

/// Why a mutated document could not be derived from a fixture.
enum FixtureJSONError: Error, CustomStringConvertible {
    /// The place named a key or an index the document does not hold.
    case noSuchPlace([JSONPathStep])
    /// The place named something that is not a JSON object, so it has no keys.
    case notAnObject([JSONPathStep])
    /// The place named something that is not a JSON array, so it has no elements.
    case notAnArray([JSONPathStep])
    /// The array at the place holds no element at that index.
    case noSuchElement(Int, at: [JSONPathStep])
    /// The key to remove or replace is not at that place, which would leave the
    /// document unmutated and the test passing on the fixture as it is.
    case noSuchKey(String, at: [JSONPathStep])
    /// The newline delimited fixture holds fewer lines than the one asked for.
    case noSuchLine(index: Int, fixture: String)

    var description: String {
        switch self {
        case let .noSuchPlace(place):
            "Nothing sits at \(Self.text(of: place)) in this document."
        case let .notAnObject(place):
            "What sits at \(Self.text(of: place)) in this document is not an object."
        case let .notAnArray(place):
            "What sits at \(Self.text(of: place)) in this document is not an array."
        case let .noSuchElement(index, place):
            "There is no element at index \(index) of \(Self.text(of: place)) in this document."
        case let .noSuchKey(key, place):
            "There is no key \"\(key)\" at \(Self.text(of: place)) in this document."
        case let .noSuchLine(index, fixture):
            "The fixture \"\(fixture)\" has no line at index \(index)."
        }
    }

    private static func text(of place: [JSONPathStep]) -> String {
        place.isEmpty ? "the document itself" : place.map(\.description).joined(separator: ".")
    }
}

/// Derives a mutated envelope from a shipped fixture, in test code.
///
/// The fixtures folder ships to every app and its file names are part of the
/// public API, so an envelope that only one test wants is derived here rather
/// than committed beside the captures. The place is data, so one helper covers
/// every posting, contact, Screener entry and watch line a test reaches for.
enum FixtureJSON {
    /// The document with one key gone from the object at the given place.
    ///
    /// A key that is not there is an error rather than a quiet no op, so a test
    /// cannot pass on a fixture it failed to mutate.
    static func removing(
        _ key: String,
        at place: [JSONPathStep],
        from document: Data
    ) throws -> Data {
        try mutating(document, at: place) { object in
            guard object.removeValue(forKey: key) != nil else {
                throw FixtureJSONError.noSuchKey(key, at: place)
            }
        }
    }

    /// The document with one key's value replaced in the object at the given
    /// place. The key has to be there already, for the same reason.
    static func replacing(
        _ key: String,
        with value: any Sendable,
        at place: [JSONPathStep],
        in document: Data
    ) throws -> Data {
        try mutating(document, at: place) { object in
            guard object[key] != nil else {
                throw FixtureJSONError.noSuchKey(key, at: place)
            }
            object[key] = value
        }
    }

    /// The document with one element of the array at the given place replaced
    /// by a value written as JSON text, such as `7`, `"a row"`, `[]` or `null`.
    ///
    /// The value is text rather than a Swift value so a test can put in a row
    /// that is not an object at all, `null` included, which the key based
    /// helpers cannot. The index has to be there already, for the same reason
    /// a key does.
    static func replacingElement(
        _ index: Int,
        withJSON text: String,
        at place: [JSONPathStep],
        in document: Data
    ) throws -> Data {
        let value = try JSONSerialization.jsonObject(
            with: Data(text.utf8),
            options: [.fragmentsAllowed]
        )

        return try mutatingValue(document, at: place) { found in
            guard var array = found as? [Any] else {
                throw FixtureJSONError.notAnArray(place)
            }
            guard array.indices.contains(index) else {
                throw FixtureJSONError.noSuchElement(index, at: place)
            }
            array[index] = value

            return array
        }
    }

    /// One line of a newline delimited fixture, which is a document of its own.
    static func line(_ index: Int, ofFixtureNamed name: String) throws -> Data {
        let text = String(decoding: try HEYFixtures.data(named: name), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.indices.contains(index) else {
            throw FixtureJSONError.noSuchLine(index: index, fixture: name)
        }

        return Data(lines[index].utf8)
    }

    private static func mutating(
        _ document: Data,
        at place: [JSONPathStep],
        _ change: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        try mutatingValue(document, at: place) { found in
            guard var object = found as? [String: Any] else {
                throw FixtureJSONError.notAnObject(place)
            }
            try change(&object)

            return object
        }
    }

    private static func mutatingValue(
        _ document: Data,
        at place: [JSONPathStep],
        _ change: (Any) throws -> Any
    ) throws -> Data {
        let mutated = try mutate(
            try JSONSerialization.jsonObject(with: document),
            at: place[...],
            in: place,
            change
        )

        // Slashes are left as the CLI printed them, so the raw text a failing
        // test prints reads the way the capture does.
        return try JSONSerialization.data(withJSONObject: mutated, options: [.withoutEscapingSlashes])
    }

    private static func mutate(
        _ value: Any,
        at place: ArraySlice<JSONPathStep>,
        in whole: [JSONPathStep],
        _ change: (Any) throws -> Any
    ) throws -> Any {
        guard let step = place.first else {
            return try change(value)
        }

        switch step {
        case let .key(key):
            guard var object = value as? [String: Any], let child = object[key] else {
                throw FixtureJSONError.noSuchPlace(whole)
            }
            object[key] = try mutate(child, at: place.dropFirst(), in: whole, change)

            return object
        case let .index(index):
            guard var array = value as? [Any], array.indices.contains(index) else {
                throw FixtureJSONError.noSuchPlace(whole)
            }
            array[index] = try mutate(array[index], at: place.dropFirst(), in: whole, change)

            return array
        }
    }
}
