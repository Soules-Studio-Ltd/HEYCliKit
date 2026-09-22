import Foundation
import Testing

import HEYCliKit
import HEYCliKitTestSupport

/// The fixture client is exercised the way an app's tests use it: through the
/// public API only, with no `@testable` import.
@Suite("Fixture client")
struct FixtureClientTests {
    @Test("A scripted fixture decodes exactly as the live client would decode it")
    func scriptedFixtureDecodes() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.version, fixture: "version.json")

        let version = try await fixtureClient.client.version()

        #expect(version.version == "1.4.0")
    }

    @Test("Two scripted answers for one operation come back in the order they were scripted")
    func queueAnswersInOrder() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.mailAccounts, fixture: "accounts.json")
        fixtureClient.script(
            .mailAccounts,
            standardOutput: Data(
                """
                {
                  "ok": true,
                  "data": [
                    {
                      "id": "654321",
                      "name": "Second User",
                      "email": "second@example.com",
                      "purpose": "work",
                      "status": "active"
                    }
                  ]
                }
                """.utf8
            )
        )

        let first = try await fixtureClient.client.mailAccounts()
        let second = try await fixtureClient.client.mailAccounts()

        #expect(first.first?.emailAddress == "test@example.com")
        #expect(second.first?.emailAddress == "second@example.com")
    }

    @Test("A scripted box page answers with the page and records what was asked for")
    func scriptedBoxPageAnswers() async throws {
        let pageSize = try #require(PageSize(50))
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.boxPage, fixture: "imbox.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        let page = try await fixtureClient.client.boxPage(.imbox, pageSize: pageSize)

        #expect(page.postings.count == 50)
        #expect(page.postings.first?.subject == "Test subject 1")
        #expect(page.nextCursor != nil)
        #expect(
            fixtureClient.recordedInvocations
                == [.boxPage(kind: .imbox, pageSize: pageSize, cursor: nil)]
        )
        #expect(await invocations.next() == .boxPage(kind: .imbox, pageSize: pageSize, cursor: nil))
    }

    @Test("A scripted page with a refused row answers with the rest of the page and the count")
    func scriptedBoxPageCountsARefusedRow() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(
            .boxPage,
            standardOutput: try FixtureJSON.removing(
                "app_url",
                at: .firstSinglePosting,
                from: try HEYFixtures.data(named: "imbox.json")
            )
        )

        let page = try await fixtureClient.client.boxPage(.imbox)

        #expect(page.postings.count == 49)
        #expect(page.refusedRowCount == 1)
    }

    @Test("A scripted page's cursor comes back on the invocation that used it")
    func scriptedBoxPageCarriesTheCursorItWasCalledWith() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.boxPage, fixture: "imbox-page-1.json")
        try fixtureClient.script(.boxPage, fixture: "imbox-page-2.json")

        let first = try await fixtureClient.client.boxPage(.imbox)
        let cursor = try #require(first.nextCursor)
        let second = try await fixtureClient.client.boxPage(.feedbox, cursor: cursor)

        #expect(second.postings.count == 30)
        #expect(
            fixtureClient.recordedInvocations
                == [
                    .boxPage(kind: .imbox, pageSize: .minimum, cursor: nil),
                    .boxPage(kind: .feedbox, pageSize: .minimum, cursor: cursor),
                ]
        )
    }

    @Test("A scripted move confirms and records the postings and the box it was given")
    func scriptedMoveConfirms() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.move, fixture: "mutation-move.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()
        let postingIDs = NonEmptySet(Posting.ID(1), Posting.ID(2))

        try await fixtureClient.client.move(postingIDs, to: .laterbox)

        #expect(
            fixtureClient.recordedInvocations == [.move(postingIDs: postingIDs, to: .laterbox)]
        )
        #expect(await invocations.next() == .move(postingIDs: postingIDs, to: .laterbox))
    }

    @Test("A scripted seen change confirms and records the postings it was given")
    func scriptedSeenChangesConfirm() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.markSeen, fixture: "mutation-seen.json")
        try fixtureClient.script(.markUnseen, fixture: "mutation-seen.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()
        let postingIDs = NonEmptySet(Posting.ID(7))

        try await fixtureClient.client.markSeen(postingIDs)
        try await fixtureClient.client.markUnseen(postingIDs)

        #expect(
            fixtureClient.recordedInvocations
                == [.markSeen(postingIDs: postingIDs), .markUnseen(postingIDs: postingIDs)]
        )
        #expect(await invocations.next() == .markSeen(postingIDs: postingIDs))
        #expect(await invocations.next() == .markUnseen(postingIDs: postingIDs))
    }

    @Test("A mutation nobody scripted fails and says which one")
    func unscriptedMutationFails() async throws {
        let fixtureClient = HEYFixtureClient()
        let postingIDs = NonEmptySet(Posting.ID(1))

        await #expect(throws: HEYFixtureClientError.notScripted(.move)) {
            try await fixtureClient.client.move(postingIDs, to: .asidebox)
        }
    }

    @Test("A mutation scripted with an error envelope throws the mapped error")
    func scriptedMutationErrorMaps() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.markSeen, fixture: "error-not-found.json", exitCode: 2)
        let postingIDs = NonEmptySet(Posting.ID(1))

        do {
            try await fixtureClient.client.markSeen(postingIDs)
            Issue.record("The mutation was expected to fail but confirmed.")
        } catch let HEYCliKitError.notFound(details) {
            #expect(details.code == "not_found")
            #expect(details.message == "resource not found")
        }
    }

    @Test("An operation that was not scripted fails and says which one")
    func unscriptedOperationFails() async throws {
        let fixtureClient = HEYFixtureClient()

        await #expect(throws: HEYFixtureClientError.notScripted(.signInStatus)) {
            _ = try await fixtureClient.client.signInStatus()
        }
        #expect(
            HEYFixtureClientError.notScripted(.mailAccounts).description
                .contains("mailAccounts")
        )
    }

    @Test("A scripted error envelope goes through the package's own error mapping")
    func scriptedErrorEnvelopeMaps() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.signInStatus, fixture: "error-auth.json", exitCode: 3)

        do {
            _ = try await fixtureClient.client.signInStatus()
            Issue.record("The operation was expected to fail but returned a value.")
        } catch let HEYCliKitError.signedOut(details) {
            #expect(details.code == "auth")
            #expect(details.hint == "Run: hey auth login")
        }
    }

    @Test("Stderr scripted alongside a fixture reaches the process failure")
    func scriptedStandardErrorReachesTheFailure() async throws {
        let fixtureClient = HEYFixtureClient()
        // Stdout that is not an envelope at a failing exit code is the one case
        // that hands an app what the CLI wrote on stderr.
        try fixtureClient.script(
            .version,
            fixture: "screener-count.txt",
            exitCode: 1,
            standardError: "hey: something went wrong\n"
        )

        do {
            _ = try await fixtureClient.client.version()
            Issue.record("The operation was expected to fail but returned a value.")
        } catch let HEYCliKitError.processFailure(failure) {
            #expect(failure.standardError == "hey: something went wrong\n")
            #expect(failure.reason == nil)
        }
    }

    @Test("A scripted failure is thrown as it was given")
    func scriptedFailureIsThrown() async throws {
        struct StagedFailure: Error, Equatable {}

        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(.version, failing: StagedFailure())

        await #expect(throws: StagedFailure()) {
            _ = try await fixtureClient.client.version()
        }
    }

    @Test("Every call is recorded in order, whether or not it was scripted")
    func invocationsAreRecorded() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.version, fixture: "version.json")

        _ = try await fixtureClient.client.version()
        _ = try? await fixtureClient.client.mailAccounts()

        #expect(fixtureClient.recordedInvocations == [.version, .mailAccounts])
        #expect(fixtureClient.recordedInvocations.map(\.operation) == [.version, .mailAccounts])
    }

    @Test("A test can await the invocation stream to see what was asked")
    func invocationStreamYieldsEveryCall() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.version, fixture: "version.json")
        try fixtureClient.script(.signInStatus, fixture: "auth-status.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        _ = try await fixtureClient.client.version()
        _ = try await fixtureClient.client.signInStatus()

        #expect(await invocations.next() == .version)
        #expect(await invocations.next() == .signInStatus)
    }

    @Test("The invocation stream ends when the fixture client goes away")
    func invocationStreamEndsWithTheFixtureClient() async throws {
        var fixtureClient: HEYFixtureClient? = HEYFixtureClient()
        let invocations = try #require(fixtureClient?.invocations)
        fixtureClient = nil

        // A stream that never ends would hang the whole suite here, so the read is
        // raced against a sleep and nil stands for the stream that did not finish.
        let seen = await withTaskGroup(of: [HEYClientInvocation]?.self) { group in
            group.addTask {
                var seen: [HEYClientInvocation] = []
                for await invocation in invocations {
                    seen.append(invocation)
                }

                return seen
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))

                return nil
            }

            let first = await group.next()
            group.cancelAll()

            return first ?? nil
        }

        #expect(seen != nil, "The invocation stream did not end within two seconds.")
        #expect(seen?.isEmpty == true)
    }

    @Test("The Screener answers from a scripted fixture with its total count")
    func scriptedScreenerCarriesItsTotalCount() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.screener, fixture: "screener.json")

        let screener = try await fixtureClient.client.screener()

        #expect(screener.totalCount == 1)
        #expect(screener.entries.first?.emailAddress == "test1@example.com")
    }

    @Test("A scripted decision comes back with the outcome HEY confirmed")
    func scriptedDecisionsDecode() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.approveScreenerEntries, fixture: "screener-approve.json")
        try fixtureClient.script(.denyScreenerEntries, fixture: "screener-deny.json")

        let approvals = try await fixtureClient.client.approveScreenerEntries(
            ScreenerApproval(entryIDs: NonEmptySet(anEntryID))
        )
        let denials = try await fixtureClient.client.denyScreenerEntries(NonEmptySet(anEntryID))

        #expect(approvals.map(\.outcome) == [.approved])
        #expect(denials.map(\.outcome) == [.denied])
    }

    @Test("An approve that was not scripted fails and names the approve operation")
    func unscriptedApproveFails() async throws {
        let fixtureClient = HEYFixtureClient()

        await #expect(throws: HEYFixtureClientError.notScripted(.approveScreenerEntries)) {
            _ = try await fixtureClient.client.approveScreenerEntries(
                ScreenerApproval(entryIDs: NonEmptySet(anEntryID))
            )
        }
    }

    @Test("A recorded decision invocation carries what was asked, not how it was spawned")
    func decisionInvocationsCarryTheirParameters() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.approveScreenerEntries, fixture: "screener-approve.json")
        try fixtureClient.script(.denyScreenerEntries, fixture: "screener-deny.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()
        let approval = ScreenerApproval(
            entryIDs: NonEmptySet(anEntryID, ScreenerEntry.ID(100_003)),
            destination: .trailbox,
            markSeen: true
        )

        _ = try await fixtureClient.client.approveScreenerEntries(approval)
        _ = try await fixtureClient.client.denyScreenerEntries(NonEmptySet(anEntryID))

        #expect(await invocations.next() == .approveScreenerEntries(approval))
        #expect(await invocations.next() == .denyScreenerEntries(NonEmptySet(anEntryID)))
        #expect(
            fixtureClient.recordedInvocations
                == [.approveScreenerEntries(approval), .denyScreenerEntries(NonEmptySet(anEntryID))]
        )
        #expect(
            fixtureClient.recordedInvocations.map(\.operation)
                == [.approveScreenerEntries, .denyScreenerEntries]
        )
    }

    @Test("A scripted ndjson fixture replays as a watch, one line per element")
    func scriptedWatchReplaysItsFixture() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.watch, fixture: "watch-session.ndjson")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        var decoded: [WatchLine] = []
        for try await line in try await fixtureClient.client.watch(NonEmptySet(.imbox)) {
            decoded.append(line)
        }

        #expect(decoded.count == 28)
        #expect(
            fixtureClient.recordedInvocations
                == [.watch(boxKinds: NonEmptySet(.imbox), since: nil)]
        )
        #expect(await invocations.next() == .watch(boxKinds: NonEmptySet(.imbox), since: nil))
    }

    @Test("A scripted added line whose posting is of an unknown kind replays as a change")
    func scriptedWatchReplaysAnOtherPosting() async throws {
        let fixtureClient = HEYFixtureClient()
        let captured = try FixtureJSON.line(.newMailArrival, ofFixtureNamed: "watch-session.ndjson")
        fixtureClient.script(
            .watch,
            standardOutput: try FixtureJSON.replacing(
                "kind",
                with: "parcel",
                at: .watchLinePosting,
                in: captured
            )
        )

        var decoded: [WatchLine] = []
        for try await line in try await fixtureClient.client.watch(NonEmptySet(.imbox)) {
            decoded.append(line)
        }

        #expect(decoded.count == 1)
        guard case let .added(change) = try #require(decoded.first) else {
            Issue.record("The line was expected to be an added change.")
            return
        }
        guard case let .other(posting) = change.posting else {
            Issue.record("The change was expected to carry an other posting.")
            return
        }
        #expect(posting.kind == "parcel")
        #expect(posting.id == Posting.ID(100_002))
    }

    @Test("A watch scripted with an error envelope at exit 3 ends signed out")
    func scriptedWatchErrorEndsSignedOut() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.watch, fixture: "error-auth.json", exitCode: 3)

        do {
            for try await _ in try await fixtureClient.client.watch(NonEmptySet(.imbox)) {}
            Issue.record("The watch was expected to end signed out.")
        } catch let HEYCliKitError.signedOut(details) {
            #expect(details.code == "auth")
            #expect(details.hint == "Run: hey auth login")
        }
    }

    @Test("A watch nobody scripted fails at the call and names the watch operation")
    func unscriptedWatchFails() async throws {
        let fixtureClient = HEYFixtureClient()

        await #expect(throws: HEYFixtureClientError.notScripted(.watch)) {
            _ = try await fixtureClient.client.watch(NonEmptySet(.imbox), since: Date())
        }
    }

    @Test("A scripted login outcome resolves at once and records the call")
    func scriptedLoginResolves() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(login: .completed)
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        let handle = try await fixtureClient.client.login()

        #expect(await handle.outcome == .completed)
        #expect(fixtureClient.recordedInvocations == [.login])
        #expect(await invocations.next() == .login)
    }

    @Test("A login scripted as waiting resolves when the app cancels it, as the CLI does")
    func scriptedLoginWaitsForCancel() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.scriptLoginWaitingForCancel()

        let handle = try await fixtureClient.client.login()
        // The call itself returns, which is what a login that opens a browser does.
        // Nothing is asserted about the wait: how long the CLI would have waited is
        // not something a test can ask, and there is no timeout to reach anyway.
        #expect(fixtureClient.recordedInvocations == [.login])

        handle.cancel()

        #expect(await handle.outcome == .notCompleted(terminatedLogin))
    }

    @Test(
        "A login scripted as envelope bytes ends the way the exit code says",
        arguments: [
            (Int32(0), LoginOutcome.completed),
            (
                143,
                .notCompleted(
                    LoginFailure(exitStatus: .exited(143), standardError: loginProgress)
                )
            ),
        ]
    )
    func scriptedLoginBytesMapByExitCode(exitCode: Int32, outcome: LoginOutcome) async throws {
        let fixtureClient = HEYFixtureClient()
        // The envelope the CLI prints on a completed sign in, captured in the app
        // repository's spawn transcript rather than shipped as a fixture, since it
        // takes signing a machine in to produce one. Login never reads it: the exit
        // code alone decides, which is what these two cases show.
        fixtureClient.script(
            .login,
            standardOutput: Data(
                """
                {
                  "ok": true,
                  "data": { "method": "oauth" },
                  "summary": "Logged in successfully"
                }
                """.utf8
            ),
            exitCode: exitCode,
            standardError: loginProgress
        )

        let handle = try await fixtureClient.client.login()

        #expect(await handle.outcome == outcome)
    }

    @Test(
        "A login scripted as not completed resolves at once with that kind",
        arguments: LoginFailure.Kind.allCases
    )
    func scriptedLoginNotCompletedCarriesItsKind(kind: LoginFailure.Kind) async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(loginNotCompleted: kind)

        let handle = try await fixtureClient.client.login()

        guard case let .notCompleted(failure) = await handle.outcome else {
            Issue.record("A login scripted as not completed was reported completed")
            return
        }
        #expect(failure.kind == kind)
        #expect(fixtureClient.recordedInvocations == [.login])
        // The ending is one the CLI could have come to, never the sign in address
        // it prints on the way: a consumer's test must not ship an install id.
        #expect(failure.standardError.contains("install_id") == false)
        #expect(failure.standardError.contains("https://") == false)

        switch kind {
        case .timedOut, .accessDenied, .notClassified:
            // Shaped as the CLI shapes it and classified by the package's own rule,
            // so the same ending built from its bytes alone reads the same kind. The
            // one not classified is the CLI's own failed envelope around an error
            // the package has no name for, not an ending made up for the fixture.
            #expect(failure.exitStatus == .exited(3))
            #expect(failure.standardError.contains(#""code": "auth""#))
            #expect(
                LoginFailure(exitStatus: failure.exitStatus, standardError: failure.standardError)
                    .kind == kind
            )
        case .cancelled:
            #expect(failure == terminatedLogin)
        }
    }

    @Test("A login scripted as envelope bytes is classified the way the live client classifies it")
    func scriptedLoginBytesAreClassified() async throws {
        let fixtureClient = HEYFixtureClient()
        // The failed envelope goes to stderr, after the progress lines, and stdout
        // carries nothing, which is how the CLI ends a sign in that timed out.
        fixtureClient.script(
            .login,
            standardOutput: Data(),
            exitCode: 3,
            standardError: signInStandardError(failingWith: "authentication timeout")
        )

        let handle = try await fixtureClient.client.login()

        guard case let .notCompleted(failure) = await handle.outcome else {
            Issue.record("A login scripted to exit 3 was reported completed")
            return
        }
        #expect(failure.kind == .timedOut)
    }

    @Test("A login nobody scripted fails at the call and names the login operation")
    func unscriptedLoginFails() async throws {
        let fixtureClient = HEYFixtureClient()

        await #expect(throws: HEYFixtureClientError.notScripted(.login)) {
            _ = try await fixtureClient.client.login()
        }
    }

    @Test("A scripted logout confirms and records the call")
    func scriptedLogoutConfirms() async throws {
        let fixtureClient = HEYFixtureClient()
        // Logout has no captured envelope either, for the same reason, so this is
        // the shape of a confirmation rather than one the CLI was seen printing.
        fixtureClient.script(
            .logout,
            standardOutput: Data(#"{"ok": true, "summary": "Logged out"}"#.utf8)
        )
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        try await fixtureClient.client.logout()

        #expect(fixtureClient.recordedInvocations == [.logout])
        #expect(await invocations.next() == .logout)
    }

    @Test("A logout the CLI answers signed out throws, since there was nothing to sign out of")
    func scriptedLogoutSignedOutThrows() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.logout, fixture: "error-auth.json", exitCode: 3)

        do {
            try await fixtureClient.client.logout()
            Issue.record("The logout was expected to fail but confirmed.")
        } catch let HEYCliKitError.signedOut(details) {
            #expect(details.code == "auth")
        }
    }

    @Test("Every operation has a queue of its own")
    func everyOperationHasAQueue() async throws {
        let fixtureClient = HEYFixtureClient()

        // Every operation is called on a fixture client that scripted nothing, so
        // each one has to fail for itself. The call goes through `perform`, whose
        // switch has no default on purpose: an operation added to the client fails
        // to compile until it is covered.
        for operation in HEYClientOperation.allCases {
            let empty = HEYFixtureClient()

            await #expect(throws: HEYFixtureClientError.notScripted(operation)) {
                try await perform(operation, on: empty.client)
            }
        }

        try fixtureClient.script(.signInStatus, fixture: "auth-status.json")

        let status = try await fixtureClient.client.signInStatus()

        #expect(status.isSignedIn)
        await #expect(throws: HEYFixtureClientError.notScripted(.version)) {
            _ = try await fixtureClient.client.version()
        }
    }

    @Test("A repeating answer answers every call and is never used up")
    func repeatingAnswerIsNeverUsedUp() async throws {
        let fixtureClient = HEYFixtureClient()
        // The Screener an app polls on a timer, scripted once for however many
        // ticks the test happens to take.
        try fixtureClient.scriptRepeating(.screener, fixture: "screener.json")

        let counts = try await [
            fixtureClient.client.screener().totalCount,
            fixtureClient.client.screener().totalCount,
            fixtureClient.client.screener().totalCount,
        ]

        #expect(counts == [1, 1, 1])
    }

    @Test("Queued answers come first, and the repeating one only once the queue is empty")
    func queuedAnswersComeBeforeTheRepeatingOne() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.scriptRepeating(.screener, fixture: "screener-empty.json")
        try fixtureClient.script(.screener, fixture: "screener.json")

        let counts = try await [
            fixtureClient.client.screener().totalCount,
            fixtureClient.client.screener().totalCount,
            fixtureClient.client.screener().totalCount,
        ]

        #expect(counts == [1, 0, 0])
    }

    @Test("Scripting a repeating answer twice replaces it rather than queueing behind it")
    func scriptingARepeatingAnswerTwiceReplacesIt() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.scriptRepeating(.mailAccounts, fixture: "accounts.json")
        fixtureClient.scriptRepeating(
            .mailAccounts,
            standardOutput: Data(
                """
                {
                  "ok": true,
                  "data": [
                    {
                      "id": "654321",
                      "name": "Second User",
                      "email": "second@example.com",
                      "purpose": "work",
                      "status": "active"
                    }
                  ]
                }
                """.utf8
            )
        )

        let first = try await fixtureClient.client.mailAccounts()
        let second = try await fixtureClient.client.mailAccounts()

        // The replaced answer is gone rather than waiting its turn, so neither
        // call sees it.
        #expect(first.first?.emailAddress == "second@example.com")
        #expect(second.first?.emailAddress == "second@example.com")
    }

    @Test("A repeating answer answers its own operation and leaves every other one failing")
    func repeatingAnswerIsPerOperation() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.scriptRepeating(.version, fixture: "version.json")

        let version = try await fixtureClient.client.version()

        #expect(version.version == "1.4.0")
        await #expect(throws: HEYFixtureClientError.notScripted(.mailAccounts)) {
            _ = try await fixtureClient.client.mailAccounts()
        }
        await #expect(throws: HEYFixtureClientError.notScripted(.signInStatus)) {
            _ = try await fixtureClient.client.signInStatus()
        }
    }

    @Test("Every call a repeating answer serves is still recorded and yielded")
    func repeatingAnswersAreStillRecorded() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.scriptRepeating(.version, fixture: "version.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        _ = try await fixtureClient.client.version()
        _ = try await fixtureClient.client.version()

        #expect(fixtureClient.recordedInvocations == [.version, .version])
        #expect(await invocations.next() == .version)
        #expect(await invocations.next() == .version)
    }

    @Test("A repeating failure is thrown as it was given, on every call")
    func repeatingFailureIsThrownEveryTime() async throws {
        struct StagedFailure: Error, Equatable {}

        let fixtureClient = HEYFixtureClient()
        fixtureClient.scriptRepeating(.version, failing: StagedFailure())

        await #expect(throws: StagedFailure()) {
            _ = try await fixtureClient.client.version()
        }
        await #expect(throws: StagedFailure()) {
            _ = try await fixtureClient.client.version()
        }
    }

    @Test("A repeating watch replays its fixture every time it is started")
    func repeatingWatchReplaysEveryTime() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.scriptRepeating(.watch, fixture: "watch-session.ndjson")

        // A watch that ends and is started again is what an app does when the CLI
        // exits under it, so the fallback has to answer the second start too.
        var counts: [Int] = []
        for _ in 1...2 {
            var decoded: [WatchLine] = []
            for try await line in try await fixtureClient.client.watch(NonEmptySet(.imbox)) {
                decoded.append(line)
            }

            counts.append(decoded.count)
        }

        #expect(counts == [28, 28])
    }

    @Test("A repeating mutation confirms every time, behind the queued answer it was given")
    func repeatingMutationConfirmsEveryTime() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.scriptRepeating(.markSeen, fixture: "mutation-seen.json")
        try fixtureClient.script(.markSeen, fixture: "error-not-found.json", exitCode: 2)
        let postingIDs = NonEmptySet(Posting.ID(7))

        await #expect(throws: HEYCliKitError.self) {
            try await fixtureClient.client.markSeen(postingIDs)
        }
        try await fixtureClient.client.markSeen(postingIDs)
        try await fixtureClient.client.markSeen(postingIDs)

        #expect(
            fixtureClient.recordedInvocations
                == Array(repeating: .markSeen(postingIDs: postingIDs), count: 3)
        )
    }

    @Test("A failing watch yields every line of its fixture, then throws from the stream")
    func failingWatchYieldsItsLinesThenThrows() async throws {
        let plain = HEYFixtureClient()
        try plain.script(.watch, fixture: "watch-session.ndjson")
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(
            watchFixture: "watch-session.ndjson",
            thenFailing: HEYCliKitError.watchFellBehind(limitInLines: 1024)
        )

        let expected = await readWatch(on: plain.client)
        let reading = await readWatch(on: fixtureClient.client)

        // The call that opened the watch handed back a stream, and the stream only
        // threw once all 28 lines had been read from it, decoded exactly as the
        // same fixture decodes when it is scripted plainly.
        #expect(reading.openingError == nil)
        #expect(reading.lines.count == 28)
        #expect(reading.lines == expected.lines)
        #expect(
            reading.streamError as? HEYCliKitError == .watchFellBehind(limitInLines: 1024)
        )
    }

    @Test("A failing watch scripted as bytes yields an unrecognised line, then throws")
    func failingWatchFromBytesYieldsItsLinesThenThrows() async throws {
        let standardOutput = Data(
            """
            {"change":"ready","at":"2026-09-03T23:46:10.883Z"}
            hey: this is not JSON at all

            """.utf8
        )
        let plain = HEYFixtureClient()
        plain.script(.watch, standardOutput: standardOutput)
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(
            watchStandardOutput: standardOutput,
            thenFailing: HEYCliKitError.lineTooLarge(limitInBytes: 65_536)
        )

        let expected = await readWatch(on: plain.client)
        let reading = await readWatch(on: fixtureClient.client)

        #expect(reading.openingError == nil)
        #expect(reading.lines == expected.lines)
        #expect(reading.lines.count == 2)
        #expect(reading.lines.last == .unrecognized(rawText: "hey: this is not JSON at all"))
        #expect(reading.streamError as? HEYCliKitError == .lineTooLarge(limitInBytes: 65_536))
    }

    @Test("A failing watch throws a cancellation as it was given, from the stream")
    func failingWatchPassesACancellationThrough() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(
            watchStandardOutput: Data("hey: this is not JSON at all\n".utf8),
            thenFailing: CancellationError()
        )

        let reading = await readWatch(on: fixtureClient.client)

        #expect(reading.openingError == nil)
        #expect(reading.lines == [.unrecognized(rawText: "hey: this is not JSON at all")])
        #expect(reading.streamError is CancellationError)
    }

    @Test("A failing watch is recorded and yielded like any other watch")
    func failingWatchIsRecorded() async throws {
        let since = Date(timeIntervalSince1970: 1_788_476_400)
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(
            watchFixture: "watch-idle-imbox.ndjson",
            thenFailing: HEYCliKitError.watchFellBehind(limitInLines: 1024)
        )
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        let lines = try await fixtureClient.client.watch(NonEmptySet(.feedbox, .imbox), since: since)

        let invocation = HEYClientInvocation.watch(
            boxKinds: NonEmptySet(.feedbox, .imbox),
            since: since
        )
        #expect(fixtureClient.recordedInvocations == [invocation])
        #expect(await invocations.next() == invocation)
        await #expect(throws: HEYCliKitError.watchFellBehind(limitInLines: 1024)) {
            for try await _ in lines {}
        }
    }

    @Test("A failing watch from a fixture that is not shipped fails and queues nothing")
    func failingWatchFromAMissingFixtureFails() async throws {
        let fixtureClient = HEYFixtureClient()

        // The queued spelling leaves the queue empty and no fallback behind it.
        #expect(throws: HEYFixtureError.missing("no-such-watch.ndjson")) {
            try fixtureClient.script(
                watchFixture: "no-such-watch.ndjson",
                thenFailing: HEYCliKitError.watchFellBehind(limitInLines: 1024)
            )
        }

        let unscripted = await readWatch(on: fixtureClient.client)

        #expect(unscripted.openingError as? HEYFixtureClientError == .notScripted(.watch))

        // The repeating spelling leaves the fallback that was already there.
        try fixtureClient.scriptRepeating(.watch, fixture: "watch-idle-imbox.ndjson")
        let expected = await readWatch(on: fixtureClient.client)
        #expect(throws: HEYFixtureError.missing("no-such-watch.ndjson")) {
            try fixtureClient.scriptRepeating(
                watchFixture: "no-such-watch.ndjson",
                thenFailing: HEYCliKitError.watchFellBehind(limitInLines: 1024)
            )
        }

        let reading = await readWatch(on: fixtureClient.client)

        #expect(reading.openingError == nil)
        #expect(reading.lines.count == 8)
        #expect(reading.lines == expected.lines)
        #expect(reading.streamError == nil)
    }

    @Test("A repeating failing watch answers every start once the queued watch is used")
    func repeatingFailingWatchAnswersEveryStart() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.scriptRepeating(
            watchFixture: "watch-session.ndjson",
            thenFailing: HEYCliKitError.watchFellBehind(limitInLines: 1024)
        )
        try fixtureClient.script(.watch, fixture: "watch-idle-imbox.ndjson")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        // An app that starts its watch again every time one fails, started once
        // for the queued watch that ends cleanly and three times after it.
        var readings: [WatchReading] = []
        for _ in 1...4 {
            readings.append(await readWatch(on: fixtureClient.client))
        }

        #expect(readings.map(\.lines.count) == [8, 28, 28, 28])
        #expect(readings.allSatisfy { $0.openingError == nil })
        #expect(readings[0].streamError == nil)
        #expect(
            readings.dropFirst().map { $0.streamError as? HEYCliKitError }
                == Array(repeating: .watchFellBehind(limitInLines: 1024), count: 3)
        )
        let invocation = HEYClientInvocation.watch(boxKinds: NonEmptySet(.imbox), since: nil)
        #expect(fixtureClient.recordedInvocations == Array(repeating: invocation, count: 4))
        for _ in 1...4 {
            #expect(await invocations.next() == invocation)
        }
    }

    @Test("A repeating failing watch replaces the watch's fallback and is replaced in turn")
    func repeatingFailingWatchReplacesTheFallback() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.scriptRepeating(.watch, fixture: "watch-session.ndjson")
        fixtureClient.scriptRepeating(
            watchStandardOutput: Data("hey: this is not JSON at all\n".utf8),
            thenFailing: HEYCliKitError.outputTooLarge(limitInBytes: 33_554_432)
        )

        let first = await readWatch(on: fixtureClient.client)
        let second = await readWatch(on: fixtureClient.client)
        try fixtureClient.scriptRepeating(.watch, fixture: "watch-idle-imbox.ndjson")
        let third = await readWatch(on: fixtureClient.client)

        for reading in [first, second] {
            #expect(reading.lines == [.unrecognized(rawText: "hey: this is not JSON at all")])
            #expect(
                reading.streamError as? HEYCliKitError
                    == .outputTooLarge(limitInBytes: 33_554_432)
            )
        }
        #expect(third.lines.count == 8)
        #expect(third.streamError == nil)
    }
}

/// One watch read to its end, with where it failed, if it did.
private struct WatchReading {
    var lines: [WatchLine] = []
    /// What the call that opens the watch threw, which leaves no stream to read.
    var openingError: (any Error)?
    /// What the stream threw after its lines.
    var streamError: (any Error)?
}

/// Opens a watch on the Imbox and reads every line it yields, keeping a throw
/// from the opening call apart from a throw from the stream.
private func readWatch(on client: HEYClient) async -> WatchReading {
    var reading = WatchReading()
    let lines: AsyncThrowingStream<WatchLine, any Error>
    do {
        lines = try await client.watch(NonEmptySet(.imbox))
    } catch {
        reading.openingError = error

        return reading
    }

    do {
        for try await line in lines {
            reading.lines.append(line)
        }
    } catch {
        reading.streamError = error
    }

    return reading
}

/// The entry the Screener fixtures were captured with.
private let anEntryID = ScreenerEntry.ID(100_001)

/// A sign in the app stopped, as the handle reports it.
private let terminatedLogin = LoginFailure(
    exitStatus: .signaled(SIGTERM),
    standardError: "",
    kind: .cancelled
)

/// What the CLI prints on stderr while it waits for the browser.
private let loginProgress = "Waiting for authentication...\n"
