import Foundation
import Testing

@testable import HEYCliKit
import HEYCliKitTestSupport

@Suite("Client operations")
struct ClientOperationTests {
    @Test("The sign in status decodes from the captured envelope")
    func signInStatusDecodes() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "auth-status.json"))]
        )

        let status = try await client.signInStatus()

        #expect(status.isSignedIn)
        #expect(status.isExpired == false)
        #expect(status.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("A signed out sign in status is a value, not a thrown signed out error")
    func signedOutSignInStatusDecodes() async throws {
        // `hey auth status --json` exits 0 and prints a success envelope whether or
        // not it holds credentials, so the one call an app makes before anything
        // else answers instead of failing. The signed out envelope stops at
        // `authenticated`: no `expired`, no `expires_at`, no credential detail.
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "auth-status-signed-out.json"))]
        )

        let status = try await client.signInStatus()

        #expect(status.isSignedIn == false)
        #expect(status.isExpired == false)
        #expect(status.expiresAt == nil)
    }

    @Test("A read while signed out throws signed out, which is why the status is asked first")
    func signedOutReadThrowsSignedOut() async throws {
        // The signed out capture of a read under 1.4.0: exit 3, nothing at all on
        // stdout, and the failed envelope on stderr, byte for byte `error-auth.json`.
        let envelope = String(decoding: try HEYFixtures.data(named: "error-auth.json"), as: UTF8.self)
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(Data(), exitCode: 3, standardError: envelope)]
        )

        do {
            _ = try await client.boxPage(.imbox)
            Issue.record("The read was expected to fail but returned a page.")
        } catch let error as HEYCliKitError {
            guard case .signedOut = error else {
                Issue.record("Expected signed out, got \(error).")
                return
            }
        }
    }

    @Test("The CLI version decodes from the captured envelope")
    func versionDecodes() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "version.json"))]
        )

        let version = try await client.version()

        #expect(version.version == "1.4.0")
        #expect(version.commit == "980cdc2021cbf672d4735ba0243e9a2c0568a465")
        #expect(version.date == Date(timeIntervalSince1970: 1_788_377_356))
    }

    @Test("A version envelope with no commit and no date still decodes")
    func versionDecodesWithoutACommitOrADate() async throws {
        // What a `go install` build prints: the semantic version is stamped and
        // nothing else is. It is the binary an app most wants named in a problem
        // report, so the read answers rather than failing to decode.
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(#"{"ok": true, "data": {"version": "1.4.0"}}"#)]
        )

        let version = try await client.version()

        #expect(version.version == "1.4.0")
        #expect(version.commit == nil)
        #expect(version.date == nil)
    }

    @Test("A version envelope stamped unknown decodes, with a date that is not a date")
    func versionDecodesUnknownStamps() async throws {
        // The other shape a build from source prints. The commit is carried as the
        // CLI printed it, since the package reads no meaning into the CLI's text,
        // and the date cannot be one, so it is nil rather than a decoding failure.
        let envelope = """
            {"ok": true, "data": {"version": "1.4.0", "commit": "unknown", "date": "unknown"}}
            """
        let (client, _) = makeScriptedClient(outputs: [scriptedOutput(envelope)])

        let version = try await client.version()

        #expect(version.version == "1.4.0")
        #expect(version.commit == "unknown")
        #expect(version.date == nil)
    }

    @Test("The tested CLI version matches the captured version fixture")
    func testedCLIVersionMatchesFixture() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "version.json"))]
        )

        let version = try await client.version()

        #expect(HEYCliKit.testedCLIVersion == "1.4.0")
        #expect(HEYCliKit.testedCLIVersion == version.version)
    }

    @Test("The mail account list drops the all row")
    func mailAccountsDropTheAllRow() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "accounts.json"))]
        )

        let accounts = try await client.mailAccounts()

        let account = try #require(accounts.first)
        #expect(accounts.count == 1)
        #expect(account.id == MailAccount.ID("123456"))
        #expect(account.name == "Test User")
        #expect(account.emailAddress == "test@example.com")
        #expect(account.purpose == "home")
        #expect(account.status == "active")
    }

    @Test("The Screener list decodes its entries and the total count beside them")
    func screenerDecodes() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "screener.json"))]
        )

        let screener = try await client.screener()

        let entry = try #require(screener.entries.first)
        #expect(screener.entries.count == 1)
        #expect(screener.totalCount == 1)
        #expect(entry.id == ScreenerEntry.ID(100_001))
        #expect(entry.name == "Test contact 1")
        #expect(entry.emailAddress == "test1@example.com")
        #expect(entry.subject == "Test 5")
        #expect(entry.summary == "Test 5")
        #expect(entry.topicID == TopicID(100_002))
    }

    @Test("An empty Screener decodes as no entries and a total count of zero")
    func emptyScreenerDecodes() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "screener-empty.json"))]
        )

        let screener = try await client.screener()

        #expect(screener.entries.isEmpty)
        #expect(screener.totalCount == 0)
    }

    @Test(
        "A Screener list without a total count is a decoding failure rather than a guess",
        arguments: [
            #"{"ok":true,"data":[]}"#,
            #"{"ok":true,"data":[],"meta":7}"#,
            #"{"ok":true,"data":[],"meta":{"pages_fetched":1}}"#,
        ]
    )
    func screenerWithoutATotalCountFails(envelope: String) async throws {
        let (client, _) = makeScriptedClient(outputs: [scriptedOutput(envelope)])

        do {
            _ = try await client.screener()
            Issue.record("The operation was expected to fail but returned a value.")
        } catch let HEYCliKitError.decodingFailure(failure) {
            #expect(failure.rawText == envelope)
            #expect(failure.description.contains("total_count"))
        }
    }

    /// Reads the captured Screener list with one key removed from its first
    /// entry, derived here rather than committed beside the captures.
    private func screener(withoutEntryKey key: String) async throws -> Screener {
        let envelope = try FixtureJSON.removing(
            key,
            at: .firstScreenerEntry,
            from: try HEYFixtures.data(named: "screener.json")
        )
        let (client, _) = makeScriptedClient(outputs: [scriptedOutput(envelope)])

        return try await client.screener()
    }

    /// A key the CLI leaves out of a Screener entry when its value is empty,
    /// which is what a waiting sender with a bare address prints.
    enum ScreenerEntryAbsentKey: String, CaseIterable, CustomTestStringConvertible {
        case name
        case emailAddress = "email_address"
        case subject
        case summary
        case topicID = "topic_id"

        var testDescription: String { rawValue }

        /// What the field reads as once the CLI has left the key out: the zero
        /// value where the type has an honest one, and nothing where it has not.
        var expectedValue: AnyHashable {
            switch self {
            case .name, .emailAddress, .subject, .summary: AnyHashable("")
            case .topicID: AnyHashable(TopicID?.none)
            }
        }

        func decodedValue(_ entry: ScreenerEntry) -> AnyHashable {
            switch self {
            case .name: AnyHashable(entry.name)
            case .emailAddress: AnyHashable(entry.emailAddress)
            case .subject: AnyHashable(entry.subject)
            case .summary: AnyHashable(entry.summary)
            case .topicID: AnyHashable(entry.topicID)
            }
        }
    }

    @Test(
        "A Screener entry decodes an absent key as the CLI's zero value or no value",
        arguments: ScreenerEntryAbsentKey.allCases
    )
    func screenerEntryDecodesAnAbsentKey(key: ScreenerEntryAbsentKey) async throws {
        let screener = try await screener(withoutEntryKey: key.rawValue)

        let entry = try #require(screener.entries.first)
        #expect(key.decodedValue(entry) == key.expectedValue)
        // A sibling the derived envelope left alone, so the test says the entry
        // itself decoded and not merely the list around it.
        #expect(entry.id == ScreenerEntry.ID(100_001))
    }

    @Test("Approving an entry decodes the decision HEY confirmed")
    func approveDecodesItsDecision() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "screener-approve.json"))]
        )

        let decisions = try await client.approveScreenerEntries(
            ScreenerApproval(entryIDs: NonEmptySet(ScreenerEntry.ID(100_001)))
        )

        let decision = try #require(decisions.first)
        #expect(decisions.count == 1)
        #expect(decision.outcome == .approved)
        #expect(decision.entryID == ScreenerEntry.ID(100_001))
        #expect(decision.name == "Test contact 1")
        #expect(decision.emailAddress == "test1@example.com")
    }

    @Test("Denying an entry decodes the decision HEY confirmed")
    func denyDecodesItsDecision() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "screener-deny.json"))]
        )

        let decisions = try await client.denyScreenerEntries(NonEmptySet(ScreenerEntry.ID(100_001)))

        let decision = try #require(decisions.first)
        #expect(decision.outcome == .denied)
        #expect(decision.entryID == ScreenerEntry.ID(100_001))
    }

    @Test("A decision status the package does not know is a decoding failure")
    func unknownDecisionStatusFails() async throws {
        // A status nobody has seen could mean anything, and claiming a sender was
        // approved when HEY said something else is the one mistake worth failing on.
        let envelope = #"{"ok":true,"data":[{"id":1,"status":"deferred","name":"A","email_address":"a@b.c"}]}"#
        let (client, _) = makeScriptedClient(outputs: [scriptedOutput(envelope)])

        do {
            _ = try await client.denyScreenerEntries(NonEmptySet(ScreenerEntry.ID(100_001)))
            Issue.record("The operation was expected to fail but returned a value.")
        } catch let HEYCliKitError.decodingFailure(failure) {
            #expect(failure.rawText == envelope)
        }
    }

    @Test("A move confirms from the captured mutation envelope and returns nothing")
    func moveConfirms() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "mutation-move.json"))]
        )

        let postingIDs = NonEmptySet(Posting.ID(1))

        try await client.move(postingIDs, to: .laterbox)
    }

    @Test(
        "Marking postings seen and unseen confirms from the captured mutation envelope",
        arguments: [HEYClientOperation.markSeen, .markUnseen]
    )
    func seenChangesConfirm(operation: HEYClientOperation) async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "mutation-seen.json"))]
        )
        let postingIDs = NonEmptySet(Posting.ID(1), Posting.ID(2))

        try await perform(operation, on: client, postingIDs: postingIDs)
    }

    @Test("A mutation envelope that carries data of its own still confirms")
    func mutationWithDataConfirms() async throws {
        // A mutation is confirmed by `ok` alone, so a payload the CLI might start
        // printing one day is ignored rather than decoded and failed on.
        let envelope = Data(
            #"{"ok":true,"summary":"1 moved","data":{"moved":[1],"anything":{"else":true}}}"#.utf8
        )
        let (client, _) = makeScriptedClient(outputs: [scriptedOutput(envelope)])

        let postingIDs = NonEmptySet(Posting.ID(1))

        try await client.markSeen(postingIDs)
    }
}
