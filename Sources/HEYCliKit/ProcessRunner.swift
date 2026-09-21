import Foundation

/// What the child process reads on stdin.
///
/// Every command reads `/dev/null`, login included: the CLI's sign in flow talks
/// to the user through a browser it opens itself, never through stdin. So there
/// is one policy and no other.
enum StandardInputPolicy: Sendable, Hashable {
    /// Stdin is `/dev/null`, so the CLI can never wait for input an app cannot give.
    case devNull
}

/// What the runner does with the child's stdout once a long lived child has started.
///
/// A one shot run always captures stdout whole, because the envelope on it is the
/// answer, so this policy is only read when a child is started rather than run.
enum StandardOutputPolicy: Sendable, Hashable {
    /// Stdout is read one line at a time into the handle's lines, under the line
    /// ceiling and the runner's line buffer bound.
    case lines
    /// Stdout is `/dev/null`. Nothing is read, nothing is buffered and the
    /// handle's lines are already finished, for a child whose stdout says nothing
    /// the package needs.
    case discarded
}

/// Everything needed to spawn one child process, as a single Sendable value.
struct SpawnDescription: Sendable, Hashable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
    let standardInput: StandardInputPolicy
    let standardOutput: StandardOutputPolicy
}

/// The ceilings the live runner and the watch hold a child to, as one value.
///
/// It is passed rather than read from anywhere global, so a test lowers a ceiling
/// for the one runner it builds and the suites running beside it in parallel keep
/// the standard ones. Why each number is what it is, and the measurement behind it,
/// is recorded in ADR 0006.
struct RunnerLimits: Sendable, Hashable {
    /// The most bytes one stream of one child is read to, stdout on a one shot run
    /// and stderr on either path. One more byte fails the read with
    /// ``HEYCliKitError/outputTooLarge(limitInBytes:)``.
    let outputCeilingInBytes: Int
    /// The longest line a long lived child's stdout may carry, without its newline.
    /// One more byte fails the lines with ``HEYCliKitError/lineTooLarge(limitInBytes:)``.
    let lineCeilingInBytes: Int
    /// How many lines the runner holds for a reader that has not taken them yet.
    /// It is never below ``watchBufferInLines``, because a full runner buffer is
    /// reported with that bound's number.
    let runnerLineBufferInLines: Int
    /// How many watch lines the watch stream holds for an app that has not read
    /// them yet. It is also the number ``HEYCliKitError/watchFellBehind(limitInLines:)``
    /// carries whichever of the two buffers filled.
    let watchBufferInLines: Int
    /// How long a child is given to end after SIGTERM before it is sent SIGKILL.
    let terminationGrace: Duration

    /// The limits every live client runs with.
    static let standard = RunnerLimits(
        outputCeilingInBytes: 32 * 1024 * 1024,
        lineCeilingInBytes: 64 * 1024,
        runnerLineBufferInLines: 4096,
        watchBufferInLines: 1024,
        terminationGrace: .seconds(5)
    )
}

/// What a finished child process left behind.
struct ProcessOutput: Sendable, Hashable {
    let stdout: Data
    let stderr: Data
    let exitStatus: ProcessExitStatus
}

/// The seam every spawn goes through.
///
/// It is internal on purpose: the package's contract is the client, not a runner
/// (ADR 0003). The package's own tests replace it with a scripted runner, which is
/// why it is internal rather than private. Consumers script answers per operation
/// with the fixture client instead, which never sees a spawn.
struct ProcessRunner: Sendable {
    /// Spawns one process, drains both its streams and waits for it to finish.
    let run: @Sendable (SpawnDescription) async throws -> ProcessOutput
    /// Spawns one long lived process and returns as soon as it has launched, with
    /// the handle that follows it. A launch that fails throws
    /// ``HEYCliKitError/processFailure(_:)`` with a reason, exactly as ``run``
    /// does, so the two entry points fail the same way.
    let start: @Sendable (SpawnDescription) async throws -> ProcessHandle
}

/// What a long lived child left the caller holding: its stdout as lines, a way to
/// ask it to stop, and how it ended.
///
/// Nothing here is the process itself. The handle carries only Sendable values and
/// two closures that capture a process identifier and a drained ending, so the
/// `Process` object stays inside the function that spawned it (ADR 0003).
struct ProcessHandle: Sendable {
    /// Stdout, one element per line as it arrives, without the newline. Empty
    /// lines are dropped. It finishes at end of file, and how the child ended is
    /// ``ending``'s business. It throws only when the runner stopped reading:
    /// ``HEYCliKitError/lineTooLarge(limitInBytes:)`` for a line past the line
    /// ceiling, which is never handed on in part, and
    /// ``HEYCliKitError/watchFellBehind(limitInLines:)`` once the buffer is full
    /// and nobody is taking lines out of it. Either way the lines that did arrive
    /// are exactly what the child printed before that point, and the child has
    /// been terminated. A child started with ``StandardOutputPolicy/discarded``
    /// hands out lines that are already finished.
    ///
    /// A consumer that stops reading must call ``terminate``. A reader that goes
    /// away leaves the child printing into a read that drops everything it gets,
    /// and nothing else stops it.
    let lines: AsyncThrowingStream<String, any Error>
    /// Sends SIGTERM to the child, then SIGKILL once the termination grace has
    /// passed if it still has not ended (ADR 0006). It is a no op once the child
    /// has ended, and the escalation checks again before it sends anything, so a
    /// process identifier the system has since handed to somebody else is never
    /// signalled on purpose.
    let terminate: @Sendable () -> Void
    /// Waits for the child to end and reports how, with its drained stderr beside
    /// it. It is safe to await from more than one place and it does not need
    /// anybody to be reading ``lines``.
    let ending: @Sendable () async -> ProcessEnding
}

/// How a long lived child ended, with what it wrote on stderr on the way.
struct ProcessEnding: Sendable, Hashable {
    let exitStatus: ProcessExitStatus
    /// The child's stderr as bytes, drained in full. Never parsed. Empty when the
    /// child wrote more than the output ceiling, rather than cut short.
    let standardError: Data
    /// Whether the child wrote more stderr than the output ceiling, in which case
    /// it was terminated and ``standardError`` holds nothing of what it wrote.
    let standardErrorWasTooLarge: Bool

    init(exitStatus: ProcessExitStatus, standardError: Data, standardErrorWasTooLarge: Bool = false) {
        self.exitStatus = exitStatus
        self.standardError = standardError
        self.standardErrorWasTooLarge = standardErrorWasTooLarge
    }
}
