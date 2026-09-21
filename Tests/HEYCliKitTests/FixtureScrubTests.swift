import Foundation
import Testing

/// The scrub rule names the fields a human can read, so it catches every visible id
/// and misses the ones sitting one base64 layer down inside a cursor. This suite
/// decodes the cursors instead of reading them, and it pins the one credential
/// instant the fixtures carry, a token's `expires_at`, to a fake value.
///
/// It reads the fixtures folder committed to the repository rather than the copy a
/// build puts in the test support bundle, because what has to stay scrubbed is what
/// goes public, not what a local build happens to hold.
@Suite("Fixture scrub")
struct FixtureScrubTests {
    /// The range every visible posting id in the fixtures already uses. A real HEY
    /// posting id is ten digits, so a real one falls outside it.
    private static let fakePostingIDs = 100_000...100_999

    /// The one instant every cursor in this package is re-encoded to. A real capture
    /// timestamp is not this value.
    private static let fakeInstant = "2026-01-01T00:00:00.000000Z"

    @Test("Every cursor a committed fixture carries is fake once it is decoded")
    func everyCommittedCursorIsScrubbed() throws {
        for cursor in try Self.committedCursors() {
            guard let decoded = Self.decoded(cursor) else { continue }

            #expect(
                Self.fakePostingIDs.contains(decoded.values.id),
                """
                \(cursor.fixtureName) carries a cursor holding posting id \
                \(decoded.values.id), which is outside the fake range \
                \(Self.fakePostingIDs.lowerBound) to \(Self.fakePostingIDs.upperBound).
                """
            )
            #expect(
                decoded.values.observedAt == Self.fakeInstant,
                """
                \(cursor.fixtureName) carries a cursor observed at \
                \(decoded.values.observedAt), and every cursor is re-encoded to \
                \(Self.fakeInstant).
                """
            )
        }
    }

    /// The one instant every credential expiry in this package is replaced with.
    private static let fakeExpiry = "2026-01-01T00:00:00Z"

    @Test("Every expires_at a committed fixture carries is the fake instant")
    func everyCommittedExpiryIsScrubbed() throws {
        for expiry in try Self.committedExpiries() {
            #expect(
                expiry.value as? String == Self.fakeExpiry,
                """
                \(expiry.fixtureName) carries an expires_at of \(expiry.value), and \
                every credential instant is replaced with \(Self.fakeExpiry).
                """
            )
        }
    }

    @Test("The scan reads the expires_at the committed signed in status holds")
    func theScanFindsTheExpiriesThatAreThere() throws {
        // As with the cursors, a scan that matched nothing would leave the check
        // above passing over an empty list. The signed in auth status holds one.
        #expect(try Self.committedExpiries().count >= 1)
    }

    @Test("The scan reads every cursor the committed Imbox fixtures hold")
    func theScanFindsTheCursorsThatAreThere() throws {
        // A scan that silently matched nothing would leave the check above passing
        // over an empty list, so the floor is asserted on its own. Six is what the
        // three Imbox fixtures hold today, two apiece.
        #expect(try Self.committedCursors().count >= 6)
    }
}

/// One cursor, together with the fixture it was read out of, so a failure says which
/// file has to be scrubbed rather than leaving somebody to find it by hand.
private struct FoundCursor {
    let fixtureName: String
    let rawValue: String
}

/// One `expires_at` value, together with the fixture it was read out of.
private struct FoundExpiry {
    let fixtureName: String
    let value: Any
}

/// What a page cursor holds once it is decoded.
///
/// Every value is required, so a cursor that decodes to some other shape is a
/// failure rather than a pass: nothing is waved through unlooked at.
private struct DecodedCursor: Decodable {
    struct Values: Decodable {
        let seen: String
        let observedAt: String
        let id: Int

        private enum CodingKeys: String, CodingKey {
            case seen
            case observedAt = "observed_at"
            case id
        }
    }

    let pageNumber: Int
    let values: Values

    private enum CodingKeys: String, CodingKey {
        case pageNumber = "page_number"
        case values
    }
}

extension FixtureScrubTests {
    /// The fixtures folder as committed, derived from this file's own path.
    ///
    /// This file sits at `Tests/HEYCliKitTests/FixtureScrubTests.swift`, so the
    /// package root is two folders up from the folder holding it.
    private static var fixturesFolder: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/HEYCliKitTestSupport/Fixtures")
    }

    /// Every committed fixture file, in the order the folder is enumerated.
    private static func committedFixtureFiles() throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(at: fixturesFolder, includingPropertiesForKeys: nil),
            "The committed fixtures folder was expected at \(fixturesFolder.path())."
        )
        var files: [URL] = []

        for case let url as URL in enumerator where url.hasDirectoryPath == false {
            // A name carrying -private is gitignored, so it is a local capture that is
            // allowed to hold unscrubbed bytes. That marker is precisely what says the
            // file is not committed, and this check is about what is.
            guard url.lastPathComponent.contains("-private") == false else { continue }

            // A capture is bytes the CLI printed, and documentation about cursors is not
            // a fixture carrying one. Every capture here is .json, .ndjson or .txt, so
            // the skip is on the extension rather than on the name README.md, and a
            // second documentation file added later is skipped as well.
            guard url.pathExtension.lowercased() != "md" else { continue }

            files.append(url)
        }

        return files
    }

    /// Every cursor in every committed fixture, in the order the files are read.
    fileprivate static func committedCursors() throws -> [FoundCursor] {
        // The value of a `page` query item inside a URL, which runs to the end of the
        // string it sits in or to the `&` that would start the next query item, and
        // the value of a `next_page` key, which is the bare cursor with no URL at all.
        let pageQueryItem = /page=([A-Za-z0-9+\/=_-]+)/
        let nextPageKey = /"next_page"\s*:\s*"([^"]+)"/

        var cursors: [FoundCursor] = []

        for url in try committedFixtureFiles() {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let raw = text.matches(of: pageQueryItem).map { String($0.output.1) }
                + text.matches(of: nextPageKey).map { String($0.output.1) }

            cursors += raw.map {
                FoundCursor(fixtureName: url.lastPathComponent, rawValue: $0)
            }
        }

        return cursors
    }

    /// Every `expires_at` value, at any depth, in every committed JSON fixture and in
    /// every line of every committed watch stream.
    ///
    /// The documents are parsed rather than searched as text, so a value is found
    /// whatever its type and however the capture happens to be laid out.
    ///
    /// A document that is not valid JSON is recorded as an issue naming the fixture,
    /// and the line for a watch stream, so the test fails rather than passing over it.
    fileprivate static func committedExpiries(
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [FoundExpiry] {
        var expiries: [FoundExpiry] = []

        for url in try committedFixtureFiles() {
            let fixtureName = url.lastPathComponent
            // Each document with the place it is quoted from in a failure message: the
            // file alone for a JSON fixture, the file and its line for a watch stream.
            let documents: [(place: String, data: Data)]

            switch url.pathExtension.lowercased() {
            case "json":
                documents = [(fixtureName, try Data(contentsOf: url))]
            case "ndjson":
                // Empty lines are kept through the split so the line numbers stay true,
                // then blank ones are passed over, as a watch stream reader would.
                documents = try Data(contentsOf: url)
                    .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                    .enumerated()
                    .filter { String(decoding: $0.element, as: UTF8.self).allSatisfy(\.isWhitespace) == false }
                    .map { ("\(fixtureName) line \($0.offset + 1)", Data($0.element)) }
            default:
                // Only .json and .ndjson fixtures are JSON, so anything else is not
                // scanned for expiries.
                continue
            }

            for document in documents {
                let object: Any
                do {
                    object = try JSONSerialization.jsonObject(with: document.data, options: [.fragmentsAllowed])
                } catch {
                    Issue.record(
                        "\(document.place) is not valid JSON, so its expires_at values cannot be checked: \(error).",
                        sourceLocation: sourceLocation
                    )
                    continue
                }

                expiries += expiryValues(in: object).map {
                    FoundExpiry(fixtureName: fixtureName, value: $0)
                }
            }
        }

        return expiries
    }

    /// Every value keyed `expires_at` inside a parsed JSON value, however deep.
    private static func expiryValues(in object: Any) -> [Any] {
        switch object {
        case let dictionary as [String: Any]:
            dictionary.flatMap { key, value in
                (key == "expires_at" ? [value] : []) + expiryValues(in: value)
            }
        case let array as [Any]:
            array.flatMap { expiryValues(in: $0) }
        default:
            []
        }
    }

    /// Decodes one cursor, recording the fixture it came from when it will not decode.
    ///
    /// The cursors are stored without their trailing `=`, and `Data(base64Encoded:)`
    /// is strict about padding, so the padding is put back first.
    fileprivate static func decoded(
        _ cursor: FoundCursor,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> DecodedCursor? {
        // The regex matches the URL safe alphabet, which the decoder rejects, so it is
        // translated here rather than dropped from the regex, because a URL safe cursor
        // the regex did not match would pass unchecked, which is the silent miss this
        // suite exists to prevent.
        let standardAlphabet = cursor.rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - standardAlphabet.count % 4) % 4
        let padded = standardAlphabet + String(repeating: "=", count: padding)

        guard let data = Data(base64Encoded: padded) else {
            Issue.record(
                "\(cursor.fixtureName) carries a cursor that is not base64: \(cursor.rawValue).",
                sourceLocation: sourceLocation
            )
            return nil
        }

        do {
            return try JSONDecoder().decode(DecodedCursor.self, from: data)
        } catch {
            Issue.record(
                """
                \(cursor.fixtureName) carries a cursor that does not hold a page \
                number and a seen, observed_at and id triple: \
                \(String(decoding: data, as: UTF8.self)).
                """,
                sourceLocation: sourceLocation
            )
            return nil
        }
    }
}
