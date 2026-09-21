import Foundation
import Synchronization
import Testing

import HEYCliKit
import HEYCliKitTestSupport

/// Held answers are exercised the way an app's tests use them: through the public
/// API only, with no `@testable` import.
///
/// Every test here carries a time limit, because a held call awaited on the test's
/// own task parks for ever and Swift Testing has no default limit of its own. The
/// limit is the last of the three guards against that: the scripting methods are
/// not `@discardableResult`, their documentation states the shape a held call is
/// made in, and a regression that forgets a release fails here rather than hanging
/// the suite. The fixture client itself has no timeout and never will (ADR 0002).
@Suite("Held answers")
struct HeldAnswerTests {
    @Test(
        "A held move stays in flight while a box page read runs to completion",
        .timeLimit(.minutes(1))
    )
    func heldMoveLetsAReadFinishUnderneathIt() async throws {
        let pageSize = try #require(PageSize(50))
        let fixtureClient = HEYFixtureClient()
        let hold = try fixtureClient.scriptHeld(.move, fixture: "mutation-move.json")
        try fixtureClient.script(.boxPage, fixture: "imbox.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()
        let postingIDs = NonEmptySet(Posting.ID(1), Posting.ID(2))
        let landings = Mutex<[String]>([])

        let move = Task {
            try await fixtureClient.client.move(postingIDs, to: .laterbox)
            landings.withLock { $0.append("move") }
        }
        // Awaiting the invocation is what makes the interleaving deterministic:
        // the move is inside the client and waiting before the read is started,
        // which is the ordering a menu bar app's own probe could never force.
        #expect(await invocations.next() == .move(postingIDs: postingIDs, to: .laterbox))

        let page = try await fixtureClient.client.boxPage(.imbox, pageSize: pageSize)
        landings.withLock { $0.append("read") }
        hold.release()
        try await move.value

        #expect(page.postings.count == 50)
        #expect(landings.withLock { $0 } == ["read", "move"])
        #expect(
            fixtureClient.recordedInvocations
                == [
                    .move(postingIDs: postingIDs, to: .laterbox),
                    .boxPage(kind: .imbox, pageSize: pageSize, cursor: nil),
                ]
        )
    }

    // The two below repeat that shape for the other two scripting overloads on
    // purpose. Asserting only what a held call finally returns or throws proves
    // nothing about the hold, since an answer that never waited returns and throws
    // the same thing. Only a landing recorded by another operation's call, made
    // after the invocation has arrived and before the release, tells the two
    // apart.

    @Test(
        "A held answer scripted from bytes stays in flight while a version read runs to completion",
        .timeLimit(.minutes(1))
    )
    func heldBytesLetAReadFinishUnderneathIt() async throws {
        let fixtureClient = HEYFixtureClient()
        let hold = fixtureClient.scriptHeld(.mailAccounts, standardOutput: secondMailAccount)
        try fixtureClient.script(.version, fixture: "version.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()
        let landings = Mutex<[String]>([])

        let accounts = Task {
            let accounts = try await fixtureClient.client.mailAccounts()
            landings.withLock { $0.append("mail accounts") }

            return accounts
        }
        #expect(await invocations.next() == .mailAccounts)

        let version = try await fixtureClient.client.version()
        landings.withLock { $0.append("version") }
        hold.release()
        let held = try await accounts.value

        #expect(version.version == "1.4.0")
        // Holding changes when the call answers and never what it answers, so the
        // bytes decode exactly as the same bytes scripted plainly decode.
        #expect(held.first?.emailAddress == "second@example.com")
        #expect(landings.withLock { $0 } == ["version", "mail accounts"])
        #expect(fixtureClient.recordedInvocations == [.mailAccounts, .version])
    }

    @Test(
        "A held failure stays in flight while a screener read runs to completion",
        .timeLimit(.minutes(1))
    )
    func heldFailureLetsAReadFinishUnderneathIt() async throws {
        struct StagedFailure: Error, Equatable {}

        let fixtureClient = HEYFixtureClient()
        let hold = fixtureClient.scriptHeld(.markUnseen, failing: StagedFailure())
        try fixtureClient.script(.screener, fixture: "screener.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()
        let postingIDs = NonEmptySet(Posting.ID(7))
        let landings = Mutex<[String]>([])

        let unseen = Task {
            await #expect(throws: StagedFailure()) {
                try await fixtureClient.client.markUnseen(postingIDs)
            }
            landings.withLock { $0.append("mark unseen") }
        }
        #expect(await invocations.next() == .markUnseen(postingIDs: postingIDs))

        let screener = try await fixtureClient.client.screener()
        landings.withLock { $0.append("screener") }
        hold.release()
        await unseen.value

        #expect(screener.totalCount == 1)
        #expect(landings.withLock { $0 } == ["screener", "mark unseen"])
        #expect(
            fixtureClient.recordedInvocations
                == [.markUnseen(postingIDs: postingIDs), .screener]
        )
    }

    @Test(
        "A release that lands before its call answers that call at once",
        .timeLimit(.minutes(1))
    )
    func releaseBeforeTheCallAnswersAtOnce() async throws {
        let fixtureClient = HEYFixtureClient()
        let hold = try fixtureClient.scriptHeld(.version, fixture: "version.json")
        // Releasing is a latch and not a signal, so this release is remembered
        // and the call below never waits. A test therefore never has to prove the
        // code under test reached the client before releasing.
        hold.release()

        let version = try await fixtureClient.client.version()

        #expect(version.version == "1.4.0")
    }

    @Test(
        "A held call is recorded and yielded as an invocation while it is still waiting",
        .timeLimit(.minutes(1))
    )
    func heldCallIsRecordedWhileItWaits() async throws {
        let fixtureClient = HEYFixtureClient()
        let hold = try fixtureClient.scriptHeld(.screener, fixture: "screener.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        let screener = Task { try await fixtureClient.client.screener() }

        #expect(await invocations.next() == .screener)
        // Recording and yielding happen under the one lock, in that order, so a
        // call that is waiting can be told from one that was never made.
        #expect(fixtureClient.recordedInvocations == [.screener])

        hold.release()

        #expect(try await screener.value.totalCount == 1)
    }

    @Test(
        "A held answer leaves its queue as its call arrives, so the next call reads the next answer",
        .timeLimit(.minutes(1))
    )
    func heldAnswerLeavesItsQueueAsTheCallArrives() async throws {
        let fixtureClient = HEYFixtureClient()
        let hold = try fixtureClient.scriptHeld(.mailAccounts, fixture: "accounts.json")
        fixtureClient.script(.mailAccounts, standardOutput: secondMailAccount)
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        let first = Task { try await fixtureClient.client.mailAccounts() }
        #expect(await invocations.next() == .mailAccounts)

        let second = try await fixtureClient.client.mailAccounts()
        hold.release()
        let held = try await first.value

        #expect(second.first?.emailAddress == "second@example.com")
        #expect(held.first?.emailAddress == "test@example.com")
    }

    @Test("A second release is a no op, before the call and after it", .timeLimit(.minutes(1)))
    func secondReleaseIsANoOp() async throws {
        let fixtureClient = HEYFixtureClient()
        let waiting = try fixtureClient.scriptHeld(.version, fixture: "version.json")
        let released = try fixtureClient.scriptHeld(.screener, fixture: "screener.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        released.release()
        released.release()
        let screener = try await fixtureClient.client.screener()

        let version = Task { try await fixtureClient.client.version() }
        #expect(await invocations.next() == .screener)
        #expect(await invocations.next() == .version)
        waiting.release()
        waiting.release()

        #expect(screener.totalCount == 1)
        #expect(try await version.value.version == "1.4.0")
    }

    @Test(
        "Cancelling the task that awaits a held call throws, and leaves the hold held",
        .timeLimit(.minutes(1))
    )
    func cancellingAHeldCallThrows() async throws {
        let fixtureClient = HEYFixtureClient()
        let hold = try fixtureClient.scriptHeld(.version, fixture: "version.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        let call = Task { try await fixtureClient.client.version() }
        #expect(await invocations.next() == .version)
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
        // The answer came off the queue when the call arrived, so the cancelled
        // call took it with it and there is nothing behind it.
        await #expect(throws: HEYFixtureClientError.notScripted(.version)) {
            _ = try await fixtureClient.client.version()
        }
        // A release nobody is waiting on any more changes nothing, which is what
        // lets a test release from a `defer` whatever the call did.
        hold.release()
    }

    @Test(
        "A task cancelled as soon as it is created still records its held call and throws from it",
        .timeLimit(.minutes(1))
    )
    func aTaskCancelledAtOnceStillRecordsItsHeldCall() async throws {
        let fixtureClient = HEYFixtureClient()
        let hold = try fixtureClient.scriptHeld(.screener, fixture: "screener.json")

        // The cancel below cannot be forced to land before the task is scheduled,
        // so this proves only what its name says. What it exercises is the same
        // either way: the body of a cancelled task still runs, so the call is
        // made and recorded, and only the wait reports the cancellation, which
        // reaches this test either from the latch's cancellation handler or from
        // the cancellation read it takes under its own lock. That read now sees
        // this case far more often than it used to, since the latch no longer
        // checks for cancellation before taking the lock.
        let call = Task { try await fixtureClient.client.screener() }
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(fixtureClient.recordedInvocations == [.screener])
        hold.release()
    }

    @Test(
        "A release that lands before a cancel answers, since nothing checks cancellation after the wait",
        .timeLimit(.minutes(1))
    )
    func releaseBeforeACancelStillAnswers() async throws {
        let fixtureClient = HEYFixtureClient()
        let hold = try fixtureClient.scriptHeld(.version, fixture: "version.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        let call = Task { try await fixtureClient.client.version() }
        #expect(await invocations.next() == .version)
        hold.release()
        call.cancel()

        // Release then cancel answers and cancel then release throws, both of
        // them every time, which is what a cancellation check after the wait
        // would turn into a race.
        #expect(try await call.value.version == "1.4.0")
    }

    @Test(
        "A held read decodes exactly as the same fixture scripted plainly decodes",
        .timeLimit(.minutes(1))
    )
    func heldReadDecodesAsAPlainAnswerWould() async throws {
        let pageSize = try #require(PageSize(50))
        let fixtureClient = HEYFixtureClient()
        let hold = try fixtureClient.scriptHeld(.boxPage, fixture: "imbox.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        let read = Task { try await fixtureClient.client.boxPage(.imbox, pageSize: pageSize) }
        #expect(await invocations.next() == .boxPage(kind: .imbox, pageSize: pageSize, cursor: nil))
        hold.release()
        let page = try await read.value

        #expect(page.postings.count == 50)
        #expect(page.postings.first?.subject == "Test subject 1")
        #expect(page.nextCursor != nil)
    }

    @Test(
        "A held error envelope maps to the error that envelope always maps to",
        .timeLimit(.minutes(1))
    )
    func heldErrorEnvelopeMapsTheSameWay() async throws {
        let fixtureClient = HEYFixtureClient()
        let hold = try fixtureClient.scriptHeld(
            .markSeen,
            fixture: "error-not-found.json",
            exitCode: 2
        )
        var invocations = fixtureClient.invocations.makeAsyncIterator()
        let postingIDs = NonEmptySet(Posting.ID(7))

        let seen = Task { try await fixtureClient.client.markSeen(postingIDs) }
        #expect(await invocations.next() == .markSeen(postingIDs: postingIDs))
        hold.release()

        do {
            try await seen.value
            Issue.record("The mutation was expected to fail but confirmed.")
        } catch let HEYCliKitError.notFound(details) {
            #expect(details.code == "not_found")
            #expect(details.message == "resource not found")
        }
    }

    @Test(
        "A held watch replays its fixture exactly as the same fixture scripted plainly does",
        .timeLimit(.minutes(1))
    )
    func heldWatchReplaysItsFixture() async throws {
        let fixtureClient = HEYFixtureClient()
        let hold = try fixtureClient.scriptHeld(.watch, fixture: "watch-session.ndjson")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        // A held watch holds the start of the watch, so the call that hands back
        // the stream is what waits, and the lines follow it as they always do.
        let started = Task { try await fixtureClient.client.watch(NonEmptySet(.imbox)) }
        #expect(await invocations.next() == .watch(boxKinds: NonEmptySet(.imbox), since: nil))
        hold.release()

        var decoded: [WatchLine] = []
        for try await line in try await started.value {
            decoded.append(line)
        }

        #expect(decoded.count == 28)
    }

    @Test(
        "A held login holds the start of the sign in, and its outcome then answers at once",
        .timeLimit(.minutes(1))
    )
    func heldLoginHoldsTheStartNotTheOutcome() async throws {
        let fixtureClient = HEYFixtureClient()
        let hold = fixtureClient.scriptHeld(
            .login,
            standardOutput: Data(#"{"ok": true, "data": { "method": "oauth" }}"#.utf8)
        )
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        let login = Task { try await fixtureClient.client.login() }
        #expect(await invocations.next() == .login)
        hold.release()
        let handle = try await login.value

        // The sign in that stays pending is the other scripting call entirely,
        // so the held one returns its handle late and the outcome is decided.
        #expect(await handle.outcome == .completed)
    }

    @Test("A held failure is thrown as it was given, once it is released", .timeLimit(.minutes(1)))
    func heldFailureIsThrownAsItWasGiven() async throws {
        struct StagedFailure: Error, Equatable {}

        let fixtureClient = HEYFixtureClient()
        let hold = fixtureClient.scriptHeld(.version, failing: StagedFailure())
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        let call = Task { try await fixtureClient.client.version() }
        #expect(await invocations.next() == .version)
        hold.release()

        await #expect(throws: StagedFailure()) { _ = try await call.value }
    }

    @Test(
        "An operation with a held answer waiting does not fall through to its repeating answer",
        .timeLimit(.minutes(1))
    )
    func aHeldAnswerIsTakenRatherThanTheRepeatingOne() async throws {
        let fixtureClient = HEYFixtureClient()
        try fixtureClient.scriptRepeating(.screener, fixture: "screener-empty.json")
        let hold = try fixtureClient.scriptHeld(.screener, fixture: "screener.json")
        var invocations = fixtureClient.invocations.makeAsyncIterator()

        let first = Task { try await fixtureClient.client.screener().totalCount }
        #expect(await invocations.next() == .screener)

        // The queue is empty once the held answer has been taken, so this second
        // call is the first one the fallback answers.
        let second = try await fixtureClient.client.screener()
        hold.release()
        let held = try await first.value

        #expect(held == 1)
        #expect(second.totalCount == 0)
    }
}

/// A second mail account, as envelope bytes of a test's own, so answers scripted
/// from bytes can be told apart by their addresses.
private let secondMailAccount = Data(
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
