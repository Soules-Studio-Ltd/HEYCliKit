import Foundation
import Testing

@testable import HEYCliKit
import HEYCliKitTestSupport

/// Login is exercised over the scripted runner: the client is the real one, and
/// the only thing replaced is the child it would have spawned. Nothing here ever
/// opens a browser.
@Suite("Login")
struct LoginTests {
    /// Starts a login and hands back its handle, the child the test drives and the
    /// script that recorded the spawn.
    private func startLogin(
        environment: [String: String] = ["HEY_CLI_KIT_TEST": "yes"]
    ) async throws -> (handle: LoginHandle, process: ScriptedProcess, script: ProcessRunnerScript) {
        let (client, script) = makeScriptedClient(outputs: [], environment: environment)
        let handle = try await client.login()

        return (handle, try #require(script.startedProcesses.first), script)
    }

    @Test("A login spawns the sign in flow with no json, no account and no non interactive variable")
    func loginSpawnShape() async throws {
        // The variable is passed in as an extra so the builder is seen removing it
        // after the overlay, rather than merely never adding it. The real process
        // environment is left alone: setting a variable is global and would race
        // every other spawn the suite runs beside this one.
        let login = try await startLogin(
            environment: ["HEY_NONINTERACTIVE": "1", "HEY_CLI_KIT_TEST": "yes"]
        )

        let spawn = try #require(login.script.recordedSpawns.first)
        // The equality is what rules out `--json` and `--account`.
        #expect(spawn.arguments == ["auth", "login"])
        #expect(spawn.environment["HEY_NONINTERACTIVE"] == nil)
        #expect(spawn.environment["HEY_CLI_KIT_TEST"] == "yes")
        // Login takes its own spawn path, so the allowlist is asserted here too. The
        // pinned path is what the assertion is really about: the CLI opens the sign
        // in page with a bare `open` and searches for it, so a login with no path
        // could not reach a browser at all.
        #expect(spawn.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        try expectOnlyAllowedEnvironmentKeys(spawn)
        #expect(spawn.executable == testExecutable)
        #expect(spawn.workingDirectory == FileManager.default.homeDirectoryForCurrentUser)
        #expect(spawn.standardInput == .devNull)
    }

    @Test("A clean exit after the success envelope resolves the handle as completed")
    func cleanExitCompletes() async throws {
        let login = try await startLogin()

        // The envelope the CLI printed in the spawned transcript, which it prints
        // on stdout even though login is not given --json. It is emitted here to
        // show that it changes nothing: stdout is never read and exit 0 alone says
        // the sign in was completed.
        for line in [
            "{",
            "  \"ok\": true,",
            "  \"data\": {",
            "    \"method\": \"oauth\"",
            "  },",
            "  \"summary\": \"Logged in successfully\"",
            "}",
        ] {
            login.process.emit(line)
        }
        login.process.end(.exited(0))

        #expect(await login.handle.outcome == .completed)
    }

    @Test("Cancelling asks the child to stop and resolves the handle as not completed")
    func cancelTerminatesAndDoesNotComplete() async throws {
        let login = try await startLogin()

        login.handle.cancel()

        #expect(
            await login.handle.outcome
                == .notCompleted(
                    LoginFailure(
                        exitStatus: .signaled(SIGTERM),
                        standardError: "",
                        kind: .cancelled
                    )
                )
        )
        #expect(login.process.terminateCallCount == 1)
    }

    @Test("A cancelled sign in that exits cleanly anyway is still not completed")
    func cancelWinsOverACleanExit() async throws {
        // The real CLI dies on SIGTERM, but it is a Go binary and a build that
        // trapped the signal for a graceful shutdown would exit 0 instead. A
        // handle that read the child's exit alone would call that a completed
        // sign in, which is the one answer a cancelled login must never give.
        let login = try await startLogin()
        login.process.endsOnTerminate(.exited(0))

        login.handle.cancel()

        // The ending is reported as it was rather than dressed up as a signal:
        // the cancel decides the outcome, it does not invent the child's exit.
        #expect(
            await login.handle.outcome
                == .notCompleted(
                    LoginFailure(exitStatus: .exited(0), standardError: "", kind: .cancelled)
                )
        )
        #expect(login.process.terminateCallCount == 1)
    }

    @Test("A sign in stopped for writing too much stderr is not completed, even by a clean exit")
    func standardErrorPastTheCeilingNeverCompletes() async throws {
        // Nobody cancelled, but the package stopped the child itself, and a CLI
        // that trapped the SIGTERM could still exit 0. Its sign in did not finish
        // on its own terms, so it is not a completed one.
        let login = try await startLogin()
        login.process.endWithStandardErrorTooLarge(.exited(0))

        #expect(
            await login.handle.outcome
                == .notCompleted(LoginFailure(exitStatus: .exited(0), standardError: ""))
        )
        #expect(login.process.terminateCallCount == 0)
    }

    @Test("A cancelled sign in that ends with a code is not completed either")
    func cancelWinsOverANonZeroExit() async throws {
        let progress = "Waiting for authentication...\n"
        let login = try await startLogin()
        login.process.endsOnTerminate(.exited(143), standardError: progress)

        login.handle.cancel()

        #expect(
            await login.handle.outcome
                == .notCompleted(
                    LoginFailure(
                        exitStatus: .exited(143),
                        standardError: progress,
                        kind: .cancelled
                    )
                )
        )
    }

    @Test(
        "Any ending but a clean exit is a sign in that was not completed",
        arguments: [ProcessExitStatus.exited(143), .exited(1), .signaled(SIGKILL)]
    )
    func otherEndingsDoNotComplete(exitStatus: ProcessExitStatus) async throws {
        let progress = "Waiting for authentication...\n"
        let login = try await startLogin()

        login.process.end(exitStatus, standardError: progress)

        #expect(
            await login.handle.outcome
                == .notCompleted(LoginFailure(exitStatus: exitStatus, standardError: progress))
        )
    }

    @Test("The outcome answers every awaiter, and a cancel after the child ended is a no op")
    func outcomeIsStableOnceTheChildEnded() async throws {
        let login = try await startLogin()
        login.process.end(.exited(0))

        let first = await login.handle.outcome
        login.handle.cancel()
        let second = await login.handle.outcome

        #expect(first == .completed)
        #expect(second == .completed)
        // The child had already ended, so the cancel was counted and nothing else:
        // it never turned a completed sign in into a termination.
        #expect(login.process.terminateCallCount == 1)
    }

    @Test("Cancelling the task that awaits the outcome ends the child, and every awaiter hears how")
    func cancellingTheAwaitingTaskEndsTheChild() async throws {
        let login = try await startLogin()

        let awaiting = Task { await login.handle.outcome }
        // The handler runs at once on a task that is already cancelled when it is
        // installed, so nothing here depends on the task having reached the await.
        awaiting.cancel()

        let cancelled = await awaiting.value
        let other = await login.handle.outcome

        let terminated = LoginOutcome.notCompleted(
            LoginFailure(exitStatus: .signaled(SIGTERM), standardError: "", kind: .cancelled)
        )
        #expect(cancelled == terminated)
        #expect(other == terminated)
        #expect(login.process.terminateCallCount >= 1)
    }

    @Test(
        "A sign in that failed is classified from what the CLI printed on stderr",
        arguments: [
            ("authentication timeout", LoginFailure.Kind.timedOut),
            ("context deadline exceeded", .timedOut),
            ("OAuth error: access_denied", .accessDenied),
            ("OAuth error: server_error", .notClassified),
            ("OAuth error: invalid_request", .notClassified),
            ("state mismatch: CSRF protection failed", .notClassified),
            ("token exchange failed: connection refused", .notClassified),
        ]
    )
    func failureIsClassifiedFromTheEnvelope(error: String, kind: LoginFailure.Kind) async throws {
        let standardError = signInStandardError(failingWith: error)
        let login = try await startLogin()

        login.process.end(.exited(3), standardError: standardError)

        // The stderr is carried whole beside the kind, address and all, since it is
        // what an app logs locally. Only the kind is fit to leave the machine.
        #expect(
            await login.handle.outcome
                == .notCompleted(
                    LoginFailure(exitStatus: .exited(3), standardError: standardError, kind: kind)
                )
        )
    }

    @Test(
        "The timeout and denied words classify nothing unless the CLI exited as signed out",
        arguments: [
            ProcessExitStatus.exited(1), .exited(143), .signaled(SIGKILL), .signaled(SIGTERM),
        ],
        ["authentication timeout", "context deadline exceeded", "OAuth error: access_denied"]
    )
    func classificationNeedsTheSignedOutExit(
        exitStatus: ProcessExitStatus,
        error: String
    ) async throws {
        // The CLI prints this envelope and exits 3 in one breath, so the words
        // under any other ending are text from something else: a CLI that changed
        // its codes, or a child that died between the two.
        let login = try await startLogin()

        login.process.end(exitStatus, standardError: signInStandardError(failingWith: error))

        guard case let .notCompleted(failure) = await login.handle.outcome else {
            Issue.record("A sign in that ended this way was reported completed")
            return
        }
        #expect(failure.kind == .notClassified)
    }

    @Test("A cancel decides the kind too, even over a timeout the CLI printed on its way out")
    func cancelBeatsATimeoutEnvelope() async throws {
        // The app asked this sign in to stop, so the user walked away from it
        // whatever the CLI made of the SIGTERM. Reporting the timeout it happened
        // to print as well would count one abandoned sign in as two things.
        let login = try await startLogin()
        login.process.endsOnTerminate(
            .exited(3),
            standardError: signInStandardError(failingWith: "authentication timeout")
        )

        login.handle.cancel()

        guard case let .notCompleted(failure) = await login.handle.outcome else {
            Issue.record("A cancelled sign in was reported completed")
            return
        }
        #expect(failure.kind == .cancelled)
        #expect(failure.exitStatus == .exited(3))
    }

    @Test("A cancelled sign in the CLI never answered is classified as cancelled")
    func cancelledSignInIsClassifiedAsCancelled() async throws {
        let login = try await startLogin()

        login.handle.cancel()

        guard case let .notCompleted(failure) = await login.handle.outcome else {
            Issue.record("A cancelled sign in was reported completed")
            return
        }
        #expect(failure.kind == .cancelled)
    }

    @Test("A signed out exit with no stderr, as the output ceiling leaves one, is not classified")
    func emptyStandardErrorIsNotClassified() async throws {
        // A sign in stopped past the output ceiling keeps none of its stderr, so the
        // envelope that would say why is gone, and the package does not guess.
        let stopped = try await startLogin()
        stopped.process.endWithStandardErrorTooLarge(.exited(3))
        let silent = try await startLogin()
        silent.process.end(.exited(3))

        #expect(
            await stopped.handle.outcome
                == .notCompleted(
                    LoginFailure(exitStatus: .exited(3), standardError: "", kind: .notClassified)
                )
        )
        #expect(
            await silent.handle.outcome
                == .notCompleted(
                    LoginFailure(exitStatus: .exited(3), standardError: "", kind: .notClassified)
                )
        )
    }

    @Test("Only the envelope's quoted error classifies, never the address or a plain log line")
    func onlyTheQuotedErrorClassifies() {
        // The address is the one other place text the CLI did not write itself
        // lands on stderr, and a state that happened to carry these words must not
        // read as the CLI's verdict. A URL cannot hold a bare quote, and the rule
        // only matches the error as the envelope quotes it, so the address can
        // never match whatever it carries. Plain log text cannot either.
        let inTheAddress =
            "If the browser doesn't open, visit: https://app.hey.com/oauth/authorizations/new"
            + "?state=login failed: authentication timeout"
            + "&error=login failed: OAuth error: access_denied\n"
        // The form a real address takes, with the state percent encoded as a
        // browser or the CLI would encode it.
        let percentEncoded =
            "If the browser doesn't open, visit: https://app.hey.com/oauth/authorizations/new"
            + "?state=login%20failed%3A%20authentication%20timeout"
            + "&error=login%20failed%3A%20OAuth%20error%3A%20access_denied\n"
        let unquoted =
            "login failed: authentication timeout\n"
            + "login failed: OAuth error: access_denied\n"

        for standardError in [inTheAddress, percentEncoded, unquoted] {
            let failure = LoginFailure(exitStatus: .exited(3), standardError: standardError)
            #expect(failure.kind == .notClassified)
        }
    }

    @Test("An error the CLI appends text to still classifies, since the anchors leave off the closing quote")
    func appendedTextStillClassifies() {
        // The envelope's error is whatever the CLI wrapped, so a later build that
        // says more after these words must not lose the kind it already had.
        let appended = [
            ("authentication timeout after 5m0s", LoginFailure.Kind.timedOut),
            ("context deadline exceeded (6m0s)", .timedOut),
            ("OAuth error: access_denied: the user declined", .accessDenied),
        ]

        for (error, kind) in appended {
            let failure = LoginFailure(
                exitStatus: .exited(3),
                standardError: signInStandardError(failingWith: error)
            )
            #expect(failure.kind == kind, "\(error)")
        }
    }

    @Test("A failure built from its ending alone is classified, and never as cancelled")
    func twoArgumentInitializerClassifies() {
        let timedOut = LoginFailure(
            exitStatus: .exited(3),
            standardError: signInStandardError(failingWith: "authentication timeout")
        )
        let denied = LoginFailure(
            exitStatus: .exited(3),
            standardError: signInStandardError(failingWith: "OAuth error: access_denied")
        )
        // The ending a cancel usually leaves, stated with no cancel behind it: only
        // the package knows a cancel was asked for, so this is not classified.
        let terminated = LoginFailure(exitStatus: .signaled(SIGTERM), standardError: "")

        #expect(timedOut.kind == .timedOut)
        #expect(denied.kind == .accessDenied)
        #expect(terminated.kind == .notClassified)
    }

    @Test("A failure built with its kind keeps that kind, whatever its stderr says")
    func kindInitializerStatesTheKind() {
        let timeout = signInStandardError(failingWith: "authentication timeout")
        let stated = LoginFailure(exitStatus: .exited(3), standardError: timeout, kind: .cancelled)

        #expect(stated.kind == .cancelled)
        #expect(stated.exitStatus == .exited(3))
        #expect(stated.standardError == timeout)
        // The kind is part of what a failure is, so two that differ only there are
        // two different failures.
        #expect(stated != LoginFailure(exitStatus: .exited(3), standardError: timeout))
    }

    @Test(
        "A failure's description names its kind and its ending, and never its stderr",
        arguments: [
            (LoginFailure.Kind.timedOut, ProcessExitStatus.exited(3), "The sign in timed out (exit code 3)."),
            (.accessDenied, .exited(3), "The sign in was declined (exit code 3)."),
            (.cancelled, .signaled(SIGTERM), "The sign in was cancelled (killed by signal \(SIGTERM))."),
            (
                .notClassified, .exited(1),
                "The sign in was not completed, for a reason the package has no name for (exit code 1)."
            ),
        ]
    )
    func failureDescriptionIsValueFree(
        kind: LoginFailure.Kind,
        exitStatus: ProcessExitStatus,
        expected: String
    ) {
        // The stderr carries the sign in address with the install id in it, so an
        // app that logs a failure or an outcome as it is must not log that. The
        // kind is stated rather than classified so every kind is described over
        // the same realistic stderr, address and all.
        let failure = LoginFailure(
            exitStatus: exitStatus,
            standardError: signInStandardError(failingWith: "authentication timeout"),
            kind: kind
        )
        let outcome = LoginOutcome.notCompleted(failure)

        #expect(failure.description == expected)
        #expect(String(describing: outcome).contains(expected))

        let renderings = [
            String(describing: failure), "\(failure)", String(reflecting: failure),
            String(describing: outcome), "\(outcome)", String(reflecting: outcome),
        ]
        for rendering in renderings {
            #expect(rendering.contains("install_id") == false, "\(rendering)")
            #expect(rendering.contains("https://") == false, "\(rendering)")
            #expect(rendering.contains("login failed") == false, "\(rendering)")
        }
    }

    @Test(
        "No operation but login itself ever spawns the sign in flow",
        arguments: HEYClientOperation.allCases.filter { $0 != .login }
    )
    func onlyLoginSpawnsTheSignInFlow(operation: HEYClientOperation) async throws {
        let (client, script) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "error-auth.json"), exitCode: 3)]
        )

        switch operation {
        case .watch:
            // A watch goes through the long lived entry point, and a scripted child
            // never ends on its own, so it is ended the way the CLI ends a watch
            // that started signed out rather than drained until it stops.
            let lines = try await client.watch(NonEmptySet(.imbox))
            try #require(script.startedProcesses.first).end(.exited(3))

            await #expect(throws: (any Error).self) {
                for try await _ in lines {}
            }
        default:
            await #expect(throws: (any Error).self) {
                try await perform(operation, on: client)
            }
        }

        // Signed out is the one answer that would tempt a package into signing in,
        // and nothing does: one spawn was asked for, and it was the operation's own.
        let spawns = script.recordedSpawns
        #expect(spawns.count == 1)
        #expect(spawns.contains { $0.arguments.starts(with: ["auth", "login"]) } == false)
    }
}
