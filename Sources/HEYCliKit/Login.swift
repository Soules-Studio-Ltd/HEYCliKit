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

/// How a sign in that was not completed ended, and why, as far as the package
/// can tell.
///
/// The kind is the part an app may send anywhere, such as a usage event saying
/// a sign in was not completed. The stderr is for the app's local logs and
/// nowhere else: the CLI prints the address of the sign in page there, and that
/// address carries the install id of the machine. The description leaves the
/// stderr out, so an app may log it verbatim.
public struct LoginFailure: Sendable, Hashable {
    /// Why a sign in was not completed, in words that never carry the CLI's text.
    ///
    /// The package decides it, because knowing what the CLI prints for each
    /// ending is the package's job and not the app's. Adding a case later is a
    /// source break for an app that switches over these exhaustively, exactly as
    /// adding one to ``HEYCliKitError`` is, so a new case waits for a version
    /// that is allowed to break.
    public enum Kind: Sendable, Hashable, CaseIterable {
        /// The CLI gave up waiting for the browser to come back, which it does on
        /// its own after five minutes.
        case timedOut
        /// The user declined the sign in on HEY's page.
        case accessDenied
        /// The app asked the sign in to stop, whatever ending the child came to
        /// afterwards.
        case cancelled
        /// Anything else: another exit, a signal nobody asked for, an error the
        /// package has no name for, or a sign in whose stderr is gone because the
        /// package stopped it past the output ceiling. The stderr, where there is
        /// any, is what says more, in the app's own logs.
        case notClassified
    }

    /// How the login process ended.
    public let exitStatus: ProcessExitStatus
    /// The process's stderr as text, decoded leniently.
    ///
    /// It is never decoded as JSON. The package only looks in it for the error
    /// words that decide ``kind``, and otherwise carries it for the app to log.
    /// It holds the sign in address with the machine's install id, so it is for
    /// local logs only and never for anything that leaves the machine.
    public let standardError: String
    /// Why the sign in was not completed. This, and not the stderr, is what an
    /// app sends anywhere.
    public let kind: Kind

    /// Builds one from how the process ended, classifying the kind from that
    /// ending the way the package does, so a test can state the outcome it wants
    /// a scripted login to resolve with. The package builds its own from the child
    /// it spawned.
    ///
    /// The kind is never ``Kind/cancelled`` from here: only the package knows that
    /// a cancel was asked for, and an ending alone cannot say so. A test that
    /// wants a cancelled sign in states it with
    /// ``init(exitStatus:standardError:kind:)``.
    public init(exitStatus: ProcessExitStatus, standardError: String) {
        self.init(
            exitStatus: exitStatus,
            standardError: standardError,
            kind: Kind(
                exitStatus: exitStatus,
                standardError: standardError,
                cancelWasRequested: false
            )
        )
    }

    /// Builds one with the kind stated rather than classified, so a test can state
    /// a cancelled sign in, or any pairing of an ending and a kind it needs.
    public init(exitStatus: ProcessExitStatus, standardError: String, kind: Kind) {
        self.exitStatus = exitStatus
        self.standardError = standardError
        self.kind = kind
    }
}

extension LoginFailure: CustomStringConvertible {
    /// The kind and the ending, in the package's own words, and never the stderr.
    ///
    /// An app may log it verbatim, and so may it log a ``LoginOutcome`` as it is,
    /// since an outcome's own description is built from this one. The stderr
    /// holds the sign in address with the machine's install id, so nothing read
    /// from it ever reaches this text: the kind is named by the package, and the
    /// ending is a number.
    public var description: String {
        switch kind {
        case .timedOut:
            "The sign in timed out (\(exitStatus))."
        case .accessDenied:
            "The sign in was declined (\(exitStatus))."
        case .cancelled:
            "The sign in was cancelled (\(exitStatus))."
        case .notClassified:
            "The sign in was not completed, for a reason the package has no name for (\(exitStatus))."
        }
    }
}

extension LoginFailure.Kind {
    /// The kind of a sign in that ended this way, read from the CLI's own words.
    ///
    /// Checked against the hey CLI source at versions 1.4.0, 1.4.3 and 1.6.0,
    /// which all fail a sign in the same way. `hey auth login` wraps whatever went
    /// wrong in `internal/cmd/auth.go` as
    /// `apierr.ErrAuth(fmt.Sprintf("login failed: %v", err))`, prints that as an
    /// indented failed envelope on stderr, `"error": "login failed: ..."` beside
    /// `"code": "auth"`, and exits 3. The errors it wraps come from
    /// `waitForCallback` in `internal/auth/auth.go`:
    ///
    /// - `case <-time.After(5 * time.Minute): return "", fmt.Errorf("authentication timeout")`
    ///   when the browser never comes back.
    /// - `fmt.Errorf("OAuth error: %s", errParam)` when HEY's page reports an
    ///   error, which is `access_denied` when the user declines.
    /// - `context deadline exceeded`, from the six minute
    ///   `context.WithTimeout(cmd.Context(), 6*time.Minute)` around the whole
    ///   flow. The five minute wait always fires first, but this is a timeout
    ///   too should it ever surface.
    /// - `state mismatch: CSRF protection failed` and
    ///   `token exchange failed: ...`, among others, which the package has no
    ///   name for.
    ///
    /// The rule, in order:
    ///
    /// 1. A cancel the app asked for is ``cancelled``, whatever the child did
    ///    next, because the handle reports a cancelled sign in as one the user
    ///    walked away from, including one that timed out on its way down.
    /// 2. Anything but exit 3 is ``notClassified``: the CLI prints the envelope
    ///    and exits 3 together, so the words under any other ending did not come
    ///    from that envelope.
    /// 3. Stderr holding `"login failed: authentication timeout` or
    ///    `"login failed: context deadline exceeded` is ``timedOut``.
    /// 4. Stderr holding `"login failed: OAuth error: access_denied` is
    ///    ``accessDenied``.
    /// 5. Everything else is ``notClassified``, empty stderr included, which is
    ///    what a sign in stopped past the output ceiling leaves.
    ///
    /// It is a check for the error string as the envelope prints it, quotes and
    /// all, and not a decoded field. Each anchor keeps the opening quote and leaves
    /// off the closing one, so text the CLI might append to any of the three
    /// errors one day still matches. Stderr is not an envelope: the CLI logs its
    /// progress there first, the sign in address included, so decoding it as JSON
    /// would fail on the first line. The opening quote anchors the match to a
    /// quoted error, which only the envelope prints in the CLI versions checked,
    /// and it is also what keeps the address from ever matching, since a URL
    /// cannot hold a bare quote whatever its state or redirect carries. None of these errors contain a character JSON escapes,
    /// so the envelope prints them exactly as written here.
    init(exitStatus: ProcessExitStatus, standardError: String, cancelWasRequested: Bool) {
        if cancelWasRequested {
            self = .cancelled
        } else if exitStatus != .exited(3) {
            self = .notClassified
        } else if Self.timedOutErrors.contains(where: standardError.contains) {
            self = .timedOut
        } else if standardError.contains(Self.accessDeniedError) {
            self = .accessDenied
        } else {
            self = .notClassified
        }
    }

    /// The start of the envelope's error strings for a sign in that ran out of
    /// time, each with its opening quote and no closing one.
    private static let timedOutErrors = [
        #""login failed: authentication timeout"#,
        #""login failed: context deadline exceeded"#,
    ]

    /// The start of the envelope's error string for a sign in the user declined,
    /// with its opening quote and no closing one.
    private static let accessDeniedError = #""login failed: OAuth error: access_denied"#
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
    /// that ending as it was, with the kind ``LoginFailure/Kind/cancelled``. A
    /// cancel once the outcome has been decided is a no op, exactly as signalling a
    /// child that has already ended is.
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
    /// The failure's kind is classified here as well, beside the ending it reads,
    /// with the cancel passed through so a cancelled sign in says so whatever the
    /// CLI printed on its way out. A child stopped past the output ceiling needs no
    /// case of its own: none of its stderr was kept, so the rule finds no error to
    /// read and the sign in is not classified.
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
            let text = String(decoding: standardError, as: UTF8.self)
            self = .notCompleted(
                LoginFailure(
                    exitStatus: exitStatus,
                    standardError: text,
                    kind: LoginFailure.Kind(
                        exitStatus: exitStatus,
                        standardError: text,
                        cancelWasRequested: cancelWasRequested
                    )
                )
            )
        }
    }
}
