import Foundation
import HEYCliKit
import Synchronization

/// One operation of ``HEYClient``, named so an answer can be scripted for it.
public enum HEYClientOperation: String, Sendable, Hashable, CaseIterable {
    case signInStatus
    case version
    case mailAccounts
    case boxPage
    case screener
    case approveScreenerEntries
    case denyScreenerEntries
    case move
    case markSeen
    case markUnseen
    case watch
    case login
    case logout
}

/// One call a test's code under test made, in the order it was made.
///
/// An invocation names the operation and carries that operation's own parameters.
/// It never carries a process concept: there are no arguments, no environment and
/// no working directory here, because a test must not depend on how the package
/// spawns the CLI.
public enum HEYClientInvocation: Sendable, Hashable {
    case signInStatus
    case version
    case mailAccounts
    case boxPage(kind: BoxKind, pageSize: PageSize, cursor: Cursor?)
    case screener
    case approveScreenerEntries(ScreenerApproval)
    case denyScreenerEntries(NonEmptySet<ScreenerEntry.ID>)
    case move(postingIDs: NonEmptySet<Posting.ID>, to: BoxKind)
    case markSeen(postingIDs: NonEmptySet<Posting.ID>)
    case markUnseen(postingIDs: NonEmptySet<Posting.ID>)
    case watch(boxKinds: NonEmptySet<BoxKind>, since: Date?)
    case login
    case logout

    /// The operation this call was made against.
    public var operation: HEYClientOperation {
        switch self {
        case .signInStatus: .signInStatus
        case .version: .version
        case .mailAccounts: .mailAccounts
        case .boxPage: .boxPage
        case .screener: .screener
        case .approveScreenerEntries: .approveScreenerEntries
        case .denyScreenerEntries: .denyScreenerEntries
        case .move: .move
        case .markSeen: .markSeen
        case .markUnseen: .markUnseen
        case .watch: .watch
        case .login: .login
        case .logout: .logout
        }
    }
}

/// Why a fixture client could not answer.
public enum HEYFixtureClientError: Error, Sendable, Hashable {
    /// The operation was called with nothing left in its queue.
    case notScripted(HEYClientOperation)
}

extension HEYFixtureClientError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .notScripted(operation):
            """
            The fixture client has no scripted answer left for \(operation.rawValue). \
            Script one with script(.\(operation.rawValue), fixture:) before the call.
            """
        }
    }
}

/// One scripted answer that waits, and the only thing that frees it.
///
/// A held answer stands for exactly one answer, the one the `scriptHeld` call that
/// handed this back queued, and releasing it is its only power. Nothing else
/// releases it: not the call arriving, not the task that awaits the call being
/// cancelled, not the fixture client going away. An answer nobody releases waits
/// for as long as the test runs, which is why the `scriptHeld` methods are not
/// `@discardableResult`. Releasing a second time is a no op, exactly as cancelling
/// a settled login is, so a test is free to release from a `defer` and again where
/// it means it.
///
/// It has no public initialiser, for the reason ``LoginHandle``'s is `package`
/// (ADR 0003): a held answer comes from scripting one and from nowhere else, so
/// `hold.release()` at a call site always names an answer that is really queued.
public struct HEYHeldAnswer: Sendable {
    /// Frees the answer this stands for, so the call holding it resolves.
    ///
    /// It is a latch and not a signal: a release that lands before its call is
    /// remembered, and that call answers the moment it arrives. A test therefore
    /// never has to prove the code under test reached the client before releasing,
    /// and the release can sit wherever the test reads best.
    public func release() {
        releaseAnswer()
    }

    private let releaseAnswer: @Sendable () -> Void

    init(release: @escaping @Sendable () -> Void) {
        releaseAnswer = release
    }
}

/// A client whose operations answer from scripted fixtures in a fixed order.
///
/// Each operation has a queue of its own, so the second call to an operation can
/// answer differently from the first, and an operation with an empty queue fails
/// with ``HEYFixtureClientError/notScripted(_:)`` rather than answering silently.
/// An operation a test is not about can be given a repeating answer instead, which
/// answers every call once that operation's queue is empty and is never used up.
/// Answers are scripted as envelope bytes and an exit code, and they are decoded
/// and mapped by the package itself, so a test sees exactly what the live client
/// would have returned or thrown for the same bytes.
///
/// The client keeps answering after the fixture client that built it is released.
/// Only the invocation stream ends there, so a test that reads the stream is the
/// one that has to hold the fixture client.
///
/// ```swift
/// let fixtureClient = HEYFixtureClient()
/// try fixtureClient.script(.mailAccounts, fixture: "accounts.json")
/// let accounts = try await fixtureClient.client.mailAccounts()
/// ```
public final class HEYFixtureClient: Sendable {
    /// One scripted answer: the bytes and exit the CLI would have produced, or a
    /// failure to throw as it is.
    private enum Answer {
        case output(standardOutput: Data, exitStatus: ProcessExitStatus, standardError: Data)
        case failure(any Error)
        /// The lines a watch yields, and the error its stream throws once they
        /// are all yielded.
        case failingWatch(standardOutput: Data, error: any Error)
        /// The outcome a scripted login resolves with, or nil for one that stays
        /// pending until the app cancels it.
        case login(LoginOutcome?)
    }

    /// One queued answer, and the latch that frees it if it was held.
    ///
    /// The hold sits beside the answer rather than as a case inside ``Answer``
    /// because ``State/repeatingAnswers`` stores an `Answer` too: a held value
    /// there would be representable, and a held fallback is a gate rather than a
    /// hold. Every call would wait on the one latch, the first release would free
    /// all of them at once, and every call after that would pass straight through.
    /// Keeping the hold in the queue element alone makes a held fallback, and a
    /// hold nested inside a hold, unrepresentable by construction.
    private struct ScriptedAnswer {
        let answer: Answer
        /// nil for every answer scripted plainly, which is every answer that
        /// resolves the moment its call arrives.
        let hold: HeldLatch?
    }

    /// The invocation stream's continuation, named short enough to read inline.
    private typealias Continuation = AsyncStream<HEYClientInvocation>.Continuation

    private struct State {
        var queues: [HEYClientOperation: [ScriptedAnswer]] = [:]
        /// The answer an operation falls back to once its queue is empty, held
        /// beside the queues rather than inside them, so a fallback is never
        /// consumed and the queue stays the order a test scripted.
        var repeatingAnswers: [HEYClientOperation: Answer] = [:]
        var recorded: [HEYClientInvocation] = []
        var continuation: Continuation?
    }

    /// The scripted state, held apart from the fixture client so the client's
    /// closures capture this and never the fixture client itself. The fixture
    /// client can then be released, and its `deinit` end the invocation stream,
    /// while the client value it built is still in use.
    private final class ScriptedAnswers: Sendable {
        let state = Mutex(State())

        /// Records the call and decodes the next answer into the read's payload.
        func answer<Payload: Decodable>(
            _ invocation: HEYClientInvocation,
            _ payloadType: Payload.Type
        ) async throws -> Payload {
            try await answerEnvelope(invocation, payloadType).data
        }

        /// The same, keeping the envelope's own fields for the one operation that
        /// reads something beside the payload.
        func answerEnvelope<Payload: Decodable>(
            _ invocation: HEYClientInvocation,
            _ payloadType: Payload.Type
        ) async throws -> DecodedEnvelope<Payload> {
            let answer = try await output(for: invocation)

            return try decodeEnvelope(
                payloadType,
                exitStatus: answer.exitStatus,
                standardOutput: answer.standardOutput,
                standardError: answer.standardError
            )
        }

        /// Records the call and takes the next answer as the bytes and exit the
        /// CLI would have produced.
        ///
        /// A login answer and a failing watch are not envelope bytes, and each only
        /// ever lands in its own operation's queue, so no reader here can meet
        /// one. Reporting either as not scripted keeps every reader total rather
        /// than trapping on a state the queues cannot produce.
        private func output(
            for invocation: HEYClientInvocation
        ) async throws -> (standardOutput: Data, exitStatus: ProcessExitStatus, standardError: Data)
        {
            switch try await take(invocation) {
            case let .failure(error):
                throw error
            case let .output(standardOutput, exitStatus, standardError):
                return (standardOutput, exitStatus, standardError)
            case .failingWatch, .login:
                throw HEYFixtureClientError.notScripted(invocation.operation)
            }
        }

        /// Records a watch and replays its scripted bytes as a stream of lines.
        ///
        /// The bytes are split into non empty lines and read by the package's own
        /// decoder, one line per element, and that same decoder ends the stream by
        /// the scripted exit exactly as a live watch ends by the child's: a clean
        /// exit finishes it, and anything else throws the mapped error for whatever
        /// the CLI printed after its last watch line. So an error fixture at exit 3
        /// arrives as the unrecognised lines it is, and then as signed out.
        ///
        /// A failing watch is read line by line the same way and only ends
        /// differently: its stream throws the scripted error as it was given, so
        /// the call that opened the watch never throws it.
        ///
        /// The stream buffers without bound on purpose, where a live watch's is
        /// bounded: the whole fixture is yielded before anybody reads it, so a
        /// bound here would drop fixture lines from a test that never fell behind
        /// at all. An app stages ``HEYCliKitError/watchFellBehind(limitInLines:)``
        /// with ``HEYFixtureClient/script(watchFixture:thenFailing:)`` instead.
        func replayWatch(
            _ invocation: HEYClientInvocation
        ) async throws -> AsyncThrowingStream<WatchLine, any Error> {
            switch try await take(invocation) {
            case let .failure(error):
                throw error
            case let .output(standardOutput, exitStatus, standardError):
                return replay(standardOutput) { decoder, continuation in
                    decoder.finish(
                        continuation,
                        exitStatus: exitStatus,
                        standardError: standardError
                    )
                }
            case let .failingWatch(standardOutput, error):
                return replay(standardOutput) { _, continuation in
                    continuation.finish(throwing: error)
                }
            case .login:
                throw HEYFixtureClientError.notScripted(invocation.operation)
            }
        }

        /// Yields every non empty line of the bytes through one decoder, then
        /// hands that decoder and the stream to `end`, which is the only part a
        /// plain watch and a failing one do not share.
        private func replay(
            _ standardOutput: Data,
            end: (WatchLineDecoder, AsyncThrowingStream<WatchLine, any Error>.Continuation) -> Void
        ) -> AsyncThrowingStream<WatchLine, any Error> {
            let (stream, continuation) = AsyncThrowingStream<WatchLine, any Error>.makeStream(
                bufferingPolicy: .unbounded
            )
            var decoder = WatchLineDecoder()
            for line in String(decoding: standardOutput, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
            {
                continuation.yield(decoder.decode(String(line)))
            }

            end(decoder, continuation)

            return stream
        }

        /// Records a mutation the same way and confirms it, returning nothing.
        ///
        /// A mutation carries no payload, so the scripted envelope is read for its
        /// `ok` and its exit code alone, exactly as the live client reads one.
        func confirm(_ invocation: HEYClientInvocation) async throws {
            let answer = try await output(for: invocation)

            try throwIfFailed(
                exitStatus: answer.exitStatus,
                standardOutput: answer.standardOutput,
                standardError: answer.standardError
            )
        }

        /// Records a login and hands back the handle it was scripted with.
        ///
        /// A login scripted as envelope bytes is mapped exactly as the live client
        /// maps a child's ending: stdout is ignored, exit 0 is a completed sign in
        /// and anything else is one that was not completed, carrying the scripted
        /// stderr and the kind the package classifies from it. So no scripting call
        /// can fail a consumer's test for a reason the CLI would not have.
        ///
        /// A held login holds the start of the sign in and never its outcome, so
        /// ``HEYClient/login()`` returns late and the handle it hands back answers
        /// at once. That is the only reading that stays coherent: the sign in that
        /// stays pending is a scripting call of its own,
        /// ``HEYFixtureClient/scriptLoginWaitingForCancel()``.
        func startLogin(_ invocation: HEYClientInvocation) async throws -> LoginHandle {
            switch try await take(invocation) {
            case let .failure(error):
                throw error
            case let .output(_, exitStatus, standardError):
                return ScriptedLogin(
                    LoginOutcome(exitStatus: exitStatus, standardError: standardError)
                ).handle
            case let .login(outcome):
                return ScriptedLogin(outcome).handle
            case .failingWatch:
                // Only ever queued for the watch, so a login cannot meet one.
                throw HEYFixtureClientError.notScripted(invocation.operation)
            }
        }

        /// Records the call, waits for its hold if it has one, and hands back the
        /// answer.
        ///
        /// Every reader goes through here rather than calling `record` itself, so
        /// the ordering a held answer rests on is stated once instead of at each
        /// call site: the call is recorded, yielded and off its queue before
        /// anything waits, and the wait is the last thing that happens. So a call
        /// that is waiting can be told from one that was never made, and the next
        /// call to that operation reads the next answer rather than this one.
        ///
        /// Cancelling the task throws from the wait, after `record` has already
        /// run, which leaves the hold held and its answer consumed. Nothing checks
        /// cancellation once the wait has returned, and that is deliberate: a
        /// release followed by a cancel answers every time, a cancel followed by a
        /// release throws every time, and a check here would turn both into races.
        /// A cancel and a release that both landed before the call ever arrived
        /// answer rather than throw, which ``HeldLatch/wait()`` explains.
        private func take(_ invocation: HEYClientInvocation) async throws -> Answer {
            let scripted = try record(invocation)
            if let hold = scripted.hold { try await hold.wait() }

            return scripted.answer
        }

        /// Records the call, hands it to the stream and takes the next answer.
        ///
        /// The call is recorded and yielded before the queue is read, so a call
        /// nobody scripted still shows up as an invocation. Both happen under the
        /// same lock, so two calls at once cannot land in one order in
        /// `recordedInvocations` and the other order in the stream. Yielding is
        /// safe to hold the lock across: the stream buffers without bound and
        /// nothing it does calls back in here.
        ///
        /// The repeating answer is read under that same lock, so an operation
        /// whose queue empties between two calls cannot answer from a fallback
        /// that a third call had already replaced.
        private func record(_ invocation: HEYClientInvocation) throws -> ScriptedAnswer {
            let next = state.withLock { state -> ScriptedAnswer? in
                state.recorded.append(invocation)
                state.continuation?.yield(invocation)

                var queue = state.queues[invocation.operation, default: []]
                guard !queue.isEmpty else {
                    // A fallback is never held, which is what keeps a repeating
                    // answer a fallback rather than a gate across every call.
                    return state.repeatingAnswers[invocation.operation]
                        .map { ScriptedAnswer(answer: $0, hold: nil) }
                }

                let next = queue.removeFirst()
                state.queues[invocation.operation] = queue

                return next
            }

            guard let next else {
                throw HEYFixtureClientError.notScripted(invocation.operation)
            }

            return next
        }

        func enqueue(_ answer: Answer, for operation: HEYClientOperation) {
            state.withLock {
                $0.queues[operation, default: []]
                    .append(ScriptedAnswer(answer: answer, hold: nil))
            }
        }

        /// Queues an answer that waits, and hands back the latch that frees it.
        ///
        /// The latch is built here and handed out at once, before any call can
        /// reach it, so a release that lands before the call has something to land
        /// on and is remembered by it.
        func enqueueHeld(_ answer: Answer, for operation: HEYClientOperation) -> HeldLatch {
            let hold = HeldLatch()
            state.withLock {
                $0.queues[operation, default: []]
                    .append(ScriptedAnswer(answer: answer, hold: hold))
            }

            return hold
        }

        /// Sets the operation's fallback, replacing whatever it had, since an
        /// operation only ever falls back to one answer.
        func setRepeating(_ answer: Answer, for operation: HEYClientOperation) {
            state.withLock { $0.repeatingAnswers[operation] = answer }
        }
    }

    private let answers = ScriptedAnswers()

    /// The client to hand to the code under test.
    public let client: HEYClient

    /// Every call, as it happens, so a test can await one before advancing a clock.
    ///
    /// The buffer is unbounded, so nothing is ever dropped, and the stream is meant
    /// for one iterator: a second one shares the same elements rather than seeing
    /// its own copy. The stream ends when this fixture client is released.
    public let invocations: AsyncStream<HEYClientInvocation>

    /// Every call made so far, in order, as a snapshot.
    public var recordedInvocations: [HEYClientInvocation] {
        answers.state.withLock { $0.recorded }
    }

    public init() {
        let answers = self.answers
        let (stream, continuation) = AsyncStream<HEYClientInvocation>.makeStream(
            bufferingPolicy: .unbounded
        )
        answers.state.withLock { $0.continuation = continuation }
        invocations = stream

        client = HEYClient(
            signInStatus: { try await answers.answer(.signInStatus, SignInStatus.self) },
            version: { try await answers.answer(.version, CLIVersion.self) },
            mailAccounts: {
                try await answers.answer(.mailAccounts, MailAccountList.self).mailAccounts
            },
            boxPage: { kind, pageSize, cursor in
                try await answers.answer(
                    .boxPage(kind: kind, pageSize: pageSize, cursor: cursor),
                    BoxPagePayload.self
                ).page
            },
            screener: {
                try Screener(await answers.answerEnvelope(.screener, [ScreenerEntry].self))
            },
            approveScreenerEntries: { approval in
                try await answers.answer(.approveScreenerEntries(approval), [ScreenerDecision].self)
            },
            denyScreenerEntries: { entryIDs in
                try await answers.answer(.denyScreenerEntries(entryIDs), [ScreenerDecision].self)
            },
            move: { postingIDs, kind in
                try await answers.confirm(.move(postingIDs: postingIDs, to: kind))
            },
            markSeen: { postingIDs in
                try await answers.confirm(.markSeen(postingIDs: postingIDs))
            },
            markUnseen: { postingIDs in
                try await answers.confirm(.markUnseen(postingIDs: postingIDs))
            },
            watch: { boxKinds, since in
                try await answers.replayWatch(.watch(boxKinds: boxKinds, since: since))
            },
            login: { try await answers.startLogin(.login) },
            logout: { try await answers.confirm(.logout) }
        )
    }

    deinit {
        answers.state.withLock { $0.continuation }?.finish()
    }

    /// Scripts one answer for an operation from a shipped fixture.
    ///
    /// The bytes go through the package's own envelope decoding and error mapping,
    /// so an error fixture with the exit code the CLI prints it with throws the
    /// same ``HEYCliKitError`` a live client would have thrown.
    public func script(
        _ operation: HEYClientOperation,
        fixture: String,
        exitCode: Int32 = 0,
        standardError: String = ""
    ) throws {
        script(
            operation,
            standardOutput: try HEYFixtures.data(named: fixture),
            exitCode: exitCode,
            standardError: standardError
        )
    }

    /// Scripts one answer for an operation from envelope bytes of your own.
    ///
    /// Use this for an envelope the CLI has not been captured producing.
    public func script(
        _ operation: HEYClientOperation,
        standardOutput: Data,
        exitCode: Int32 = 0,
        standardError: String = ""
    ) {
        answers.enqueue(
            .output(
                standardOutput: standardOutput,
                exitStatus: .exited(exitCode),
                standardError: Data(standardError.utf8)
            ),
            for: operation
        )
    }

    /// Scripts one answer for an operation that throws the given error as it is.
    ///
    /// Use this to stage a failure the CLI cannot express in an envelope, such as a
    /// cancellation or a process that never launched.
    public func script(_ operation: HEYClientOperation, failing error: any Error) {
        answers.enqueue(.failure(error), for: operation)
    }

    // None of the three below is `@discardableResult`, and that is the point of
    // them. A discarded held answer is one nobody can ever release, so the call
    // holding it waits for as long as the test runs, and the unused result warning
    // is the only diagnostic a consumer gets before that happens. The fixture
    // client has no timeout of its own to fall back on and never will (ADR 0002).

    /// Scripts one answer for an operation from a shipped fixture, held until the
    /// returned value releases it.
    ///
    /// Holding changes when a call answers and never what it answers: the fixture
    /// goes through the package's own envelope decoding and error mapping exactly
    /// as ``script(_:fixture:exitCode:standardError:)`` sends it, once released.
    /// The call is recorded and yielded as an invocation the moment it arrives, and
    /// it has taken this answer off its operation's queue by then, so the next call
    /// to that operation reads the next answer rather than waiting behind this one.
    ///
    /// A held watch holds the call that hands back the stream, so that call is what
    /// waits, and the lines follow once it is released.
    ///
    /// Make the held call from a task the test owns, await its invocation, then
    /// release and await that task. A held call awaited on the test's own task
    /// parks the test for ever, since nothing but ``HEYHeldAnswer/release()`` frees
    /// it. Awaiting the invocation is the step that pins the interleaving: the
    /// release is a latch and is remembered whenever it lands, but only the
    /// invocation proves the held call has reached the client, so whatever the test
    /// does next really does happen while that call is in flight.
    ///
    /// ```swift
    /// let hold = try fixtureClient.scriptHeld(.move, fixture: "mutation-move.json")
    /// try fixtureClient.script(.boxPage, fixture: "imbox.json")
    /// var invocations = fixtureClient.invocations.makeAsyncIterator()
    ///
    /// let move = Task { try await fixtureClient.client.move(postingIDs, to: .laterbox) }
    /// _ = await invocations.next()
    /// _ = try await fixtureClient.client.boxPage(.imbox)
    /// hold.release()
    /// try await move.value
    /// ```
    public func scriptHeld(
        _ operation: HEYClientOperation,
        fixture: String,
        exitCode: Int32 = 0,
        standardError: String = ""
    ) throws -> HEYHeldAnswer {
        scriptHeld(
            operation,
            standardOutput: try HEYFixtures.data(named: fixture),
            exitCode: exitCode,
            standardError: standardError
        )
    }

    /// Scripts one held answer for an operation from envelope bytes of your own.
    ///
    /// Use this for an envelope the CLI has not been captured producing, and for a
    /// held login: a sign in is held by its bytes, since holding a login holds the
    /// start of the sign in and not its outcome, so ``HEYClient/login()`` returns
    /// late and the handle then answers at once. The sign in that stays pending is
    /// ``scriptLoginWaitingForCancel()`` and nothing to do with holding.
    ///
    /// Make the held call from a task the test owns, await its invocation, then
    /// release and await that task, for the reason
    /// ``scriptHeld(_:fixture:exitCode:standardError:)`` gives.
    public func scriptHeld(
        _ operation: HEYClientOperation,
        standardOutput: Data,
        exitCode: Int32 = 0,
        standardError: String = ""
    ) -> HEYHeldAnswer {
        hold(
            .output(
                standardOutput: standardOutput,
                exitStatus: .exited(exitCode),
                standardError: Data(standardError.utf8)
            ),
            for: operation
        )
    }

    /// Scripts one held answer that throws the given error as it is, once released.
    ///
    /// Use this to stage a failure the CLI cannot express in an envelope arriving
    /// late, such as a process that never launched while a read is already running.
    ///
    /// Make the held call from a task the test owns, await its invocation, then
    /// release and await that task, for the reason
    /// ``scriptHeld(_:fixture:exitCode:standardError:)`` gives.
    public func scriptHeld(
        _ operation: HEYClientOperation,
        failing error: any Error
    ) -> HEYHeldAnswer {
        hold(.failure(error), for: operation)
    }

    /// Queues the answer held and wraps its latch in the one value that frees it.
    private func hold(_ answer: Answer, for operation: HEYClientOperation) -> HEYHeldAnswer {
        let latch = answers.enqueueHeld(answer, for: operation)

        return HEYHeldAnswer(release: { latch.release() })
    }

    /// Scripts what an operation falls back to once its queue is empty, from a
    /// shipped fixture.
    ///
    /// This is for the operations that merely happen around the one a test is
    /// about. An app that polls the Screener on a timer would otherwise need one
    /// scripted answer per tick, and the ticks counted by hand, in every test of
    /// something else. Queued answers still come first and in order, so the
    /// operation a test is about keeps saying what it was scripted to say, and an
    /// operation with neither a queue nor a fallback still fails rather than
    /// answering silently.
    ///
    /// A repeating answer is never used up and there is only one per operation, so
    /// scripting a second replaces the first rather than queueing behind it.
    public func scriptRepeating(
        _ operation: HEYClientOperation,
        fixture: String,
        exitCode: Int32 = 0,
        standardError: String = ""
    ) throws {
        scriptRepeating(
            operation,
            standardOutput: try HEYFixtures.data(named: fixture),
            exitCode: exitCode,
            standardError: standardError
        )
    }

    /// Scripts the same fallback from envelope bytes of your own.
    ///
    /// Use this for an envelope the CLI has not been captured producing.
    public func scriptRepeating(
        _ operation: HEYClientOperation,
        standardOutput: Data,
        exitCode: Int32 = 0,
        standardError: String = ""
    ) {
        answers.setRepeating(
            .output(
                standardOutput: standardOutput,
                exitStatus: .exited(exitCode),
                standardError: Data(standardError.utf8)
            ),
            for: operation
        )
    }

    /// Scripts a fallback that throws the given error as it is, on every call.
    ///
    /// Use this to hold an operation failing the same way for as long as a test
    /// runs, such as a background poll that stays broken while the test watches
    /// what the app does about it.
    public func scriptRepeating(_ operation: HEYClientOperation, failing error: any Error) {
        answers.setRepeating(.failure(error), for: operation)
    }

    /// Scripts the next login so its handle resolves with this outcome at once.
    ///
    /// An outcome is not envelope bytes, which is why login has a scripting method
    /// of its own. The bytes methods above still work for a login, and map the way
    /// the live client maps a child's ending.
    public func script(login outcome: LoginOutcome) {
        answers.enqueue(.login(outcome), for: .login)
    }

    /// Scripts the next login so its handle resolves at once as a sign in that
    /// was not completed, with the given kind.
    ///
    /// Each kind gets an ending the CLI could have come to, and the package
    /// classifies it by the same rule it applies to a real child:
    ///
    /// - ``LoginFailure/Kind/timedOut``, ``LoginFailure/Kind/accessDenied`` and
    ///   ``LoginFailure/Kind/notClassified`` exit 3 with stderr shaped like the
    ///   CLI's, its progress lines and then the failed envelope, with the sign in
    ///   address left out so no test ever carries an install id. The one not
    ///   classified carries `OAuth error: server_error`, an error HEY's page can
    ///   report that the package has no name for.
    /// - ``LoginFailure/Kind/cancelled`` ends by SIGTERM with no stderr, as the
    ///   CLI does once it is asked to stop. It resolves at once, which a real
    ///   cancel cannot: the realistic one is a login scripted with
    ///   ``scriptLoginWaitingForCancel()`` that the app cancels itself.
    ///
    /// Use ``script(login:)`` for an ending of your own.
    public func script(loginNotCompleted kind: LoginFailure.Kind) {
        answers.enqueue(.login(.notCompletedLogin(kind)), for: .login)
    }

    /// Scripts the next login so its handle stays pending until the app cancels it,
    /// and then resolves as not completed by SIGTERM, the way the CLI does, with
    /// the kind ``LoginFailure/Kind/cancelled``.
    ///
    /// This is the sign in nobody finished: the CLI waits for a browser that never
    /// comes back, with no timeout of its own (ADR 0002), until the app stops it.
    public func scriptLoginWaitingForCancel() {
        answers.enqueue(.login(nil), for: .login)
    }

    // Login has no repeating spelling on purpose. A sign in is a one shot flow the
    // user starts, not something an app polls, so a login that answered the same
    // way for ever would stand for nothing the CLI does.

    /// Scripts the next watch so it yields the lines of a shipped fixture and then
    /// its stream throws the given error as it is.
    ///
    /// This is the shape the live client gives a watch that fails once it is
    /// running, such as ``HEYCliKitError/watchFellBehind(limitInLines:)``,
    /// ``HEYCliKitError/lineTooLarge(limitInBytes:)`` or a watch ended by
    /// ``HEYCliKitError/outputTooLarge(limitInBytes:)``: the call that opens the
    /// watch returns a stream, and the error arrives from that stream after the
    /// lines the package held. ``script(_:failing:)`` stages the other throw site,
    /// a watch that never started, since it throws from the opening call itself.
    ///
    /// Every line is decoded exactly as ``script(_:fixture:exitCode:standardError:)``
    /// decodes it for a watch, and only the ending differs: there is no exit code
    /// or stderr to map, so the error is thrown unchanged, whatever it is. A
    /// `CancellationError` is thrown like any other. The call is recorded and
    /// yielded as a watch invocation the moment it arrives, and queued answers for
    /// the watch are still read in the order they were scripted.
    ///
    /// It is a spelling of the watch alone, as the login spellings are of login,
    /// since lines followed by an error mean nothing for any other operation.
    ///
    /// ```swift
    /// try fixtureClient.script(
    ///     watchFixture: "watch-session.ndjson",
    ///     thenFailing: HEYCliKitError.watchFellBehind(limitInLines: 1024)
    /// )
    /// let lines = try await fixtureClient.client.watch(NonEmptySet(.imbox))
    /// for try await line in lines { ... }
    /// ```
    ///
    /// - Throws: ``HEYFixtureError/missing(_:)`` when no fixture has that name, in
    ///   which case nothing is scripted.
    public func script(watchFixture fixture: String, thenFailing error: any Error) throws {
        script(watchStandardOutput: try HEYFixtures.data(named: fixture), thenFailing: error)
    }

    /// Scripts the next watch so it yields lines of your own and then its stream
    /// throws the given error as it is.
    ///
    /// Use this for watch lines the CLI has not been captured producing. The bytes
    /// are read exactly as ``script(watchFixture:thenFailing:)`` reads a fixture's.
    public func script(watchStandardOutput standardOutput: Data, thenFailing error: any Error) {
        answers.enqueue(
            .failingWatch(standardOutput: standardOutput, error: error),
            for: .watch
        )
    }

    /// Scripts what the watch falls back to once its queue is empty: the lines of
    /// a shipped fixture, then a stream that throws the given error as it is.
    ///
    /// This is for an app that starts its watch again every time one fails, so a
    /// test can follow as many restarts as it likes without scripting one answer
    /// per start. Each start is answered exactly as
    /// ``script(watchFixture:thenFailing:)`` answers one, and is recorded and
    /// yielded as its own invocation. Queued answers for the watch still come
    /// first and in order, and the watch has only one fallback, so this replaces
    /// whatever ``scriptRepeating(_:fixture:exitCode:standardError:)`` or another
    /// repeating spelling set for it, and is replaced by the next one in turn.
    ///
    /// - Throws: ``HEYFixtureError/missing(_:)`` when no fixture has that name, in
    ///   which case the fallback is left as it was.
    public func scriptRepeating(watchFixture fixture: String, thenFailing error: any Error) throws {
        scriptRepeating(
            watchStandardOutput: try HEYFixtures.data(named: fixture),
            thenFailing: error
        )
    }

    /// Scripts the same failing fallback for the watch from lines of your own.
    ///
    /// Use this for watch lines the CLI has not been captured producing.
    public func scriptRepeating(
        watchStandardOutput standardOutput: Data,
        thenFailing error: any Error
    ) {
        answers.setRepeating(
            .failingWatch(standardOutput: standardOutput, error: error),
            for: .watch
        )
    }

    // A failing watch has no held spelling on purpose. Holding a watch only delays
    // the call that opens its stream, never the throw relative to the lines, so a
    // held failing watch would look like a failure on the test's cue without being
    // one. A failure on cue is a different thing, and no app has needed it yet.

    // A repeating answer has no held spelling on purpose either, and cannot have
    // one: a fallback is stored as an `Answer` rather than a `ScriptedAnswer`, so
    // a held fallback does not typecheck. It would be a gate and not a hold, one
    // latch every call waits on, freed for all of them at once by the first
    // release and passed straight through by every call after it.
}

/// What one held answer waits on, and what releasing it does.
///
/// It is a latch and not a signal: a release that lands before anybody waits is
/// remembered, so the call that arrives afterwards answers at once and a test
/// never has to prove the code under test reached the client first. One latch
/// belongs to one queued answer, so a release frees that call and no other.
///
/// A latch therefore has at most one waiter ever: `record` takes that one answer
/// off its queue exactly once, so exactly one call can ever reach this latch. The
/// dictionary of waiters is kept anyway, because it is what makes the mutual
/// exclusion provable rather than merely argued. Releasing and cancelling both
/// take the continuation out of it under the same lock, so one of them finds it
/// there and resumes it while the other finds nothing, and neither can resume a
/// continuation the other has already resumed. Collapsing this to a single
/// optional slot would hold the same invariant and is deliberately not done, since
/// tracing that slot's lifetime is work this spares a reader.
///
/// Waiters are keyed by an id of their own rather than kept in a list, so a
/// cancelled waiter reclaims its own continuation and nobody else's. That is where
/// this parts company with ``ScriptedLogin``, whose cancellation resolves the login
/// for every awaiter: cancelling the task that awaits a sign in terminates the
/// child, which really does end it for everyone, while a hold that released itself
/// on a cancel would release for everybody and contradict what a held answer is.
///
/// Every continuation is resumed after ``Mutex/withLock(_:)`` has returned, the
/// discipline ``ScriptedLogin`` already keeps, so nothing resumes while the lock
/// is held.
private final class HeldLatch: Sendable {
    private struct State {
        var isReleased = false
        var nextID = 0
        var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    /// Frees this answer, now and for every call that arrives later.
    ///
    /// A second release finds nobody waiting and an already released latch, so it
    /// does nothing, which is what lets a test release from a `defer` as well as
    /// where it means it.
    func release() {
        let resumed = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.isReleased = true
            defer { state.waiting = [:] }

            return Array(state.waiting.values)
        }

        for continuation in resumed {
            continuation.resume()
        }
    }

    /// Waits for the release, or throws if the waiting task is cancelled.
    ///
    /// `CancellationError` is what the live client throws for a cancelled
    /// operation, so a model that gives up on a call in flight behaves here as it
    /// does against a real child.
    ///
    /// There is deliberately no cancellation check before the lock is taken. The
    /// decision belongs inside the lock, where `isReleased` is read before
    /// `Task.isCancelled`, and a check out here would override that order for
    /// whichever of the two landed while this call was on its way in. Without it
    /// both directions are decided rather than raced. A release that lands before
    /// a cancel answers: either this call reaches the lock before the release
    /// does, in which case the cancel has not started yet and the call parks for
    /// that release to resume it, or it reaches the lock afterwards and reads
    /// `isReleased`. A cancel that lands before a release throws, from the in lock
    /// read or from the handler below, and from exactly one of them, since both
    /// take the continuation out of `waiting` under the same lock.
    ///
    /// The one case that is genuinely order dependent is a cancel and a release
    /// that have both landed before the call reaches the latch at all: that call
    /// reads `isReleased` first, so it answers. That is the precedence this is
    /// meant to have and not an accident of the reads, since a release names one
    /// queued answer while a cancel names whichever task happens to be carrying
    /// it.
    func wait() async throws {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }

            return state.nextID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                enum Verdict { case released, cancelled, parked }

                let verdict = state.withLock { state -> Verdict in
                    if state.isReleased { return .released }
                    // This read is the cancellation gate for a task cancelled
                    // before it ever parked, now that nothing checks ahead of the
                    // lock, and it is read second on purpose so a release that
                    // already landed wins. It is also what makes the handler below
                    // safe: without it a cancel that landed while this call was on
                    // its way here would run the handler against a waiter that is
                    // not parked yet, find nothing to remove, and strand this
                    // continuation for ever.
                    if Task.isCancelled { return .cancelled }
                    state.waiting[id] = continuation

                    return .parked
                }

                switch verdict {
                case .released: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .parked: break
                }
            }
        } onCancel: {
            let parked = state.withLock { $0.waiting.removeValue(forKey: id) }
            parked?.resume(throwing: CancellationError())
        }
    }
}

/// One scripted login, and the handle the fixture client hands out for it.
///
/// A login scripted with an outcome is resolved from the start, so awaiting it
/// returns at once. One scripted as waiting is resolved by ``cancel()`` alone,
/// as a cancelled sign in ended by SIGTERM, and every cancel after that is a no
/// op. The outcome is safe to await from as many places as a test likes, which is
/// why every waiter is remembered rather than one.
private final class ScriptedLogin: Sendable {
    private struct State {
        var outcome: LoginOutcome?
        var waiting: [CheckedContinuation<LoginOutcome, Never>] = []
    }

    private let state: Mutex<State>

    init(_ resolved: LoginOutcome?) {
        state = Mutex(State(outcome: resolved))
    }

    var handle: LoginHandle {
        LoginHandle(cancel: { self.cancel() }, outcome: { await self.outcome })
    }

    private func cancel() {
        resolve(.cancelledLogin)
    }

    /// The outcome, with the cancellation the live handle has: a task that awaits
    /// this and goes away cancels the sign in, so a test of an app's own
    /// cancellation behaves here exactly as it does against a real child.
    private var outcome: LoginOutcome {
        get async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resolved: LoginOutcome? = state.withLock { state in
                        guard let outcome = state.outcome else {
                            state.waiting.append(continuation)
                            return nil
                        }

                        return outcome
                    }

                    if let resolved {
                        continuation.resume(returning: resolved)
                    }
                }
            } onCancel: {
                cancel()
            }
        }
    }

    private func resolve(_ outcome: LoginOutcome) {
        let waiting = state.withLock { state -> [CheckedContinuation<LoginOutcome, Never>] in
            guard state.outcome == nil else { return [] }

            state.outcome = outcome
            defer { state.waiting = [] }

            return state.waiting
        }

        for continuation in waiting {
            continuation.resume(returning: outcome)
        }
    }
}

extension LoginOutcome {
    /// A sign in the app stopped, ended by SIGTERM with no stderr, which is what
    /// the CLI does once it is asked to stop.
    ///
    /// It goes through the package's own mapping with the cancel passed in, so it
    /// is classified exactly as the live client classifies a cancelled child.
    fileprivate static let cancelledLogin = LoginOutcome(
        exitStatus: .signaled(SIGTERM),
        standardError: Data(),
        cancelWasRequested: true
    )

    /// A representative sign in that was not completed with this kind, mapped
    /// from its ending by the package's own rule.
    fileprivate static func notCompletedLogin(_ kind: LoginFailure.Kind) -> LoginOutcome {
        switch kind {
        case .timedOut:
            LoginOutcome(
                exitStatus: .exited(3),
                standardError: failedSignInStandardError(error: "authentication timeout")
            )
        case .accessDenied:
            LoginOutcome(
                exitStatus: .exited(3),
                standardError: failedSignInStandardError(error: "OAuth error: access_denied")
            )
        case .cancelled:
            cancelledLogin
        case .notClassified:
            LoginOutcome(
                exitStatus: .exited(3),
                standardError: failedSignInStandardError(error: "OAuth error: server_error")
            )
        }
    }

    /// The stderr the CLI writes for a sign in that failed with this error: its
    /// progress lines, then the failed envelope it exits 3 with.
    ///
    /// The line the CLI prints between the two, naming the sign in address, is
    /// left out, since the real one carries the machine's install id and a
    /// scripted ending has no business carrying even a made up one.
    ///
    /// The package's own tests build the same text, address line included, in
    /// their `signInStandardError(failingWith:)`. The copies are separate because
    /// they live in different products, and this one ships to apps, so it must not
    /// export a helper for the package's tests to share.
    private static func failedSignInStandardError(error: String) -> Data {
        Data(
            """

            Opening browser for authentication...

            Waiting for authentication...
            {
              "ok": false,
              "error": "login failed: \(error)",
              "code": "auth",
              "hint": "Run: hey auth login"
            }

            """.utf8
        )
    }
}
