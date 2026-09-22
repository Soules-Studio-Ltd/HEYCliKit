import Foundation
import Testing

@testable import HEYCliKit

/// Every date the package reads goes through the one envelope decoder, so these
/// tests decode through it directly, then once each through the sign in status and
/// the watch line decoder to show the same strategy sits behind both.
@Suite("Date decoding")
struct DateDecodingTests {
    /// One fraction the CLI might print after the seconds of 2026-09-03T21:40:15,
    /// and the instant it stands for in UTC.
    struct FractionRow: Sendable, CustomTestStringConvertible {
        let digits: String
        let secondsSince1970: TimeInterval

        /// The text the CLI prints for this fraction in the given zone. No digits
        /// means no `.` at all, which is how Go prints a whole second.
        func text(zone: String) -> String {
            let fraction = digits.isEmpty ? "" : "." + digits

            return "2026-09-03T21:40:15" + fraction + zone
        }

        var testDescription: String {
            digits.isEmpty ? "no fraction" : "\(digits.count) digits"
        }
    }

    /// Go prints from none to nine fraction digits and trims trailing zeros, so
    /// every length is one the CLI can print. Each instant is written by hand.
    static let rows: [FractionRow] = [
        FractionRow(digits: "", secondsSince1970: 1_788_471_615),
        FractionRow(digits: "7", secondsSince1970: 1_788_471_615.7),
        FractionRow(digits: "79", secondsSince1970: 1_788_471_615.79),
        FractionRow(digits: "793", secondsSince1970: 1_788_471_615.793),
        FractionRow(digits: "7934", secondsSince1970: 1_788_471_615.7934),
        FractionRow(digits: "79345", secondsSince1970: 1_788_471_615.79345),
        FractionRow(digits: "793452", secondsSince1970: 1_788_471_615.793452),
        FractionRow(digits: "7934521", secondsSince1970: 1_788_471_615.7934521),
        FractionRow(digits: "79345212", secondsSince1970: 1_788_471_615.79345212),
        FractionRow(digits: "793452123", secondsSince1970: 1_788_471_615.793452123),
    ]

    /// One zone the CLI might print after a date, and how far that zone's wall
    /// clock runs ahead of UTC. A wall time in a zone ahead of UTC is an earlier
    /// instant than the same wall time in UTC, so the instant is the UTC one minus
    /// the offset.
    struct ZoneRow: Sendable, CustomTestStringConvertible {
        let text: String
        let offsetFromUTC: TimeInterval

        var testDescription: String { text }
    }

    /// `Z` is what the CLI prints on most dates, and a local offset is what it
    /// prints on `expires_at`: ahead of UTC for a user in the Netherlands in
    /// summer, behind it for a user on the US east coast in winter.
    static let zones: [ZoneRow] = [
        ZoneRow(text: "Z", offsetFromUTC: 0),
        ZoneRow(text: "+02:00", offsetFromUTC: 7200),
        ZoneRow(text: "-05:00", offsetFromUTC: -18_000),
    ]

    /// Dates the package cannot read: a `.` with no digit after it, and text that
    /// is no date at all.
    static let unreadableDates = ["2026-09-03T21:40:15.Z", "nope-3f9c2a"]

    private struct Stamp: Decodable {
        let at: Date
    }

    private func stamp(_ text: String) throws -> Stamp {
        try makeEnvelopeDecoder().decode(Stamp.self, from: Data(#"{"at":"\#(text)"}"#.utf8))
    }

    @Test("Every fraction length decodes in every zone form", arguments: rows, zones)
    func everyFractionDecodes(row: FractionRow, zone: ZoneRow) throws {
        let decoded = try stamp(row.text(zone: zone.text))

        // `+02:00` is 7200 seconds before the `Z` instant and `-05:00` 18000 after
        // it. The ninth digit is below what a Date this far from 2001 can hold, so
        // every row is compared to the microsecond rather than exactly.
        expect(decoded.at, isWithinAMicrosecondOf: row.secondsSince1970 - zone.offsetFromUTC)
    }

    @Test("A sign in status whose expiry carries a local offset decodes")
    func expiryWithALocalOffsetDecodes() async throws {
        // The CLI formats `expires_at` in the machine's own zone, so a user in the
        // Netherlands in summer is printed an offset of two hours.
        let envelope = Data(
            """
            {
              "ok": true,
              "data": {
                "authenticated": true,
                "expired": false,
                "expires_at": "2026-01-01T00:00:00+02:00"
              }
            }
            """.utf8
        )
        let (client, _) = makeScriptedClient(outputs: [scriptedOutput(envelope)])

        let status = try await client.signInStatus()

        let expiresAt = try #require(status.expiresAt)
        expect(expiresAt, isWithinAMicrosecondOf: 1_767_225_600 - 7200)
    }

    @Test("A ready line with a six digit fraction is a ready line at that instant")
    func readyLineWithSixDigitsDecodes() throws {
        var decoder = WatchLineDecoder()

        let line = decoder.decode(#"{"change":"ready","at":"2026-09-03T21:40:15.793452Z"}"#)

        #expect(line.kind == .ready)
        let at = try #require(line.at)
        expect(at, isWithinAMicrosecondOf: 1_788_471_615.793452)
    }

    @Test(
        "A date the package cannot read is refused in its own words and never quoted",
        arguments: unreadableDates
    )
    func unreadableDateIsRefused(text: String) throws {
        let error: DecodingError
        do {
            _ = try stamp(text)
            Issue.record("The date was expected to be refused but decoded.")
            return
        } catch let refusal as DecodingError {
            error = refusal
        }

        guard case let .dataCorrupted(context) = error else {
            Issue.record("Expected a corrupted data error, got \(error).")
            return
        }

        #expect(context.codingPath.map(\.stringValue) == ["at"])
        #expect(context.debugDescription.contains("RFC 3339"))
        #expect(context.underlyingError is SchemaRefusal)
        #expect(!String(describing: error).contains(text))
    }

    @Test(
        "A decoding failure for an unreadable date never quotes the date",
        arguments: unreadableDates
    )
    func decodingFailureNeverQuotesTheDate(text: String) throws {
        let envelope = Data(#"{"ok":true,"data":{"at":"\#(text)"}}"#.utf8)

        let error: HEYCliKitError
        do {
            _ = try decodePayload(
                Stamp.self,
                exitStatus: .exited(0),
                standardOutput: envelope,
                standardError: Data()
            )
            Issue.record("The envelope was expected to fail but decoded.")
            return
        } catch let failure as HEYCliKitError {
            error = failure
        }

        guard case let .decodingFailure(failure) = error else {
            Issue.record("Expected a decoding failure, got \(error).")
            return
        }

        #expect(failure.description.contains("RFC 3339"))
        #expect(!failure.description.contains(text))
    }
}
