import Foundation
import Testing

@testable import HEYCliKit
import HEYCliKitTestSupport

@Suite("Error mapping")
struct ErrorMappingTests {
    /// Runs the sign in status against one scripted answer and returns what it threw.
    private func heyError(
        _ standardOutput: Data,
        exitCode: Int32,
        standardError: String = ""
    ) async throws -> HEYCliKitError {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(standardOutput, exitCode: exitCode, standardError: standardError)]
        )

        return try await heyError { _ = try await client.signInStatus() }
    }

    /// Runs an operation that is expected to fail and returns the package's error.
    private func heyError(_ operation: () async throws -> Void) async throws -> HEYCliKitError {
        do {
            try await operation()
        } catch let error as HEYCliKitError {
            return error
        }

        Issue.record("The operation was expected to fail but returned a value.")
        throw ExpectedFailureMissing()
    }

    private struct ExpectedFailureMissing: Error {}

    @Test(
        "A signed out envelope maps to signed out and keeps the hint the app shows",
        arguments: ["error-auth.json", "error-noninteractive.json"]
    )
    func signedOut(fixture: String) async throws {
        // Scripted the way hey 1.4.0 prints it: nothing on stdout, and the failed
        // envelope on stderr.
        let error = try await heyError(
            Data(),
            exitCode: 3,
            standardError: String(decoding: try HEYFixtures.data(named: fixture), as: UTF8.self)
        )

        guard case let .signedOut(details) = error else {
            Issue.record("Expected signed out, got \(error).")
            return
        }

        #expect(details.code == "auth")
        #expect(details.message == "Not logged in")
        #expect(details.hint == "Run: hey auth login")
    }

    @Test("An api code maps to HEY unreachable or failed")
    func unreachableOrFailed() async throws {
        let error = try await heyError(HEYFixtures.data(named: "error-network.json"), exitCode: 7)

        guard case let .unreachableOrFailed(details) = error else {
            Issue.record("Expected HEY unreachable or failed, got \(error).")
            return
        }

        #expect(details.code == "api")
        #expect(
            details.message
                == "Get \"https://app.hey.com/imbox.json\": dial tcp: lookup app.hey.com: no such host"
        )
        #expect(details.hint == nil)
    }

    @Test(
        "A not found envelope maps to not found and keeps its message",
        arguments: [
            ("error-not-found.json", "resource not found"),
            ("error-not-found-box.json", "box \"feed\" not found"),
        ]
    )
    func notFound(fixture: String, message: String) async throws {
        let error = try await heyError(HEYFixtures.data(named: fixture), exitCode: 2)

        guard case let .notFound(details) = error else {
            Issue.record("Expected not found, got \(error).")
            return
        }

        #expect(details.code == "not_found")
        #expect(details.message == message)
    }

    @Test("A box the CLI does not know maps to not found through approve")
    func approveToAnUnknownBoxIsNotFound() async throws {
        // The captured failure is what the CLI answers when a box is named by its
        // display name: `feed` is what a user calls The Feed, and `feedbox` is the
        // only thing this package ever passes.
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "error-not-found-box.json"), exitCode: 2)]
        )

        let error = try await heyError {
            _ = try await client.approveScreenerEntries(
                ScreenerApproval(entryIDs: NonEmptySet(ScreenerEntry.ID(100_001)), destination: .feedbox)
            )
        }

        guard case let .notFound(details) = error else {
            Issue.record("Expected not found, got \(error).")
            return
        }

        #expect(details.code == "not_found")
        #expect(details.message == "box \"feed\" not found")
    }

    @Test("The Screener list maps a failure exactly as every other operation does")
    func screenerMapsItsErrors() async throws {
        // The Screener is the one operation that reads the envelope's own fields
        // rather than the payload alone, so it is worth proving it maps a failure
        // through the same path.
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "error-auth.json"), exitCode: 3)]
        )

        let error = try await heyError { _ = try await client.screener() }

        guard case let .signedOut(details) = error else {
            Issue.record("Expected signed out, got \(error).")
            return
        }

        #expect(details.code == "auth")
        #expect(details.message == "Not logged in")
        #expect(details.hint == "Run: hey auth login")
    }

    @Test("An unknown code at exit 1 maps to unknown code")
    func unknownCodeFromFixture() async throws {
        let error = try await heyError(HEYFixtures.data(named: "error-usage.json"), exitCode: 1)

        guard case let .unknownCode(details) = error else {
            Issue.record("Expected unknown code, got \(error).")
            return
        }

        #expect(details.code == "unknown")
        #expect(details.message == "Usage: hey move <box-item-id>...")
    }

    @Test("A rate limited envelope keeps its code, message and hint")
    func rateLimited() async throws {
        let envelope = Data(
            #"{"ok":false,"error":"Too many requests","code":"rate_limit","hint":"Try again later"}"#
                .utf8
        )

        let error = try await heyError(envelope, exitCode: 5)

        guard case let .rateLimited(details) = error else {
            Issue.record("Expected rate limited, got \(error).")
            return
        }

        #expect(details.code == "rate_limit")
        #expect(details.message == "Too many requests")
        #expect(details.hint == "Try again later")
    }

    @Test("A code the package does not know is carried through as unknown code")
    func unknownCodeIsCarriedThrough() async throws {
        let envelope = Data(#"{"ok":false,"error":"Something new","code":"brand_new"}"#.utf8)

        let error = try await heyError(envelope, exitCode: 1)

        guard case let .unknownCode(details) = error else {
            Issue.record("Expected unknown code, got \(error).")
            return
        }

        #expect(details.code == "brand_new")
        #expect(details.message == "Something new")
    }

    @Test(
        "A not found envelope on a mutation maps to not found and spawns once",
        arguments: [HEYClientOperation.move, .markSeen, .markUnseen]
    )
    func mutationNotFound(operation: HEYClientOperation) async throws {
        let (client, script) = makeScriptedClient(
            outputs: [
                scriptedOutput(try HEYFixtures.data(named: "error-not-found.json"), exitCode: 2)
            ]
        )
        let postingIDs = NonEmptySet(Posting.ID(1))

        let error = try await heyError {
            try await perform(operation, on: client, postingIDs: postingIDs)
        }

        guard case let .notFound(details) = error else {
            Issue.record("Expected not found, got \(error).")
            return
        }

        #expect(details.code == "not_found")
        // Nothing retries a mutation, so a failed one was asked for exactly once.
        #expect(script.recordedSpawns.count == 1)
    }

    @Test("An ok mutation envelope at a failing exit code is still an error")
    func okMutationEnvelopeAtAFailingExitIsAnError() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(#"{"ok": true, "summary": "x"}"#, exitCode: 1)]
        )

        let postingIDs = NonEmptySet(Posting.ID(1))

        let error = try await heyError {
            try await client.markSeen(postingIDs)
        }

        guard case let .unknownCode(details) = error else {
            Issue.record("Expected unknown code, got \(error).")
            return
        }

        #expect(details.code == nil)
        #expect(details.message == nil)
    }

    @Test("An ok envelope with no data is still a decoding failure for a read")
    func okEnvelopeWithNoDataIsADecodingFailureForARead() async throws {
        let error = try await heyError(Data(#"{"ok": true}"#.utf8), exitCode: 0)

        guard case let .decodingFailure(failure) = error else {
            Issue.record("Expected a decoding failure, got \(error).")
            return
        }

        #expect(failure.rawText == #"{"ok": true}"#)
    }

    @Test("An ok envelope with no data confirms a mutation")
    func okEnvelopeWithNoDataConfirmsAMutation() async throws {
        let (client, _) = makeScriptedClient(outputs: [scriptedOutput(#"{"ok": true}"#)])

        let postingIDs = NonEmptySet(Posting.ID(1))

        try await client.markUnseen(postingIDs)
    }

    @Test("Stdout that is not an envelope at exit 0 is a decoding failure carrying the raw text")
    func decodingFailureCarriesRawText() async throws {
        let error = try await heyError(Data("not json at all".utf8), exitCode: 0)

        guard case let .decodingFailure(failure) = error else {
            Issue.record("Expected a decoding failure, got \(error).")
            return
        }

        #expect(failure.rawText == "not json at all")
        #expect(failure.description.isEmpty == false)
    }

    @Test("Empty stdout at a non zero exit is a process failure carrying stderr")
    func processFailureCarriesStderr() async throws {
        let error = try await heyError(Data(), exitCode: 1, standardError: "boom")

        guard case let .processFailure(failure) = error else {
            Issue.record("Expected a process failure, got \(error).")
            return
        }

        #expect(failure.exitStatus == .exited(1))
        #expect(failure.standardError == "boom")
        #expect(failure.reason == nil)
    }

    @Test("A process killed by a signal is a process failure")
    func signaledProcessFailure() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [
                ProcessOutput(stdout: Data(), stderr: Data("terminated".utf8), exitStatus: .signaled(15))
            ]
        )

        let error = try await heyError { _ = try await client.signInStatus() }

        guard case let .processFailure(failure) = error else {
            Issue.record("Expected a process failure, got \(error).")
            return
        }

        #expect(failure.exitStatus == .signaled(15))
        #expect(failure.standardError == "terminated")
    }

    @Test(
        "Summary, notice and breadcrumbs are never parsed and a meta of any other shape is tolerated",
        arguments: [#"{ "total_count": 4 }"#, "7", "[1, 2]", #""text""#]
    )
    func opaqueFieldsAreNeverParsed(meta: String) async throws {
        // `meta.total_count` is the one meta field the package reads, and only the
        // Screener list asks for it, so a meta of any other shape has to decode
        // here exactly as a missing one would.
        let envelope = Data(
            """
            {
              "ok": true,
              "summary": { "text": "Logged in", "count": 2 },
              "notice": [1, 2, 3],
              "breadcrumbs": 7,
              "meta": \(meta),
              "data": {
                "authenticated": true,
                "expired": false,
                "expires_at": "2026-01-01T00:00:00Z"
              }
            }
            """.utf8
        )

        let (client, _) = makeScriptedClient(outputs: [scriptedOutput(envelope)])

        let status = try await client.signInStatus()

        #expect(status.isSignedIn)
        #expect(status.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("The cwd edge case fixture holds two envelopes for the same command")
    func edgeCaseCwdHoldsTwoEnvelopes() async throws {
        let (fromProjectDirectory, fromHome) = try edgeCaseCwdEnvelopes()

        let (failing, _) = makeScriptedClient(
            outputs: [scriptedOutput(fromProjectDirectory, exitCode: 1)]
        )
        let error = try await heyError { _ = try await failing.mailAccounts() }

        guard case let .usage(details) = error else {
            Issue.record("Expected a usage error, got \(error).")
            return
        }

        #expect(details.code == "usage")
        #expect(details.message == "account must be a positive ID or \"all\" (got \"not-the-real-one\")")

        let (succeeding, _) = makeScriptedClient(outputs: [scriptedOutput(fromHome)])
        let accounts = try await succeeding.mailAccounts()

        #expect(accounts.count == 1)
        #expect(accounts.first?.name == "Test contact 1")
    }

    /// Splits the cwd edge case fixture back into the two envelopes it captured.
    private func edgeCaseCwdEnvelopes() throws -> (fromProjectDirectory: Data, fromHome: Data) {
        let wrapper = try JSONSerialization.jsonObject(with: try HEYFixtures.data(named: "edge-case-cwd.json"))
        let object = try #require(wrapper as? [String: Any])

        func envelope(_ key: String) throws -> Data {
            let value = try #require(object[key])
            return try JSONSerialization.data(withJSONObject: value)
        }

        return (try envelope("from_project_dir_with_local_config"), try envelope("from_home"))
    }
}
