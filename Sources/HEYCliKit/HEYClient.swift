import Foundation
import Synchronization

/// The typed client an app calls.
///
/// It is a struct of closures rather than a protocol, so adding an operation is
/// never a source breaking change for the apps that hold one (ADR 0003). The
/// closures themselves are `package`: an app calls an operation through its
/// public method, so every operation has one spelling and can grow a labelled
/// optional parameter without breaking anybody. There are two ways to obtain a
/// client: ``live(executable:accountSelection:environment:)``, which spawns the
/// executable the app supplies, and the fixture client in the test support
/// product.
///
/// A client built by ``live(executable:accountSelection:environment:)`` throws only
/// ``HEYCliKitError``, plus `CancellationError` when the calling task is cancelled:
/// the child is terminated and the cancellation is reported, never the exit the
/// termination caused. The operations are declared with a plain `throws` because
/// the fixture client throws its own failure when an operation was not scripted.
public struct HEYClient: Sendable {
    // One closure per operation, each named for its operation with an
    // `Operation` suffix because a stored property cannot share a name with the
    // method that calls it. What every one of them means is documented on that
    // method, which is the only way to call an operation from outside the
    // package.

    /// Answers ``signInStatus()``.
    package let signInStatusOperation: @Sendable () async throws -> SignInStatus
    /// Answers ``version()``.
    package let versionOperation: @Sendable () async throws -> CLIVersion
    /// Answers ``mailAccounts()``.
    package let mailAccountsOperation: @Sendable () async throws -> [MailAccount]
    /// Answers ``boxPage(_:pageSize:cursor:)``.
    package let boxPageOperation: @Sendable (BoxKind, PageSize, Cursor?) async throws -> BoxPage
    /// Answers ``screener()``.
    package let screenerOperation: @Sendable () async throws -> Screener
    /// Answers ``approveScreenerEntries(_:)``.
    package let approveScreenerEntriesOperation: @Sendable (ScreenerApproval) async throws
        -> [ScreenerDecision]
    /// Answers ``denyScreenerEntries(_:)``.
    package let denyScreenerEntriesOperation: @Sendable (NonEmptySet<ScreenerEntry.ID>) async throws
        -> [ScreenerDecision]
    /// Answers ``move(_:to:)``.
    package let moveOperation: @Sendable (NonEmptySet<Posting.ID>, BoxKind) async throws -> Void
    /// Answers ``markSeen(_:)``.
    package let markSeenOperation: @Sendable (NonEmptySet<Posting.ID>) async throws -> Void
    /// Answers ``markUnseen(_:)``.
    package let markUnseenOperation: @Sendable (NonEmptySet<Posting.ID>) async throws -> Void
    /// Answers ``watch(_:since:)``.
    package let watchOperation: @Sendable (NonEmptySet<BoxKind>, Date?) async throws
        -> AsyncThrowingStream<WatchLine, any Error>
    /// Answers ``login()``.
    package let loginOperation: @Sendable () async throws -> LoginHandle
    /// Answers ``logout()``.
    package let logoutOperation: @Sendable () async throws -> Void

    /// Builds a client from one closure per operation.
    ///
    /// It is `package` rather than public so adding an operation is never a source
    /// breaking change for an app (ADR 0003). The fixture client in the test support
    /// product is the supported way to build a client that answers from fixtures.
    package init(
        signInStatus: @escaping @Sendable () async throws -> SignInStatus,
        version: @escaping @Sendable () async throws -> CLIVersion,
        mailAccounts: @escaping @Sendable () async throws -> [MailAccount],
        boxPage: @escaping @Sendable (BoxKind, PageSize, Cursor?) async throws -> BoxPage,
        screener: @escaping @Sendable () async throws -> Screener,
        approveScreenerEntries: @escaping @Sendable (ScreenerApproval) async throws -> [ScreenerDecision],
        denyScreenerEntries: @escaping @Sendable (NonEmptySet<ScreenerEntry.ID>) async throws
            -> [ScreenerDecision],
        move: @escaping @Sendable (NonEmptySet<Posting.ID>, BoxKind) async throws -> Void,
        markSeen: @escaping @Sendable (NonEmptySet<Posting.ID>) async throws -> Void,
        markUnseen: @escaping @Sendable (NonEmptySet<Posting.ID>) async throws -> Void,
        watch: @escaping @Sendable (NonEmptySet<BoxKind>, Date?) async throws
            -> AsyncThrowingStream<WatchLine, any Error>,
        login: @escaping @Sendable () async throws -> LoginHandle,
        logout: @escaping @Sendable () async throws -> Void
    ) {
        signInStatusOperation = signInStatus
        versionOperation = version
        mailAccountsOperation = mailAccounts
        boxPageOperation = boxPage
        screenerOperation = screener
        approveScreenerEntriesOperation = approveScreenerEntries
        denyScreenerEntriesOperation = denyScreenerEntries
        moveOperation = move
        markSeenOperation = markSeen
        markUnseenOperation = markUnseen
        watchOperation = watch
        loginOperation = login
        logoutOperation = logout
    }

    /// Reports whether the CLI is signed in.
    public func signInStatus() async throws -> SignInStatus {
        try await signInStatusOperation()
    }

    /// Reports the version of the executable the client runs.
    public func version() async throws -> CLIVersion {
        try await versionOperation()
    }

    /// Lists the mail accounts linked to the signed in user.
    public func mailAccounts() async throws -> [MailAccount] {
        try await mailAccountsOperation()
    }

    /// Reads one page of a box.
    ///
    /// The page size defaults to the first page HEY serves, and a cursor is only
    /// passed for a page after the first, which is why both carry a default.
    public func boxPage(
        _ kind: BoxKind,
        pageSize: PageSize = .minimum,
        cursor: Cursor? = nil
    ) async throws -> BoxPage {
        try await boxPageOperation(kind, pageSize, cursor)
    }

    /// Lists the senders waiting in the Screener, with the total count beside them.
    public func screener() async throws -> Screener {
        try await screenerOperation()
    }

    /// Lets the senders of the given entries through, and reports what HEY confirmed.
    public func approveScreenerEntries(
        _ approval: ScreenerApproval
    ) async throws -> [ScreenerDecision] {
        try await approveScreenerEntriesOperation(approval)
    }

    /// Turns the senders of the given entries away, and reports what HEY confirmed.
    public func denyScreenerEntries(
        _ entryIDs: NonEmptySet<ScreenerEntry.ID>
    ) async throws -> [ScreenerDecision] {
        try await denyScreenerEntriesOperation(entryIDs)
    }

    /// Moves a set of postings to a box.
    ///
    /// A move succeeds or fails as a whole, it returns nothing because HEY confirms
    /// it with a summary only, and nothing is ever retried.
    ///
    /// The app names its own menu items on top of this: Reply Later and Set Aside
    /// are what a user sees, and the package only knows the box kinds they stand
    /// for. The CLI accepts five destinations and Bubble Up is not one of them, so
    /// any box kind is passed through and the CLI's own error is what an app that
    /// asks for an impossible destination gets back.
    public func move(_ postingIDs: NonEmptySet<Posting.ID>, to kind: BoxKind) async throws {
        try await moveOperation(postingIDs, kind)
    }

    /// Marks a set of postings as opened by the user.
    public func markSeen(_ postingIDs: NonEmptySet<Posting.ID>) async throws {
        try await markSeenOperation(postingIDs)
    }

    /// Marks a set of postings as not opened by the user.
    public func markUnseen(_ postingIDs: NonEmptySet<Posting.ID>) async throws {
        try await markUnseenOperation(postingIDs)
    }

    /// Follows a set of boxes as a long lived process and yields one element per
    /// line the CLI prints.
    ///
    /// A since date is passed only when there is one, so a watch that was never
    /// running asks for nothing it missed. The call itself throws when the watch
    /// could not be started at all, so a launch failure arrives where every other
    /// operation's failure does. What happens after the watch started travels on
    /// the stream, and cancelling the task that reads it terminates the child and
    /// ends the stream without throwing.
    ///
    /// The stream holds a bounded number of lines for a reader that has not taken
    /// them yet. An app that falls that far behind is sent the lines it had kept,
    /// exactly as the CLI printed them, and then
    /// ``HEYCliKitError/watchFellBehind(limitInLines:)``, and the child is
    /// terminated. Nothing stands in for the lines that were dropped: the app
    /// starts another watch.
    public func watch(
        _ boxKinds: NonEmptySet<BoxKind>,
        since: Date? = nil
    ) async throws -> AsyncThrowingStream<WatchLine, any Error> {
        try await watchOperation(boxKinds, since)
    }

    /// Starts the CLI's sign in flow and returns the handle that follows it.
    ///
    /// The package runs this only because the app called it: it never signs in on
    /// its own initiative and never as a retry after a signed out result (ADR
    /// 0002). The CLI opens a browser itself and waits for the user, so the call
    /// throws only when the child could not be launched at all. Everything after
    /// that travels on ``LoginHandle``.
    public func login() async throws -> LoginHandle {
        try await loginOperation()
    }

    /// Signs the CLI out.
    public func logout() async throws {
        try await logoutOperation()
    }
}

extension HEYClient {
    /// Builds a client that spawns the given `hey` executable.
    ///
    /// The package never searches for an executable (ADR 0001): the app hands it the
    /// location of the copy it ships. The account selection is fixed here and passed
    /// on every spawn, so a change made in the user's terminal cannot alter what the
    /// app sees. The child sees a fixed allowlist of the app's own environment, with
    /// `HOME` and `PATH` pinned, and the extra environment overlaid on that rather
    /// than on the app's whole environment, so nothing exported into the user's
    /// session can point the CLI at another host or move its credentials (ADR 0005).
    /// Anything an app relied on the child inheriting has to be passed here.
    ///
    /// Every child is held to fixed ceilings on what it prints, and a child that is
    /// asked to stop and does not is killed after a grace (ADR 0006). A ceiling
    /// that is passed throws its own case, never a short answer.
    public static func live(
        executable: URL,
        accountSelection: AccountSelection = .all,
        environment: [String: String] = [:]
    ) -> HEYClient {
        HEYClient(
            runner: .live(limits: .standard),
            executable: executable,
            accountSelection: accountSelection,
            environment: environment,
            limits: .standard
        )
    }

    /// Builds a client over any runner, so the package's tests can script the CLI's
    /// answers without spawning anything.
    ///
    /// The limits are the ones the watch stream is held to, and should be the ones
    /// the runner was built with, so the ceiling a watch reports is the one that
    /// was passed.
    init(
        runner: ProcessRunner,
        executable: URL,
        accountSelection: AccountSelection,
        environment: [String: String],
        limits: RunnerLimits = .standard
    ) {
        @Sendable
        func spawn(_ commandWords: [String], options: [String] = []) -> SpawnDescription {
            SpawnDescription.forCommand(
                commandWords,
                options: options,
                executable: executable,
                accountSelection: accountSelection,
                extraEnvironment: environment
            )
        }

        @Sendable
        func spawn(_ commandWords: String..., options: [String] = []) -> SpawnDescription {
            spawn(commandWords, options: options)
        }

        /// The ids of a mutation as command arguments, in the order they were given.
        ///
        /// A non empty set keeps the order it was built in, and that is the order
        /// that reaches the command line, so nothing is reordered here. Rendering
        /// lives here rather than on ``Posting/ID`` because the shape means nothing
        /// outside a command line.
        @Sendable
        func idArguments(_ postingIDs: NonEmptySet<Posting.ID>) -> [String] {
            postingIDs.elements.map { String($0.rawValue) }
        }

        self.init(
            signInStatus: {
                try await runner.decoding(SignInStatus.self, from: spawn("auth", "status"))
            },
            version: {
                try await runner.decoding(CLIVersion.self, from: spawn("version"))
            },
            mailAccounts: {
                try await runner.decoding(MailAccountList.self, from: spawn("account", "list")).mailAccounts
            },
            boxPage: { kind, pageSize, cursor in
                // The cursor is only passed when there is one: HEY reads the first
                // page when `--page` is absent, and an empty value is not a cursor.
                var options = ["--limit", String(pageSize.count)]
                if let cursor {
                    options += ["--page", cursor.rawValue]
                }

                return try await runner.decoding(
                    BoxPagePayload.self,
                    from: spawn("box", "view", kind.rawValue, options: options)
                ).page
            },
            screener: {
                try Screener(
                    await runner.decodingEnvelope([ScreenerEntry].self, from: spawn("screener", "list"))
                )
            },
            approveScreenerEntries: { approval in
                // The Imbox is where an approved sender lands anyway, so the
                // package leaves the argument off rather than spelling out the
                // CLI's own default back to it.
                let destination = approval.destination == .imbox
                    ? []
                    : ["--box", approval.destination.rawValue]

                return try await runner.decoding(
                    [ScreenerDecision].self,
                    from: spawn(
                        ["screener", "approve"]
                            + approval.entryIDs.elements.map(\.argumentValue)
                            + destination
                            + (approval.markSeen ? ["--seen"] : [])
                    )
                )
            },
            denyScreenerEntries: { entryIDs in
                try await runner.decoding(
                    [ScreenerDecision].self,
                    from: spawn(["screener", "deny"] + entryIDs.elements.map(\.argumentValue))
                )
            },
            move: { postingIDs, kind in
                try await runner.confirming(
                    spawn(["move"] + idArguments(postingIDs), options: ["--to", kind.rawValue])
                )
            },
            markSeen: { postingIDs in
                try await runner.confirming(spawn(["seen"] + idArguments(postingIDs)))
            },
            markUnseen: { postingIDs in
                try await runner.confirming(spawn(["unseen"] + idArguments(postingIDs)))
            },
            watch: { boxKinds, since in
                // One --box per kind, in the order the set was built, and --since
                // only when the caller had a date. The CLI's own --calendar is
                // never passed: calendar lines are out of the package's scope.
                let boxOptions = boxKinds.elements.flatMap { ["--box", $0.rawValue] }
                let sinceOptions = since.map { ["--since", $0.formatted(.iso8601)] } ?? []

                return watchLines(
                    from: try await runner.start(spawn(["watch"], options: boxOptions + sinceOptions)),
                    limits: limits
                )
            },
            login: {
                loginHandle(
                    for: try await runner.start(
                        SpawnDescription.forLogin(
                            executable: executable,
                            extraEnvironment: environment
                        )
                    )
                )
            },
            logout: {
                try await runner.confirming(spawn("auth", "logout"))
            }
        )
    }
}

/// Turns one long lived child into the handle that follows a sign in.
///
/// The child's stdout is discarded at the spawn and never read, because the
/// envelope the CLI prints there says nothing the exit does not, and its stderr
/// is drained by the runner on its way to the ending, so neither stream can fill
/// a pipe and stall the flow, and no buffer of lines nobody reads can end a sign
/// in for being chatty.
///
/// A cancel is remembered here rather than read back off the child's ending,
/// because SIGTERM is a request and a CLI is free to answer it with a clean exit:
/// a sign in the app stopped is not a completed one whichever way its child went
/// (ADR 0002).
///
/// The ending is awaited inside a cancellation handler that terminates the child,
/// so a `.task` that awaits the outcome and goes away ends the sign in exactly as
/// dropping a watch's stream ends the watch. The outcome still arrives, as the
/// cancelled sign in it was, for every other awaiter.
private func loginHandle(for handle: ProcessHandle) -> LoginHandle {
    let signIn = SignInProgress()

    @Sendable
    func cancel() {
        signIn.recordCancel()
        handle.terminate()
    }

    return LoginHandle(
        cancel: cancel,
        outcome: {
            let ending = await withTaskCancellationHandler {
                await handle.ending()
            } onCancel: {
                cancel()
            }

            return signIn.outcome(for: ending)
        }
    )
}

/// What one sign in has come to: whether the app asked it to stop, and the outcome
/// once that has been decided.
///
/// The outcome is decided once, by whoever asks for it first, and everybody after
/// is told that same one, so two awaiters can never disagree about a sign in. A
/// cancel that arrives after it was decided changes nothing, exactly as asking a
/// child that has already ended to stop signals nobody.
private final class SignInProgress: Sendable {
    private struct State {
        var cancelWasRequested = false
        var decided: LoginOutcome?
    }

    private let state = Mutex(State())

    /// Records that the app asked this sign in to stop.
    func recordCancel() {
        state.withLock { state in
            guard state.decided == nil else { return }

            state.cancelWasRequested = true
        }
    }

    /// The outcome for a child that ended this way, decided the first time it is
    /// asked for and unchanged from then on.
    func outcome(for ending: ProcessEnding) -> LoginOutcome {
        state.withLock { state in
            if let decided = state.decided { return decided }

            let outcome = LoginOutcome(
                exitStatus: ending.exitStatus,
                standardError: ending.standardError,
                cancelWasRequested: state.cancelWasRequested,
                standardErrorWasTooLarge: ending.standardErrorWasTooLarge
            )
            state.decided = outcome

            return outcome
        }
    }
}

/// Turns one long lived child into the watch's own stream of lines.
///
/// A pump task reads the child's stdout, decodes each line and yields it, so no
/// decoding happens where the caller reads and a slow reader only fills a buffer.
/// The buffer holds the watch buffer bound's worth of lines. An app that falls
/// that far behind is not catching up, so the pump terminates the child and ends
/// the stream with ``HEYCliKitError/watchFellBehind(limitInLines:)``. The line
/// that did not fit is the one dropped, never an older one, so what the app
/// already has is exactly what the CLI printed first, the first ready included.
///
/// The pump never throws on a line: an undecodable line is an unrecognised line.
/// It throws from how the child ended, and the decoder is what decides that, so a
/// scripted watch from the fixture client ends exactly as this one ends a live
/// child. It also throws where the package stopped reading: the runner's own
/// failure for a line past the line ceiling or a buffer this pump fell behind,
/// and ``HEYCliKitError/outputTooLarge(limitInBytes:)`` for a child terminated for
/// writing too much stderr, whose signal is the package's doing and not the CLI's.
///
/// Only ``AsyncThrowingStream/Continuation/onTermination-swift.property``
/// terminates the child, and only when the stream ended because the reader was
/// cancelled: a stream that ended because the child did has nothing left to
/// terminate. Dropping the stream counts as cancelling it, so a watch nobody
/// reads any more does not outlive its reader. A child that ignores SIGTERM is
/// sent SIGKILL once the termination grace has passed (ADR 0006).
private func watchLines(
    from handle: ProcessHandle,
    limits: RunnerLimits
) -> AsyncThrowingStream<WatchLine, any Error> {
    let (stream, continuation) = AsyncThrowingStream<WatchLine, any Error>.makeStream(
        bufferingPolicy: .bufferingOldest(limits.watchBufferInLines)
    )

    let pump = Task {
        var decoder = WatchLineDecoder()

        do {
            for try await line in handle.lines {
                switch continuation.yield(decoder.decode(line)) {
                case .enqueued:
                    continue
                case .dropped:
                    handle.terminate()
                    continuation.finish(
                        throwing: HEYCliKitError.watchFellBehind(limitInLines: limits.watchBufferInLines)
                    )

                    return
                case .terminated:
                    // The reader has gone, and the stream ending has already
                    // asked the child to stop.
                    return
                @unknown default:
                    // Read as the reader being gone, exactly as the runner reads
                    // it, since a result nobody knows is not a line delivered.
                    return
                }
            }
        } catch {
            // The runner stopped reading and has already terminated the child, so
            // its failure is the watch's.
            continuation.finish(throwing: error)

            return
        }

        let ending = await handle.ending()
        guard !ending.standardErrorWasTooLarge else {
            continuation.finish(
                throwing: HEYCliKitError.outputTooLarge(limitInBytes: limits.outputCeilingInBytes)
            )

            return
        }

        decoder.finish(
            continuation,
            exitStatus: ending.exitStatus,
            standardError: ending.standardError
        )
    }

    continuation.onTermination = { reason in
        if case .cancelled = reason {
            handle.terminate()
        }

        pump.cancel()
    }

    return stream
}

extension ProcessRunner {
    /// Runs one spawn and turns its output into a payload or a mapped error.
    func decoding<Payload: Decodable>(
        _ payloadType: Payload.Type,
        from description: SpawnDescription
    ) async throws -> Payload {
        try await decodingEnvelope(payloadType, from: description).data
    }

    /// Runs one spawn and keeps the envelope's own fields, for the one operation
    /// that reads something beside the payload.
    func decodingEnvelope<Payload: Decodable>(
        _ payloadType: Payload.Type,
        from description: SpawnDescription
    ) async throws -> DecodedEnvelope<Payload> {
        let output = try await run(description)

        return try decodeEnvelope(
            payloadType,
            exitStatus: output.exitStatus,
            standardOutput: output.stdout,
            standardError: output.stderr
        )
    }

    /// Runs one mutation and confirms it, or throws the mapped error.
    func confirming(_ description: SpawnDescription) async throws {
        let output = try await run(description)

        try throwIfFailed(
            exitStatus: output.exitStatus,
            standardOutput: output.stdout,
            standardError: output.stderr
        )
    }
}

extension SpawnDescription {
    /// The spawn rules every operation shares, whichever way it talks to the user.
    ///
    /// The working directory is the user's home folder, so a project's local config
    /// can never change what the app sees, and stdin is `/dev/null`, so the CLI can
    /// never wait on input the app is not there to give. The environment is
    /// ``ChildEnvironment``'s: a fixed allowlist of the app's own with `HOME` and
    /// `PATH` pinned, the extra environment overlaid on that, and
    /// `HEY_NONINTERACTIVE` settled last, either forced on or removed, so a value
    /// the app inherited cannot leak in either way. The process environment is read
    /// here and nowhere else, and the home folder is read once and used both as the
    /// pinned `HOME` and as the working directory, so the two can never disagree.
    private static func forSpawn(
        arguments: [String],
        nonInteractive: Bool,
        standardOutput: StandardOutputPolicy,
        executable: URL,
        extraEnvironment: [String: String]
    ) -> SpawnDescription {
        let home = FileManager.default.homeDirectoryForCurrentUser

        return SpawnDescription(
            executable: executable,
            arguments: arguments,
            environment: ChildEnvironment.build(
                inherited: ProcessInfo.processInfo.environment,
                extra: extraEnvironment,
                home: home,
                nonInteractive: nonInteractive
            ),
            workingDirectory: home,
            standardInput: .devNull,
            standardOutput: standardOutput
        )
    }

    /// The spawn rules every command but login takes.
    ///
    /// `HEY_NONINTERACTIVE` is forced on, so the CLI can never wait for input. Every
    /// command carries `--json` and the client's account selection, and an
    /// operation's own options follow them.
    static func forCommand(
        _ commandWords: [String],
        options: [String] = [],
        executable: URL,
        accountSelection: AccountSelection,
        extraEnvironment: [String: String]
    ) -> SpawnDescription {
        forSpawn(
            arguments: commandWords + ["--json", "--account", accountSelection.argumentValue] + options,
            nonInteractive: true,
            standardOutput: .lines,
            executable: executable,
            extraEnvironment: extraEnvironment
        )
    }

    /// The spawn rules login takes instead.
    ///
    /// Login is the one command that talks to the user, through a browser the CLI
    /// opens itself, so `HEY_NONINTERACTIVE` is removed rather than forced on. No
    /// `--json`, because the CLI prints its envelope on stdout regardless and the
    /// package never reads it, which is also why stdout is discarded rather than
    /// read, and no `--account`, because signing in is about the user and not
    /// about a mail account.
    static func forLogin(
        executable: URL,
        extraEnvironment: [String: String]
    ) -> SpawnDescription {
        forSpawn(
            arguments: ["auth", "login"],
            nonInteractive: false,
            standardOutput: .discarded,
            executable: executable,
            extraEnvironment: extraEnvironment
        )
    }
}
