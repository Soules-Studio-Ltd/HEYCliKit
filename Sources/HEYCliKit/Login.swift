import Foundation

/// How a sign in ended.
///
/// The CLI's exit decides, unless the app asked the sign in to stop: a cancelled
/// sign in was not completed whatever the child made of the SIGTERM it was sent.
/// The CLI prints a success envelope on stdout when the flow worked, but the
/// package never reads it, and an app confirms the session with
/// ``HEYClient/signInStatus()`` anyway.
public enum LoginOutcome: Sendable, Hashable {
    /// The CLI exited cleanly and nobody cancelled, so it reports sign in as done.
    case completed
    /// The CLI ended any other way: a non zero exit, or a signal, including the
    /// SIGTERM a cancel sends, and every ending at all once a cancel was asked
    /// for. The app treats every one of these as not signed in.
    case notCompleted(LoginFailure)
}

/// How a sign in that was not completed ended.
public struct LoginFailure: Sendable, Hashable {
    /// How the login process ended.
    public let exitStatus: ProcessExitStatus
    /// The process's stderr as text, decoded leniently. Never parsed.
    public let standardError: String

    /// Builds one, so a test can state the outcome it wants a scripted login to
    /// resolve with. The package builds its own from the child it spawned.
    public init(exitStatus: ProcessExitStatus, standardError: String) {
        self.exitStatus = exitStatus
        self.standardError = standardError
    }
}

/// What a running sign in left the caller holding: a way to stop it, and how it
/// ended.
///
/// A handle is obtained from ``HEYClient/login()`` alone. Two logins spawn two
/// children, and neither knows about the other: whether that can happen is the
/// app's business.
public struct LoginHandle: Sendable {
    /// Asks the login process to stop, and settles the sign in as not completed.
    ///
    /// It sends SIGTERM, which is a request the CLI is free to answer any way it
    /// likes, so the handle remembers the cancel rather than reading the answer:
    /// the outcome is not completed whatever ending the child comes to, carrying
    /// that ending as it was. A cancel once the outcome has been decided is a no
    /// op, exactly as signalling a child that has already ended is.
    public func cancel() {
        cancelSignIn()
    }

    /// Waits for the login process to end and reports how.
    ///
    /// It never throws and it never times out (ADR 0002): a sign in that waits for
    /// a browser waits until the app cancels it. It is safe to await from more
    /// than one place: the outcome is decided once, when the first awaiter is
    /// answered, and every awaiter is told that same one. Cancelling the task that
    /// awaits it cancels the sign in, the way cancelling a watch's reader ends the
    /// watch, and the outcome still resolves, as the cancelled sign in it was, for
    /// anyone else awaiting it.
    public var outcome: LoginOutcome {
        get async { await awaitOutcome() }
    }

    private let cancelSignIn: @Sendable () -> Void
    private let awaitOutcome: @Sendable () async -> LoginOutcome

    /// Builds a handle from the two closures that follow one login.
    ///
    /// It is `package` rather than public for the same reason the client's own
    /// initialiser is (ADR 0003): a handle comes from the live client or from the
    /// fixture client in the test support product, and from nowhere else.
    package init(
        cancel: @escaping @Sendable () -> Void,
        outcome: @escaping @Sendable () async -> LoginOutcome
    ) {
        cancelSignIn = cancel
        awaitOutcome = outcome
    }
}

extension LoginOutcome {
    /// The outcome the package reports for a login child that ended this way.
    ///
    /// Exit 0 that nobody cancelled is a completed sign in. Everything else, a non
    /// zero exit and every signal alike, is a sign in that was not completed,
    /// carrying the child's own stderr so an app can log what the CLI said on its
    /// way out.
    ///
    /// A cancel decides the outcome on its own, whatever the child's ending turns
    /// out to be. SIGTERM is a request, and a CLI is free to trap it and shut down
    /// cleanly: hey 1.4.0 dies on it, but a build that exited 0 instead would turn
    /// a sign in the user walked away from into a completed one, which is the one
    /// answer the handle must never give. The ending is still carried as it was,
    /// so nothing about the child is invented.
    ///
    /// A child the package stopped for writing more stderr than the output ceiling
    /// is not completed for the same reason, whatever its exit: it ended because it
    /// was told to, not because the sign in finished.
    ///
    /// It is `package` so the fixture client maps scripted bytes exactly as the
    /// live client maps a real child's ending.
    package init(
        exitStatus: ProcessExitStatus,
        standardError: Data,
        cancelWasRequested: Bool = false,
        standardErrorWasTooLarge: Bool = false
    ) {
        switch exitStatus {
        case .exited(0) where !cancelWasRequested && !standardErrorWasTooLarge:
            self = .completed
        case .exited, .signaled:
            self = .notCompleted(
                LoginFailure(
                    exitStatus: exitStatus,
                    standardError: String(decoding: standardError, as: UTF8.self)
                )
            )
        }
    }
}
