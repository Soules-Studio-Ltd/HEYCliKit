import Foundation
import Testing

@testable import HEYCliKit
import HEYCliKitTestSupport

/// A decoding failure's description names keys and schema tokens and never a
/// value, so an app can log it verbatim. Each test here plants a value no schema
/// could contain, makes the CLI's output fail to decode around it, and checks that
/// the description names where the failure was without ever carrying that value.
///
/// The operations the fixture client has are read through it. The rest go through
/// `decodePayload`, which is the seam the fixture client decodes through too.
@Suite("Decoding description")
struct DecodingDescriptionTests {
    /// A value no key and no schema token contains, so finding it in a description
    /// can only mean the description carried a value.
    static let planted = "SECRETVAL7"

    /// A character no description contains, planted first in output that is not
    /// JSON, since the first character is the one Foundation quotes.
    static let plantedCharacter = "~"

    @Test("Stdout that is not JSON is described without quoting any of it")
    func outputThatIsNotJSONIsNeverQuoted() throws {
        let failure = try decodingFailure(
            of: VersionOnly.self,
            from: "\(Self.plantedCharacter)\(Self.planted)"
        )

        #expect(!failure.description.contains(Self.plantedCharacter))
        #expect(!failure.description.contains(Self.planted))
        #expect(failure.description == "The output could not be read.")
    }

    @Test(
        "A number that does not fit a Screener entry's id is described without it",
        arguments: ["123456789012345678901234", "100001.5"]
    )
    func numberThatDoesNotFitIsNeverQuoted(number: String) async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(
            .screener,
            standardOutput: Data(
                #"{"ok":true,"data":[{"id":\#(number)}],"meta":{"total_count":1}}"#.utf8
            )
        )

        let failure = try await expectDecodingFailure {
            _ = try await fixtureClient.client.screener()
        }

        #expect(!failure.description.contains(number))
        #expect(!failure.description.contains("100001"))
        #expect(!failure.description.contains("123456"))
        #expect(failure.description == "The output could not be read.")
    }

    @Test("A posting of a kind the package does not model is described without its kind")
    func postingKindIsNeverQuoted() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(
            .boxPage,
            standardOutput: Data(
                #"""
                {"ok":true,"data":{"postings":{"id":100001,"kind":"\#(Self.planted)","name":"Test subject 1"}}}
                """#.utf8
            )
        )

        let failure = try await expectDecodingFailure {
            _ = try await fixtureClient.client.boxPage(.imbox)
        }

        #expect(!failure.description.contains(Self.planted))
        #expect(failure.description.contains("data.postings"))
    }

    @Test("A decision outcome the package does not know is described by its key alone")
    func unknownOutcomeIsNeverQuoted() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(
            .approveScreenerEntries,
            standardOutput: Data(
                #"""
                {"ok":true,"data":[{"id":100001,"status":"\#(Self.planted)","name":"Test contact 1","email_address":"test1@example.com"}]}
                """#.utf8
            )
        )

        let failure = try await expectDecodingFailure {
            _ = try await fixtureClient.client.approveScreenerEntries(
                ScreenerApproval(entryIDs: NonEmptySet(ScreenerEntry.ID(100_001)))
            )
        }

        #expect(!failure.description.contains(Self.planted))
        #expect(failure.description.contains("data[0].status"))
    }

    @Test("A mail account missing its email address is described without its id")
    func mailAccountMissingItsEmailNeverNamesItsID() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(
            .mailAccounts,
            standardOutput: Data(
                #"""
                {"ok":true,"data":[{"id":"\#(Self.planted)","name":"Test User","purpose":"home","status":"active"}]}
                """#.utf8
            )
        )

        let failure = try await expectDecodingFailure {
            _ = try await fixtureClient.client.mailAccounts()
        }

        #expect(!failure.description.contains(Self.planted))
        #expect(failure.description.contains("email address"))
    }

    @Test("Only the package's own refusal is quoted, never another underlying error")
    func foreignUnderlyingErrorIsNeverQuoted() throws {
        let failure = try decodingFailure(
            of: PlantedCorruption.self,
            from: #"{"ok":true,"data":{}}"#
        )

        #expect(!failure.description.contains(Self.planted))
        #expect(failure.description == "The value at data could not be read.")
    }

    @Test("Each kind of decoding error names what was expected and where")
    func eachShapeNamesItsPath() throws {
        let typeMismatch = try decodingFailure(
            of: VersionOnly.self,
            from: #"{"ok":true,"data":{"version":7}}"#
        )
        let valueNotFound = try decodingFailure(
            of: VersionOnly.self,
            from: #"{"ok":true,"data":{"version":null}}"#
        )
        let keyNotFound = try decodingFailure(
            of: VersionOnly.self,
            from: #"{"ok":true,"data":{}}"#
        )
        let keyNotFoundAtTheRoot = try decodingFailure(
            of: VersionOnly.self,
            from: #"{"data":{}}"#
        )
        let typeMismatchInAList = try decodingFailure(
            of: [VersionOnly].self,
            from: #"{"ok":true,"data":[{"version":"1.4.0"},{"version":7}]}"#
        )

        #expect(typeMismatch.description == "Expected String at data.version.")
        #expect(valueNotFound.description == "Expected String at data.version, found null.")
        #expect(keyNotFound.description == "The key version is missing at data.")
        #expect(keyNotFoundAtTheRoot.description == "The key ok is missing at the root.")
        #expect(typeMismatchInAList.description == "Expected String at data[1].version.")
    }

    @Test("An error that is not a decoding error is described in a fixed sentence")
    func errorThatIsNotADecodingErrorIsDescribedPlainly() {
        struct Planted: Error, CustomStringConvertible {
            var description: String { DecodingDescriptionTests.planted }
        }

        #expect(describeDecodingError(Planted()) == "The output could not be decoded.")
    }

    /// Decodes an envelope that must fail, and returns its decoding failure.
    private func decodingFailure<Payload: Decodable>(
        of payloadType: Payload.Type,
        from standardOutput: String
    ) throws -> DecodingFailure {
        do {
            _ = try decodePayload(
                payloadType,
                exitStatus: .exited(0),
                standardOutput: Data(standardOutput.utf8),
                standardError: Data()
            )
        } catch let HEYCliKitError.decodingFailure(failure) {
            return failure
        }

        Issue.record("The envelope was expected to fail but decoded.")
        return DecodingFailure(description: "", rawText: "")
    }

    /// Runs an operation that must fail to decode, and returns its decoding failure.
    private func expectDecodingFailure(
        _ operation: () async throws -> Void
    ) async throws -> DecodingFailure {
        do {
            try await operation()
        } catch let HEYCliKitError.decodingFailure(failure) {
            return failure
        }

        Issue.record("The operation was expected to fail but returned a value.")
        return DecodingFailure(description: "", rawText: "")
    }
}

/// A payload with one required text field, for failures of every shape.
private struct VersionOnly: Decodable {
    let version: String
}

/// A payload that refuses itself with an underlying error carrying a value, the
/// way a Foundation error quotes the input it could not read.
private struct PlantedCorruption: Decodable {
    struct PlantedError: Error, CustomStringConvertible, CustomDebugStringConvertible {
        var description: String { DecodingDescriptionTests.planted }
        var debugDescription: String { DecodingDescriptionTests.planted }
    }

    init(from decoder: any Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Refused \(DecodingDescriptionTests.planted).",
                underlyingError: PlantedError()
            )
        )
    }
}
