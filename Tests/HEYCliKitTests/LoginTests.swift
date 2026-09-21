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
                    LoginFailure(exitStatus: .signaled(SIGTERM), standardError: "")
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
                == .notCompleted(LoginFailure(exitStatus: .exited(0), standardError: ""))
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
                == .notCompleted(LoginFailure(exitStatus: .exited(143), standardError: progress))
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
            LoginFailure(exitStatus: .signaled(SIGTERM), standardError: "")
        )
        #expect(cancelled == terminated)
        #expect(other == terminated)
        #expect(login.process.terminateCallCount >= 1)
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
