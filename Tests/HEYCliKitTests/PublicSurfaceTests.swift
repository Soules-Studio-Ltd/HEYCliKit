import Foundation
import Testing

import HEYCliKit
import HEYCliKitTestSupport

/// Everything here compiles against the public API exactly as an app sees it: no
/// `@testable` import, so an operation or a type that leaks an internal detail
/// fails to build. Every operation is called through its method, which is the one
/// spelling an app has, because the closures behind the methods are `package`.
///
/// That last part is the one thing this suite cannot assert. It is a test target
/// of the same package, so a `package` declaration is visible to it and a call to
/// a closure would compile here even though it would not compile in an app. What
/// the suite does prove is that no operation needs a spelling beside its method.
/// The live client is only ever built here, never run.
@Suite("Public surface")
struct PublicSurfaceTests {
    @Test("A live client is built from an executable location alone")
    func liveClientTakesAnExecutable() {
        let client = HEYClient.live(executable: URL(filePath: "/usr/local/bin/hey"))

        #expect(type(of: client) == HEYClient.self)
    }

    @Test("A live client takes an account selection and extra environment")
    func liveClientTakesASelectionAndEnvironment() {
        let client = HEYClient.live(
            executable: URL(filePath: "/usr/local/bin/hey"),
            accountSelection: .mailAccount(MailAccount.ID("123456")),
            environment: ["HEY_CLI_KIT_TEST": "yes"]
        )

        #expect(type(of: client) == HEYClient.self)
    }

    @Test("A fixture client answers the same client type the live constructor builds")
    func fixtureClientBuildsTheSameClient() async throws {
        let live = HEYClient.live(executable: URL(filePath: "/usr/local/bin/hey"))
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.signInStatus, fixture: "auth-status.json")

        let status = try await fixtureClient.client.signInStatus()

        #expect(type(of: fixtureClient.client) == type(of: live))
        #expect(status.isSignedIn)
        #expect(status.isExpired == false)
        #expect(fixtureClient.recordedInvocations == [.signInStatus])
    }

    @Test("An approval is built from entry ids alone, with the package's own defaults")
    func approvalTakesItsDefaults() async throws {
        // This is the call an app writes for the common case: let this sender
        // through, wherever HEY would have put them, without touching what they
        // already sent.
        let approval = ScreenerApproval(entryIDs: NonEmptySet(ScreenerEntry.ID(100_001)))
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.approveScreenerEntries, fixture: "screener-approve.json")

        let decisions = try await fixtureClient.client.approveScreenerEntries(approval)

        #expect(approval.destination == .imbox)
        #expect(approval.markSeen == false)
        #expect(approval.entryIDs.count == 1)
        #expect(decisions.first?.outcome == .approved)
        #expect(fixtureClient.recordedInvocations == [.approveScreenerEntries(approval)])
    }

    @Test("A set of ids is built from an array through its label, and an empty array builds nothing")
    func nonEmptySetIsBuiltFromAnArrayThroughItsLabel() throws {
        // The array an app holds, say the postings a person selected, written with
        // the label and no element type, exactly as an app would write it.
        let selected = [Posting.ID(3), Posting.ID(1), Posting.ID(3), Posting.ID(2)]
        let noneSelected: [Posting.ID] = []

        let postingIDs = try #require(NonEmptySet(elements: selected))

        #expect(postingIDs.elements == [Posting.ID(3), Posting.ID(1), Posting.ID(2)])
        #expect(NonEmptySet(elements: noneSelected) == nil)
    }

    @Test("A box page is read through the public API alone")
    func boxPageIsPublic() async throws {
        let pageSize = try #require(PageSize(40))
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.boxPage, fixture: "imbox.json")
        try fixtureClient.script(.boxPage, fixture: "imbox-page-2.json")

        let page = try await fixtureClient.client.boxPage(.imbox, pageSize: pageSize)
        let cursor = try #require(page.nextCursor)
        // The second read passes both of the method's defaulted parameters, so a
        // page after the first is read the way an app reads one.
        let next = try await fixtureClient.client.boxPage(
            .laterbox,
            pageSize: .minimum,
            cursor: cursor
        )

        #expect(page.postings.count == 50)
        #expect(next.postings.count == 30)
        #expect(page.postings.first?.sender.name == "Test contact 2")
        #expect(page.postings.first?.isSeen == false)
        #expect(
            fixtureClient.recordedInvocations
                == [
                    .boxPage(kind: .imbox, pageSize: pageSize, cursor: nil),
                    .boxPage(kind: .laterbox, pageSize: .minimum, cursor: cursor),
                ]
        )
    }

    @Test("A mutation is made through the public API alone")
    func mutationsArePublic() async throws {
        let postingIDs = NonEmptySet(Posting.ID(1), Posting.ID(2))
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.move, fixture: "mutation-move.json")
        try fixtureClient.script(.move, fixture: "mutation-move.json")
        try fixtureClient.script(.markSeen, fixture: "mutation-seen.json")
        try fixtureClient.script(.markUnseen, fixture: "mutation-seen.json")

        try await fixtureClient.client.move(postingIDs, to: .laterbox)
        try await fixtureClient.client.move(postingIDs, to: .asidebox)
        try await fixtureClient.client.markSeen(postingIDs)
        try await fixtureClient.client.markUnseen(postingIDs)

        #expect(
            fixtureClient.recordedInvocations
                == [
                    .move(postingIDs: postingIDs, to: .laterbox),
                    .move(postingIDs: postingIDs, to: .asidebox),
                    .markSeen(postingIDs: postingIDs),
                    .markUnseen(postingIDs: postingIDs),
                ]
        )
    }

    @Test("A watch is read through the public API alone")
    func watchIsPublic() async throws {
        let since = Date(timeIntervalSince1970: 1_788_476_400)
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.watch, fixture: "watch-bundle-growth.ndjson")
        try fixtureClient.script(.watch, fixture: "watch-session.ndjson")

        // One watch asks for what it missed and one does not, so the since date
        // and the default beside it are both exercised.
        var replayed: [WatchLine] = []
        let replay = try await fixtureClient.client.watch(NonEmptySet(.imbox), since: since)
        for try await line in replay {
            replayed.append(line)
        }
        var live: [WatchLine] = []
        for try await line in try await fixtureClient.client.watch(NonEmptySet(.feedbox, .imbox)) {
            live.append(line)
        }

        #expect(replayed.count == 27)
        #expect(live.count == 28)
        #expect(replayed.first?.isReplayed == true)
        #expect(live.first == .ready(at: try #require(live.first?.at)))
        #expect(
            fixtureClient.recordedInvocations
                == [
                    .watch(boxKinds: NonEmptySet(.imbox), since: since),
                    .watch(boxKinds: NonEmptySet(.feedbox, .imbox), since: nil),
                ]
        )
    }

    @Test("A watch line the package cannot read is matched on by its public case")
    func unrecognizedWatchLineIsPublic() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(.watch, standardOutput: Data("hey: this is not JSON at all\n".utf8))

        var rawTexts: [String] = []
        for try await line in try await fixtureClient.client.watch(NonEmptySet(.imbox)) {
            if case let .unrecognized(rawText: rawText) = line {
                rawTexts.append(rawText)
            }
        }

        #expect(rawTexts == ["hey: this is not JSON at all"])
    }

    @Test("A sign in is started, followed and stopped through the public API alone")
    func loginIsPublic() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(login: .completed)
        fixtureClient.scriptLoginWaitingForCancel()

        let completed: LoginHandle = try await fixtureClient.client.login()
        let outcome: LoginOutcome = await completed.outcome
        let cancelled = try await fixtureClient.client.login()
        cancelled.cancel()

        #expect(outcome == .completed)
        #expect(
            await cancelled.outcome
                == .notCompleted(
                    LoginFailure(
                        exitStatus: .signaled(SIGTERM),
                        standardError: "",
                        kind: .cancelled
                    )
                )
        )
        #expect(fixtureClient.recordedInvocations == [.login, .login])
    }

    @Test("Why a sign in was not completed is read and scripted through the public API alone")
    func loginFailureKindIsPublic() async throws {
        let fixtureClient = HEYFixtureClient()
        for kind in LoginFailure.Kind.allCases {
            fixtureClient.script(loginNotCompleted: kind)
        }

        var kinds: [String] = []
        for _ in LoginFailure.Kind.allCases {
            guard case let .notCompleted(failure) = try await fixtureClient.client.login().outcome
            else { continue }
            // The switch has no default on purpose: it is the check that these four
            // are every case an app has to name.
            switch failure.kind {
            case .timedOut: kinds.append("timed out")
            case .accessDenied: kinds.append("access denied")
            case .cancelled: kinds.append("cancelled")
            case .notClassified: kinds.append("not classified")
            }
        }

        let stated = LoginFailure(exitStatus: .exited(3), standardError: "", kind: .accessDenied)
        let hashed: Set<LoginFailure.Kind> = [stated.kind, .timedOut]

        // The description is public too, so an app can log a failure as it is.
        let described: any CustomStringConvertible = stated

        #expect(kinds == ["timed out", "access denied", "cancelled", "not classified"])
        #expect(hashed == [.accessDenied, .timedOut])
        #expect(described.description == "The sign in was declined (exit code 3).")
    }

    @Test("A sign in is cancelled and a held answer released by methods, not stored closures")
    func cancelAndReleaseAreMethods() {
        // An unapplied reference like these names a method and nothing else: the
        // same spelling against a stored closure does not build.
        let cancel: (LoginHandle) -> () -> Void = LoginHandle.cancel
        let release: (HEYHeldAnswer) -> () -> Void = HEYHeldAnswer.release

        _ = (cancel, release)
    }

    @Test(
        "A sign in's outcome awaited from two tasks is the same one",
        .timeLimit(.minutes(1))
    )
    func outcomeIsDecidedOnceForEveryAwaiter() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.scriptLoginWaitingForCancel()
        let handle = try await fixtureClient.client.login()

        let first = Task { await handle.outcome }
        let second = Task { await handle.outcome }
        handle.cancel()

        let terminated = LoginOutcome.notCompleted(
            LoginFailure(exitStatus: .signaled(SIGTERM), standardError: "", kind: .cancelled)
        )
        #expect(await first.value == terminated)
        #expect(await second.value == terminated)
        #expect(await handle.outcome == terminated)
    }

    @Test(
        "Cancelling the task that awaits a sign in's outcome cancels the sign in",
        .timeLimit(.minutes(1))
    )
    func cancellingTheAwaitingTaskCancelsTheSignIn() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.scriptLoginWaitingForCancel()
        let handle = try await fixtureClient.client.login()

        // A task already cancelled when it reaches the await runs the handler at
        // once, so nothing here depends on the task having parked first.
        let awaiting = Task { await handle.outcome }
        awaiting.cancel()

        let terminated = LoginOutcome.notCompleted(
            LoginFailure(exitStatus: .signaled(SIGTERM), standardError: "", kind: .cancelled)
        )
        #expect(await awaiting.value == terminated)
        #expect(await handle.outcome == terminated)
    }

    @Test("A sign out is made through the public API alone")
    func logoutIsPublic() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(
            .logout,
            standardOutput: Data(#"{"ok": true, "summary": "Logged out"}"#.utf8)
        )

        try await fixtureClient.client.logout()

        #expect(fixtureClient.recordedInvocations == [.logout])
    }

    @Test("A scripted error carries the CLI's own fields to the app that catches it")
    func scriptedErrorCarriesItsDetails() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.mailAccounts, fixture: "error-network.json", exitCode: 7)

        do {
            _ = try await fixtureClient.client.mailAccounts()
            Issue.record("The operation was expected to fail but returned a value.")
        } catch let HEYCliKitError.unreachableOrFailed(details) {
            #expect(details.code == "api")
            #expect(details.message?.isEmpty == false)
        }
    }

    @Test("An app builds the package's own error payloads and stages one as a failure")
    func errorPayloadsAreBuiltByTheApp() async throws {
        // The bundled executable that is not there: no exit code and no envelope
        // can say it, so scripted bytes cannot stage it and a built failure is the
        // only way an app reaches the case its own code has to present.
        let missingExecutable = ProcessFailure(
            exitStatus: nil,
            reason: "The bundled hey executable is missing from the app bundle."
        )
        let details = CLIErrorDetails(
            code: "auth",
            message: "Not logged in",
            hint: "Run: hey auth login"
        )
        let decodingFailure = DecodingFailure(
            description: "The stdout was not an envelope.",
            rawText: "<!doctype html>"
        )
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(.mailAccounts, failing: HEYCliKitError.processFailure(missingExecutable))

        await #expect(throws: HEYCliKitError.processFailure(missingExecutable)) {
            _ = try await fixtureClient.client.mailAccounts()
        }
        #expect(missingExecutable.standardError.isEmpty)
        #expect(HEYCliKitError.signedOut(details).description.contains("hint: Run: hey auth login"))
        #expect(
            HEYCliKitError.decodingFailure(decodingFailure)
                .description.contains("The stdout was not an envelope.")
        )
        #expect(decodingFailure.rawText == "<!doctype html>")
        // Details with nothing in them are a call an app can write, since every
        // field of an envelope's error is one the CLI need not have printed.
        #expect(CLIErrorDetails() == CLIErrorDetails(code: nil, message: nil, hint: nil))
        #expect(fixtureClient.recordedInvocations == [.mailAccounts])
    }

    @Test("An app builds the three ceiling failures, stages one, and reads each one's ceiling")
    func ceilingFailuresArePublic() async throws {
        let fixtureClient = HEYFixtureClient()
        fixtureClient.script(.boxPage, failing: HEYCliKitError.outputTooLarge(limitInBytes: 33_554_432))

        await #expect(throws: HEYCliKitError.outputTooLarge(limitInBytes: 33_554_432)) {
            _ = try await fixtureClient.client.boxPage(.imbox)
        }

        let failures: [HEYCliKitError] = [
            .outputTooLarge(limitInBytes: 33_554_432),
            .lineTooLarge(limitInBytes: 65_536),
            .watchFellBehind(limitInLines: 1024),
        ]

        // Each case is matched on by its own label and carries its own number,
        // which is what an app reads to say how far past the ceiling it went.
        var limits: [Int] = []
        for failure in failures {
            switch failure {
            case let .outputTooLarge(limitInBytes: limit): limits.append(limit)
            case let .lineTooLarge(limitInBytes: limit): limits.append(limit)
            case let .watchFellBehind(limitInLines: limit): limits.append(limit)
            default: Issue.record("\(failure) was expected to be a ceiling failure.")
            }
        }

        #expect(limits == [33_554_432, 65_536, 1024])
        #expect(failures[0].description.contains("33554432 bytes"))
        #expect(failures[1].description.contains("65536 bytes"))
        #expect(failures[2].description.contains("1024 lines"))
        #expect(fixtureClient.recordedInvocations == [.boxPage(kind: .imbox, pageSize: .minimum, cursor: nil)])
    }

    @Test("A watch that fails after its lines is scripted and read through the public API alone")
    func failingWatchIsPublic() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(
            watchFixture: "watch-idle-imbox.ndjson",
            thenFailing: HEYCliKitError.outputTooLarge(limitInBytes: 33_554_432)
        )
        try fixtureClient.scriptRepeating(
            watchFixture: "watch-session.ndjson",
            thenFailing: HEYCliKitError.watchFellBehind(limitInLines: 1024)
        )
        fixtureClient.scriptRepeating(
            watchStandardOutput: Data("hey: this is not JSON at all\n".utf8),
            thenFailing: HEYCliKitError.lineTooLarge(limitInBytes: 65_536)
        )

        // The opening call is made on its own line and outside the catch, so a
        // throw from it fails the test rather than passing as the stream's throw.
        var limits: [Int] = []
        var counts: [Int] = []
        for _ in 1...2 {
            let lines = try await fixtureClient.client.watch(NonEmptySet(.imbox))
            var count = 0
            do {
                for try await _ in lines {
                    count += 1
                }
                Issue.record("The watch was expected to fail after its lines.")
            } catch let HEYCliKitError.outputTooLarge(limitInBytes: limit) {
                limits.append(limit)
            } catch let HEYCliKitError.lineTooLarge(limitInBytes: limit) {
                limits.append(limit)
            }
            counts.append(count)
        }

        // The second repeating answer replaced the first, so the fallback is the
        // one scripted as bytes.
        #expect(counts == [8, 1])
        #expect(limits == [33_554_432, 65_536])
        #expect(
            fixtureClient.recordedInvocations
                == Array(repeating: .watch(boxKinds: NonEmptySet(.imbox), since: nil), count: 2)
        )
    }

    @Test("An exit status is named by its bare name and matched on, with no scoped import")
    func exitStatusIsNamedUnqualified() {
        // Swift Testing ships an exit status enum of its own, which the package's
        // earlier name for this type collided with. This suite imports Testing and
        // the package plainly, exactly as an app's test does, so the bare name
        // below is the assertion: an ambiguous one would not compile at all. Both
        // failures that carry a status are read, since an app catches either.
        let signaled: ProcessExitStatus = .signaled(SIGTERM)
        let exited: ProcessExitStatus = .exited(3)
        let cancelled = LoginFailure(exitStatus: signaled, standardError: "")
        let failed = ProcessFailure(exitStatus: exited)

        var signal: Int32?
        var code: Int32?
        if case let .signaled(value) = cancelled.exitStatus { signal = value }
        if case let .exited(value)? = failed.exitStatus { code = value }

        #expect(signal == SIGTERM)
        #expect(code == 3)
        #expect(signaled.description == "killed by signal \(SIGTERM)")
    }

    @Test(
        "A held answer is scripted, released and observed through the public API alone",
        .timeLimit(.minutes(1))
    )
    func heldAnswersArePublic() async throws {
        let fixtureClient = HEYFixtureClient()
        // The held answer, the release and the invocation that proves the call is
        // waiting are all spellings an app has, which is the whole assertion here.
        let hold = try fixtureClient.scriptHeld(.markSeen, fixture: "mutation-seen.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()
        let postingIDs = NonEmptySet(Posting.ID(7))

        let seen = Task { try await fixtureClient.client.markSeen(postingIDs) }
        #expect(await invocations.next() == .markSeen(postingIDs: postingIDs))
        #expect(fixtureClient.recordedInvocations == [.markSeen(postingIDs: postingIDs)])
        hold.release()

        try await seen.value
    }

    @Test("The three operations no other test here calls are methods too")
    func everyRemainingOperationIsAMethod() async throws {
        // The tests above call every operation but these three, so between them
        // all thirteen are reached the only way an app can reach one.
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.script(.version, fixture: "version.json")
        try fixtureClient.script(.screener, fixture: "screener.json")
        try fixtureClient.script(.denyScreenerEntries, fixture: "screener-deny.json")

        let version = try await fixtureClient.client.version()
        let screener = try await fixtureClient.client.screener()
        let entryID = try #require(screener.entries.first?.id)
        let decisions = try await fixtureClient.client.denyScreenerEntries(NonEmptySet(entryID))

        #expect(version.version == HEYCliKit.testedCLIVersion)
        #expect(screener.totalCount == 1)
        #expect(decisions.map(\.outcome) == [.denied])
        #expect(
            fixtureClient.recordedInvocations
                == [.version, .screener, .denyScreenerEntries(NonEmptySet(entryID))]
        )
    }
}
