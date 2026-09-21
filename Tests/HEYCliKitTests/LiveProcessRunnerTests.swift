import Foundation
import Synchronization
import Testing

@testable import HEYCliKit

@Suite("Live process runner")
struct LiveProcessRunnerTests {
    /// Builds a spawn that runs a shell script. Nothing here runs the hey CLI.
    private func shellSpawn(
        _ script: String,
        standardOutput: StandardOutputPolicy = .lines
    ) -> SpawnDescription {
        SpawnDescription(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", script],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            standardInput: .devNull,
            standardOutput: standardOutput
        )
    }

    /// Runs one spawn under the given limits, cancelling it if it has not returned
    /// within the bound.
    ///
    /// A run that never returns then fails its test with a cancellation rather than
    /// hanging the suite, and a test that expects a ceiling failure can tell the
    /// two apart.
    private func run(
        _ spawn: SpawnDescription,
        limits: RunnerLimits,
        within bound: Duration = .seconds(10)
    ) async throws -> ProcessOutput {
        let run = Task { try await ProcessRunner.live(limits: limits).run(spawn) }
        let watchdog = Task {
            try? await Task.sleep(for: bound)
            run.cancel()
        }

        defer { watchdog.cancel() }

        return try await run.value
    }

    /// Spawns a long running process the test owns, to stand in for whoever the
    /// system might have handed a reaped child's process identifier to.
    ///
    /// It is spawned here rather than through the runner because the test needs the
    /// identifier of a process nothing in the package is following, which is exactly
    /// the position a stranger who inherited a reused identifier is in.
    ///
    /// The flag it hands back says whether the stand in has ended, read from its own
    /// termination handler the way the runner reads a child's, so a signal that
    /// escalates after the grace checks something true rather than a constant.
    private func spawnStandIn(ended: StandInEnded = StandInEnded()) throws -> Process {
        let standIn = Process()
        standIn.executableURL = URL(filePath: "/bin/sleep")
        standIn.arguments = ["30"]
        standIn.standardOutput = FileHandle.nullDevice
        standIn.standardError = FileHandle.nullDevice
        standIn.terminationHandler = { _ in ended.record() }
        try standIn.run()

        return standIn
    }

    @Test("Payloads larger than the pipe buffer on both streams are captured without deadlocking")
    func drainsBothStreamsConcurrently() async throws {
        // Both streams are filled past the pipe buffer, so a drain that reads one
        // stream to the end before starting the other deadlocks here: the child
        // blocks writing to the pipe nobody is reading.
        let output = try await ProcessRunner.live().run(
            shellSpawn(
                """
                head -c 300000 /dev/zero | tr '\\0' 'a'
                head -c 300000 /dev/zero | tr '\\0' 'b' 1>&2
                """
            )
        )

        #expect(output.stdout.count == 300_000)
        #expect(output.stdout.allSatisfy { $0 == UInt8(ascii: "a") })
        #expect(output.stderr.count == 300_000)
        #expect(output.stderr.allSatisfy { $0 == UInt8(ascii: "b") })
        #expect(output.exitStatus == .exited(0))
    }

    @Test("An exit code and stderr come back as they were")
    func reportsExitCodeAndStandardError() async throws {
        let output = try await ProcessRunner.live().run(shellSpawn("echo err 1>&2; exit 4"))

        #expect(output.exitStatus == .exited(4))
        #expect(String(decoding: output.stderr, as: UTF8.self) == "err\n")
        #expect(output.stdout.isEmpty)
    }

    @Test("Stdin is closed, so a child that reads gets end of file")
    func standardInputIsDevNull() async throws {
        let output = try await ProcessRunner.live().run(shellSpawn("read x; echo $?"))

        #expect(String(decoding: output.stdout, as: UTF8.self) == "1\n")
    }

    @Test("A child killed by a signal reports the signal")
    func reportsSignal() async throws {
        let output = try await ProcessRunner.live().run(shellSpawn("kill -TERM $$"))

        #expect(output.exitStatus == .signaled(SIGTERM))
    }

    @Test("Cancelling the calling task terminates the child and surfaces as cancellation")
    func cancellationTerminatesTheChild() async throws {
        let spawn = shellSpawn("sleep 30")
        let run = Task { try await ProcessRunner.live().run(spawn) }

        // Give the child a moment to be spawned before asking it to stop.
        try await Task.sleep(for: .milliseconds(200))
        run.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await run.value
        }
    }

    @Test("A task cancelled before the run starts never spawns anything")
    func cancellationBeforeSpawn() async throws {
        // Launching this executable can only fail, so a run that reports
        // cancellation rather than a process failure never reached the launch.
        let spawn = SpawnDescription(
            executable: URL(filePath: "/nonexistent/hey"),
            arguments: [],
            environment: [:],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            standardInput: .devNull,
            standardOutput: .lines
        )

        let run = Task {
            // The run is entered on an already cancelled task, so it has to notice
            // on its way in rather than spawn a child nobody is waiting for.
            while !Task.isCancelled {
                await Task.yield()
            }

            return try await ProcessRunner.live().run(spawn)
        }
        run.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await run.value
        }
    }

    @Test("An executable that does not exist is a process failure with a reason")
    func launchFailure() async throws {
        var spawn = shellSpawn("true")
        spawn = SpawnDescription(
            executable: URL(filePath: "/nonexistent/hey"),
            arguments: spawn.arguments,
            environment: spawn.environment,
            workingDirectory: spawn.workingDirectory,
            standardInput: spawn.standardInput,
            standardOutput: spawn.standardOutput
        )

        do {
            _ = try await ProcessRunner.live().run(spawn)
            Issue.record("The spawn was expected to fail.")
        } catch let HEYCliKitError.processFailure(failure) {
            #expect(failure.exitStatus == nil)
            #expect(failure.reason?.isEmpty == false)
            #expect(failure.standardError.isEmpty)
        }
    }

    @Test("A long lived child's lines arrive while it is still running")
    func longLivedLinesArriveAsTheyArePrinted() async throws {
        let handle = try await ProcessRunner.live().start(shellSpawn("echo one; sleep 0.5; echo two"))
        var iterator = handle.lines.makeAsyncIterator()

        // The first line has to arrive well before the child prints its second
        // one, so a handle that buffered everything until exit fails here.
        let start = ContinuousClock.now
        let first = try await iterator.next()
        let elapsed = ContinuousClock.now - start

        #expect(first == "one")
        #expect(elapsed < .milliseconds(400))
        #expect(try await iterator.next() == "two")
        #expect(try await iterator.next() == nil)
        #expect(await handle.ending().exitStatus == .exited(0))
    }

    @Test("Terminating a long lived child sends SIGTERM and ends its lines")
    func longLivedTerminateSendsSIGTERM() async throws {
        // The shell execs the sleep, so the child that is signalled is the one
        // holding stdout open. A shell that forked it instead would die on the
        // signal while its own child kept the pipe open for the full thirty
        // seconds, which is the shell's doing and not the runner's.
        let handle = try await ProcessRunner.live().start(shellSpawn("echo up; exec sleep 30"))
        var iterator = handle.lines.makeAsyncIterator()

        // The child has printed, so it is running: terminating now is asking a
        // live child to stop rather than signalling one that already ended.
        #expect(try await iterator.next() == "up")
        handle.terminate()

        #expect(try await iterator.next() == nil)
        #expect(await handle.ending().exitStatus == .signaled(SIGTERM))
    }

    @Test("A child that has already ended is never signalled")
    func terminateSkipsAChildThatHasEnded() async throws {
        // The process the test spawned here is not the child that ended: it stands
        // in for whoever the system handed that child's identifier to once it was
        // reaped. Signalling it is the bug, and it dying is what the bug looks like.
        let standIn = try spawnStandIn()
        defer { if standIn.isRunning { standIn.terminate() } }

        terminateChild(standIn.processIdentifier, grace: .seconds(5), unlessEnded: { true })

        // Generous, because the claim is that nothing happens: a signal that had
        // been sent would have arrived and been noticed several times over by now.
        try await Task.sleep(for: .seconds(1.5))

        #expect(standIn.isRunning)
    }

    @Test("A child that has not ended yet is asked to stop")
    func terminateSignalsARunningChild() async throws {
        let ended = StandInEnded()
        let standIn = try spawnStandIn(ended: ended)
        defer { if standIn.isRunning { standIn.terminate() } }

        terminateChild(standIn.processIdentifier, grace: .seconds(5), unlessEnded: { ended.hasEnded })

        // Polled rather than waited on, so the assertion below never reads an exit
        // status from a process that is somehow still running.
        let deadline = ContinuousClock.now + .seconds(5)
        while standIn.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        try #require(!standIn.isRunning)
        #expect(standIn.terminationReason == .uncaughtSignal)
        #expect(standIn.terminationStatus == SIGTERM)
    }

    @Test("A long lived child's ending carries its exit code and its stderr")
    func longLivedEndingCarriesTheExitCodeAndStandardError() async throws {
        let handle = try await ProcessRunner.live().start(shellSpawn("echo err 1>&2; exit 4"))

        for try await _ in handle.lines {}
        let ending = await handle.ending()

        #expect(ending.exitStatus == .exited(4))
        #expect(String(decoding: ending.standardError, as: UTF8.self) == "err\n")
        // The ending stays in its box once it arrives, so a second reader gets the
        // same answer rather than waiting for something that already happened.
        #expect(await handle.ending() == ending)
    }

    @Test("A long lived child's ending reaches two callers that were already waiting")
    func longLivedEndingReachesEveryWaiter() async throws {
        let handle = try await ProcessRunner.live().start(shellSpawn("sleep 0.5; exit 4"))

        // Both waits are in place well before the child exits, which is how the
        // watch pump and an app following the same sign in wait on it. A handle
        // that remembered only the last caller to ask would leave the other one
        // waiting for an ending that has already been and gone.
        let (arrivals, arrival) = AsyncStream<ProcessEnding>.makeStream()
        let waiters = (0 ..< 2).map { _ in
            Task { arrival.yield(await handle.ending()) }
        }

        // A waiter that is never answered would otherwise hang this test rather
        // than fail it, so the arrivals are cut off well after the child's exit.
        let bound = Task {
            try? await Task.sleep(for: .seconds(5))
            arrival.finish()
        }

        defer {
            for waiter in waiters { waiter.cancel() }
            bound.cancel()
        }

        var delivered: [ProcessEnding] = []
        for await ending in arrivals {
            delivered.append(ending)
            if delivered.count == waiters.count { break }
        }

        #expect(delivered.map(\.exitStatus) == [.exited(4), .exited(4)])
    }

    @Test("A long lived executable that does not exist is a process failure with a reason")
    func longLivedLaunchFailure() async throws {
        let spawn = SpawnDescription(
            executable: URL(filePath: "/nonexistent/hey"),
            arguments: [],
            environment: [:],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            standardInput: .devNull,
            standardOutput: .lines
        )

        do {
            _ = try await ProcessRunner.live().start(spawn)
            Issue.record("The start was expected to fail.")
        } catch let HEYCliKitError.processFailure(failure) {
            #expect(failure.exitStatus == nil)
            #expect(failure.reason?.isEmpty == false)
            #expect(failure.standardError.isEmpty)
        }
    }

    @Test("A last line the child printed without a newline is still delivered")
    func longLivedDeliversATrailingLineWithoutANewline() async throws {
        let handle = try await ProcessRunner.live().start(shellSpawn("printf 'a\\nb'"))

        var lines: [String] = []
        for try await line in handle.lines {
            lines.append(line)
        }

        #expect(lines == ["a", "b"])
        #expect(await handle.ending().exitStatus == .exited(0))
    }

    @Test("A child that traps SIGTERM and exits by code ends with that code, not a signal")
    func longLivedTerminateReportsATrappedSignalAsAnExitCode() async throws {
        // Nothing says a CLI has to die on the signal: a binary that trapped it
        // for a graceful shutdown ends by exit code instead, and a login that
        // read the ending alone would take a clean one for a completed sign in.
        // The shell here traps it, and the sleep it waits on is backgrounded with
        // both its streams redirected, so once the trap has run nothing is left
        // holding the pipes open.
        let handle = try await ProcessRunner.live().start(
            shellSpawn("trap 'exit 3' TERM; echo up; sleep 30 >/dev/null 2>&1 & wait")
        )
        var iterator = handle.lines.makeAsyncIterator()

        // The child has printed, so its trap is installed and it is running:
        // terminating now asks a live child to stop.
        #expect(try await iterator.next() == "up")
        handle.terminate()

        #expect(try await iterator.next() == nil)
        let trapped = await ending(of: handle, within: .seconds(10))

        #expect(trapped?.exitStatus == .exited(3))
    }

    @Test("Output exactly at the output ceiling is read in full, on both streams")
    func outputAtTheCeilingIsRead() async throws {
        let output = try await run(
            shellSpawn("head -c 1000 /dev/zero; head -c 1000 /dev/zero 1>&2"),
            limits: .standard.with(outputCeilingInBytes: 1000)
        )

        #expect(output.stdout.count == 1000)
        #expect(output.stderr.count == 1000)
        #expect(output.exitStatus == .exited(0))
    }

    @Test(
        "Output past the output ceiling is a loud failure, never a short envelope",
        arguments: ["head -c 5000 /dev/zero", "head -c 5000 /dev/zero 1>&2"]
    )
    func outputPastTheCeilingFails(script: String) async throws {
        // One byte past the ceiling on either stream is enough, and nothing of what
        // was read is handed on: a decoder given the first thousand bytes of a page
        // could come back with a page that is shorter than the one HEY sent.
        await #expect(throws: HEYCliKitError.outputTooLarge(limitInBytes: 1000)) {
            _ = try await run(shellSpawn(script), limits: .standard.with(outputCeilingInBytes: 1000))
        }
    }

    @Test("A child that never stops printing is stopped at the ceiling rather than read for ever")
    func aChildThatNeverStopsPrintingIsStopped() async throws {
        // yes never reaches end of file on its own. A drain that only asked it to
        // stop once the read had returned would therefore never return at all, the
        // watchdog would cancel the run, and it would report a cancellation instead.
        let spawn = SpawnDescription(
            executable: URL(filePath: "/usr/bin/yes"),
            arguments: [],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            standardInput: .devNull,
            standardOutput: .lines
        )

        await #expect(throws: HEYCliKitError.outputTooLarge(limitInBytes: 64 * 1024)) {
            _ = try await run(spawn, limits: .standard.with(outputCeilingInBytes: 64 * 1024))
        }
    }

    @Test(
        "A line past the line ceiling ends the lines loudly, and no part of it arrives",
        arguments: [
            // The long line arrives whole, newline and all, in one read.
            "printf 'short\\n%5000s\\nafter\\n' ''",
            // The long line is still unterminated when the child stops writing.
            "printf 'short\\n'; head -c 5000 /dev/zero | tr '\\0' a",
        ]
    )
    func aLinePastTheCeilingEndsTheLines(script: String) async throws {
        let handle = try await ProcessRunner.live(
            limits: .standard.with(lineCeilingInBytes: 1000)
        ).start(shellSpawn(script))

        var lines: [String] = []
        do {
            for try await line in handle.lines {
                lines.append(line)
            }
            Issue.record("The lines were expected to end with a line too large.")
        } catch let error as HEYCliKitError {
            #expect(error == .lineTooLarge(limitInBytes: 1000))
        }

        // A partial line is not a line, and nothing the child printed after the one
        // that was too long is handed on either.
        #expect(lines == ["short"])
        #expect(await ending(of: handle, within: .seconds(10)) != nil)
    }

    @Test("Lines nobody reads fill the runner's buffer, and the lines that fit arrive before the failure")
    func unreadLinesPastTheBufferEndTheLines() async throws {
        let handle = try await ProcessRunner.live(
            limits: .standard.with(runnerLineBufferInLines: 4, watchBufferInLines: 2)
        ).start(shellSpawn("for i in 1 2 3 4 5 6 7 8; do echo line$i; done; exec sleep 30"))

        // Nothing reads a line until the child has ended, so the buffer fills while
        // the runner is still reading. A child that was never terminated would
        // sleep well past the bound here.
        let ended = try #require(await ending(of: handle, within: .seconds(10)))
        #expect(ended.exitStatus == .signaled(SIGTERM))

        var lines: [String] = []
        do {
            for try await line in handle.lines {
                lines.append(line)
            }
            Issue.record("The lines were expected to end with the reader fallen behind.")
        } catch let error as HEYCliKitError {
            // The failure names the watch buffer bound whichever buffer filled, so
            // one case never carries two numbers. A full runner buffer holds more
            // unread lines than that bound, so the number is still true.
            #expect(error == .watchFellBehind(limitInLines: 2))
        }

        // What arrived is exactly what the child printed first, with no hole in it.
        #expect(lines == ["line1", "line2", "line3", "line4"])
    }

    @Test("A long lived child that writes stderr past the output ceiling is terminated, and its ending says so")
    func longLivedStandardErrorPastTheCeiling() async throws {
        let handle = try await ProcessRunner.live(
            limits: .standard.with(outputCeilingInBytes: 1000)
        ).start(shellSpawn("head -c 5000 /dev/zero 1>&2; exec sleep 30"))

        let ended = try #require(await ending(of: handle, within: .seconds(10)))

        #expect(ended.standardErrorWasTooLarge)
        #expect(ended.standardError.isEmpty)
        #expect(ended.exitStatus == .signaled(SIGTERM))
    }

    @Test("A child whose stdout is discarded is never stalled by it, and its lines are already finished")
    func discardedStandardOutputIsNeverRead() async throws {
        // The child prints far more than the line buffer holds, so a runner that
        // read this stdout with nobody taking the lines would terminate it.
        let handle = try await ProcessRunner.live(
            limits: .standard.with(runnerLineBufferInLines: 4)
        ).start(
            shellSpawn("i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done", standardOutput: .discarded)
        )

        var lines: [String] = []
        for try await line in handle.lines {
            lines.append(line)
        }

        #expect(lines.isEmpty)
        #expect(await ending(of: handle, within: .seconds(10))?.exitStatus == .exited(0))
    }

    @Test("A child that ignores SIGTERM is sent SIGKILL once the termination grace has passed")
    func aChildIgnoringSIGTERMIsKilled() async throws {
        // The shell is the child the runner signals and it ignores SIGTERM. The
        // sleep it waits on is backgrounded with both its streams redirected, so
        // once the shell is killed nothing is left holding the pipes open.
        let handle = try await ProcessRunner.live(
            limits: .standard.with(terminationGrace: .milliseconds(500))
        ).start(shellSpawn("trap '' TERM; echo up; sleep 30 >/dev/null 2>&1 & wait"))
        var iterator = handle.lines.makeAsyncIterator()

        // The child has printed, so the signal is already ignored when it arrives.
        #expect(try await iterator.next() == "up")
        handle.terminate()

        let killed = await ending(of: handle, within: .seconds(10))

        #expect(killed?.exitStatus == .signaled(SIGKILL))
    }

    @Test("A child that ends on SIGTERM ends by SIGTERM, with the grace long past")
    func aChildEndingOnSIGTERMIsNotEscalated() async throws {
        let handle = try await ProcessRunner.live(
            limits: .standard.with(terminationGrace: .milliseconds(200))
        ).start(shellSpawn("echo up; exec sleep 30"))
        var iterator = handle.lines.makeAsyncIterator()

        #expect(try await iterator.next() == "up")
        handle.terminate()
        #expect(try await iterator.next() == nil)

        // Well past the grace, so an escalation that fired regardless of the ending
        // has had every chance to.
        try await Task.sleep(for: .milliseconds(600))

        #expect(await handle.ending().exitStatus == .signaled(SIGTERM))
    }

    /// Waits for a child's ending, giving up after a bound so a child that never
    /// ends fails a test rather than hanging the suite.
    ///
    /// The bound is generous because a real process has to take the signal, run
    /// whatever it does with it and exit before an ending can arrive. The waiter is
    /// left behind on purpose: an ending is deliberately not cancellable, so there
    /// is nothing to call off, and it goes away with the child.
    private func ending(of handle: ProcessHandle, within bound: Duration) async -> ProcessEnding? {
        let (endings, arrival) = AsyncStream<ProcessEnding>.makeStream()
        let waiter = Task { arrival.yield(await handle.ending()) }
        let deadline = Task {
            try? await Task.sleep(for: bound)
            arrival.finish()
        }

        defer {
            waiter.cancel()
            deadline.cancel()
        }

        var arrivals = endings.makeAsyncIterator()

        return await arrivals.next()
    }
}

/// Whether a stand in process has ended, set from its termination handler.
final class StandInEnded: Sendable {
    private let state = Mutex(false)

    func record() {
        state.withLock { $0 = true }
    }

    var hasEnded: Bool {
        state.withLock { $0 }
    }
}
