import Foundation
import Synchronization

@testable import HEYCliKit
import HEYCliKitTestSupport

/// Thrown when a test asks the scripted runner for more output than it holds.
struct ScriptedOutputExhausted: Error, CustomStringConvertible {
    let spawnCount: Int

    var description: String {
        "The scripted process runner ran out of scripted output on spawn number \(spawnCount)."
    }
}

/// A process runner that answers from a queue of scripted output and records
/// every spawn it is asked for, so a test can assert the shape of the spawn
/// without ever launching the real hey executable.
final class ProcessRunnerScript: Sendable {
    private struct State {
        var queue: [ProcessOutput]
        var spawns: [SpawnDescription] = []
        var started: [ScriptedProcess] = []
    }

    private let state: Mutex<State>

    init(_ outputs: [ProcessOutput] = []) {
        state = Mutex(State(queue: outputs))
    }

    /// The runner to hand to a client under test.
    var runner: ProcessRunner {
        ProcessRunner(
            run: { description in
                try self.state.withLock { state in
                    state.spawns.append(description)
                    guard !state.queue.isEmpty else {
                        throw ScriptedOutputExhausted(spawnCount: state.spawns.count)
                    }

                    return state.queue.removeFirst()
                }
            },
            start: { description in
                let process = ScriptedProcess()
                self.state.withLock { state in
                    state.spawns.append(description)
                    state.started.append(process)
                }

                return process.handle
            }
        )
    }

    /// Every spawn the runner was asked for, in the order it was asked, whether it
    /// was a one shot run or a long lived start.
    var recordedSpawns: [SpawnDescription] {
        state.withLock { $0.spawns }
    }

    /// Every long lived child the runner handed out, in the order it started them,
    /// so a test can drive one after the call that started it has returned.
    var startedProcesses: [ScriptedProcess] {
        state.withLock { $0.started }
    }
}

/// One long lived child the scripted runner handed out.
///
/// Nothing is scripted in advance: a test emits the lines it wants, in the order
/// it wants them, and ends the child when it is done. Terminating reacts the way
/// a real child does, finishing the lines and ending as killed by SIGTERM unless
/// the test scripted another ending with ``endsOnTerminate(_:standardError:)``,
/// and only while the child has not already ended. Every terminate is counted
/// either way, so a test can assert that the stream asked the child to stop.
final class ScriptedProcess: Sendable {
    private struct State {
        var lines: AsyncThrowingStream<String, any Error>.Continuation
        var ending: ProcessEnding?
        var terminationEnding = ProcessEnding(
            exitStatus: .signaled(SIGTERM),
            standardError: Data()
        )
        var waiting: [CheckedContinuation<ProcessEnding, Never>] = []
        var terminateCallCount = 0
    }

    private let state: Mutex<State>
    private let lines: AsyncThrowingStream<String, any Error>

    init() {
        let (lines, continuation) = AsyncThrowingStream<String, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.lines = lines
        state = Mutex(State(lines: continuation))
    }

    /// The handle the runner hands back for this child.
    var handle: ProcessHandle {
        ProcessHandle(
            lines: lines,
            terminate: { self.terminate() },
            ending: { await self.endingValue }
        )
    }

    /// How many times whoever holds the handle asked this child to stop.
    var terminateCallCount: Int {
        state.withLock { $0.terminateCallCount }
    }

    /// Prints one line on the child's stdout.
    func emit(_ line: String) {
        state.withLock { state in
            guard state.ending == nil else { return }

            state.lines.yield(line)
        }
    }

    /// Prints every non empty line of a shipped ndjson fixture, in fixture order.
    func emit(contentsOf fixture: String) throws {
        let text = String(decoding: try HEYFixtures.data(named: fixture), as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            emit(String(line))
        }
    }

    /// Ends the child: the lines finish and the ending is delivered.
    func end(_ exitStatus: ProcessExitStatus, standardError: String = "") {
        deliver(ProcessEnding(exitStatus: exitStatus, standardError: Data(standardError.utf8)))
    }

    /// Fails the child's lines the way the live runner fails them when it stops
    /// reading, leaving the ending to whatever the test does next.
    func failLines(with error: any Error) {
        state.withLock { state in
            guard state.ending == nil else { return }

            state.lines.finish(throwing: error)
        }
    }

    /// Ends the child the way the live runner ends one that wrote more stderr than
    /// the output ceiling: terminated, with none of that stderr kept. The exit is
    /// SIGTERM unless the test scripts the CLI that traps it and exits by code.
    func endWithStandardErrorTooLarge(_ exitStatus: ProcessExitStatus = .signaled(SIGTERM)) {
        deliver(
            ProcessEnding(
                exitStatus: exitStatus,
                standardError: Data(),
                standardErrorWasTooLarge: true
            )
        )
    }

    /// Scripts how this child ends once it is asked to stop, for the CLI that
    /// traps SIGTERM and exits by code rather than dying on the signal.
    ///
    /// A child nobody scripts dies on the signal, which is what the real hey 1.4.0
    /// binary does with a sign in, so every test that does not care about the
    /// distinction keeps the ending it always had.
    func endsOnTerminate(_ exitStatus: ProcessExitStatus, standardError: String = "") {
        state.withLock { state in
            state.terminationEnding = ProcessEnding(
                exitStatus: exitStatus,
                standardError: Data(standardError.utf8)
            )
        }
    }

    private func terminate() {
        let ending: ProcessEnding? = state.withLock { state in
            state.terminateCallCount += 1
            guard state.ending == nil else { return nil }

            return state.terminationEnding
        }

        guard let ending else { return }

        deliver(ending)
    }

    private func deliver(_ ending: ProcessEnding) {
        let waiting = state.withLock { state -> [CheckedContinuation<ProcessEnding, Never>] in
            guard state.ending == nil else { return [] }

            state.ending = ending
            state.lines.finish()
            defer { state.waiting = [] }

            return state.waiting
        }

        for continuation in waiting {
            continuation.resume(returning: ending)
        }
    }

    /// The ending, awaited from as many places as a test likes and from the watch
    /// pump beside them, which is why every waiter is remembered rather than one.
    private var endingValue: ProcessEnding {
        get async {
            await withCheckedContinuation { continuation in
                let ending: ProcessEnding? = state.withLock { state in
                    guard let ending = state.ending else {
                        state.waiting.append(continuation)
                        return nil
                    }

                    return ending
                }

                if let ending {
                    continuation.resume(returning: ending)
                }
            }
        }
    }
}

/// Builds one scripted answer from stdout bytes, an exit code and stderr text.
func scriptedOutput(
    _ standardOutput: Data,
    exitCode: Int32 = 0,
    standardError: String = ""
) -> ProcessOutput {
    ProcessOutput(
        stdout: standardOutput,
        stderr: Data(standardError.utf8),
        exitStatus: .exited(exitCode)
    )
}

/// Builds one scripted answer from stdout text, an exit code and stderr text.
func scriptedOutput(
    _ standardOutput: String,
    exitCode: Int32 = 0,
    standardError: String = ""
) -> ProcessOutput {
    scriptedOutput(Data(standardOutput.utf8), exitCode: exitCode, standardError: standardError)
}

/// The executable location every test spawns against. Nothing ever runs it.
let testExecutable = URL(filePath: "/usr/local/bin/hey")

/// Builds a client whose runner answers from the given scripted output.
func makeScriptedClient(
    outputs: [ProcessOutput],
    accountSelection: AccountSelection = .all,
    environment: [String: String] = [:],
    limits: RunnerLimits = .standard
) -> (client: HEYClient, script: ProcessRunnerScript) {
    let script = ProcessRunnerScript(outputs)
    let client = HEYClient(
        runner: script.runner,
        executable: testExecutable,
        accountSelection: accountSelection,
        environment: environment,
        limits: limits
    )

    return (client, script)
}

extension [String] {
    /// The argument that follows the given one, when there is one, so a test can
    /// read a flag's value without depending on where in the line it landed.
    func argument(after name: String) -> String? {
        guard let index = firstIndex(of: name), index + 1 < count else { return nil }

        return self[index + 1]
    }
}

extension RunnerLimits {
    /// The same limits with the given ones replaced, so a test reaches a ceiling
    /// with a few lines or a few kilobytes rather than tens of megabytes.
    func with(
        outputCeilingInBytes: Int? = nil,
        lineCeilingInBytes: Int? = nil,
        runnerLineBufferInLines: Int? = nil,
        watchBufferInLines: Int? = nil,
        terminationGrace: Duration? = nil
    ) -> RunnerLimits {
        RunnerLimits(
            outputCeilingInBytes: outputCeilingInBytes ?? self.outputCeilingInBytes,
            lineCeilingInBytes: lineCeilingInBytes ?? self.lineCeilingInBytes,
            runnerLineBufferInLines: runnerLineBufferInLines ?? self.runnerLineBufferInLines,
            watchBufferInLines: watchBufferInLines ?? self.watchBufferInLines,
            terminationGrace: terminationGrace ?? self.terminationGrace
        )
    }
}
