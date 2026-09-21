import Foundation
import Synchronization

extension ProcessRunner {
    /// The runner that actually spawns a child process, holding every child it
    /// spawns to the given limits.
    static func live(limits: RunnerLimits = .standard) -> ProcessRunner {
        ProcessRunner(
            run: { description in
                try await runToCompletion(description, limits: limits)
            },
            start: { description in
                try await startLongLived(description, limits: limits)
            }
        )
    }
}

/// Spawns one process, drains both streams concurrently and waits for it to exit.
///
/// The `Process` never leaves this function: only the exit status, the drained
/// bytes and the child's process identifier cross a boundary. Both streams are
/// drained at the same time because a payload larger than the pipe buffer would
/// otherwise deadlock, the writer blocked on a full pipe nobody is reading.
///
/// Cancellation is checked on the way in, so a task already cancelled never
/// spawns anything, and once more after the drains, so a cancelled run returns a
/// cancellation rather than the half written output of the child it terminated.
/// In between, the cancellation handler around the drains terminates the child,
/// including when the run was cancelled while it was being spawned: the handler
/// runs at once on a task that is already cancelled when it is installed.
///
/// Each stream is read to the output ceiling and no further. A drain that passes
/// it terminates the child there and then, and the run throws
/// ``HEYCliKitError/outputTooLarge(limitInBytes:)`` rather than hand a decoder the
/// first part of an envelope. Cancellation is checked first, so a run that was both
/// cancelled and too large still reports the cancellation the caller asked for.
private func runToCompletion(
    _ description: SpawnDescription,
    limits: RunnerLimits
) async throws -> ProcessOutput {
    try Task.checkCancellation()

    let process = makeProcess(for: description)

    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()
    process.standardOutput = standardOutputPipe
    process.standardError = standardErrorPipe

    let finalStatus = DeliveryBox<ProcessExitStatus>()
    process.terminationHandler = { finished in
        // Only the reason and the status are read here. The process itself never
        // escapes this closure.
        finalStatus.deliver(exitStatus(of: finished))
    }

    do {
        try process.run()
    } catch {
        throw launchFailure(error)
    }

    // The identifier is known before either drain starts and before the
    // cancellation handler is installed, so every way of stopping the child
    // shares this one closure.
    let stop = stopper(for: process.processIdentifier, limits: limits, finalStatus: finalStatus)

    let standardOutputDescriptor = standardOutputPipe.fileHandleForReading.fileDescriptor
    let standardErrorDescriptor = standardErrorPipe.fileHandleForReading.fileDescriptor

    let (stdout, stderr, status) = await withTaskCancellationHandler {
        async let standardOutput = readToEnd(
            standardOutputDescriptor,
            ceiling: limits.outputCeilingInBytes,
            onOverflow: stop
        )
        async let standardError = readToEnd(
            standardErrorDescriptor,
            ceiling: limits.outputCeilingInBytes,
            onOverflow: stop
        )

        let stdout = await standardOutput
        let stderr = await standardError

        // The exit status is only ever read from the termination handler, which
        // runs once the child has actually finished.
        return (stdout, stderr, await finalStatus.value)
    } onCancel: {
        // Ask the child to stop, unless it has already ended. Its streams then
        // reach end of file and the run finishes normally with whatever it
        // managed to write. A child that exited while the drains were still
        // emptying its pipe, which a page larger than the pipe buffer leaves
        // plenty of room for, is left alone: by then its identifier may already
        // name somebody else.
        stop()
    }

    // The drains read the pipes by file descriptor, so the process and both pipes
    // have to outlive them: releasing a pipe early would close a descriptor that is
    // still being read.
    withExtendedLifetime(process) {}
    withExtendedLifetime(standardOutputPipe) {}
    withExtendedLifetime(standardErrorPipe) {}

    // A run that was cancelled is a cancellation, not a child killed by signal 15:
    // the caller asked for it and never asked for what the child managed to write.
    try Task.checkCancellation()

    // Whatever was kept of a stream that went past the ceiling is not an answer,
    // so neither stream is handed on when either one did.
    guard case let .complete(standardOutput) = stdout, case let .complete(standardError) = stderr else {
        throw HEYCliKitError.outputTooLarge(limitInBytes: limits.outputCeilingInBytes)
    }

    return ProcessOutput(stdout: standardOutput, stderr: standardError, exitStatus: status)
}

/// Spawns one long lived process and returns as soon as it has launched.
///
/// Everything that touches the `Process` happens inside one detached task, which
/// builds it, launches it, reports the launch back here through a box, and then
/// holds it and both pipes alive until the child has ended. So the process object
/// never crosses an isolation boundary, and what escapes is the handle: a stream
/// of lines, a process identifier to signal, and a box the ending is delivered to.
///
/// That box is the only thing the handle waits on, so the ending can be awaited any
/// number of times and from as many places at once as care to ask, by the watch pump
/// and by a test beside it, and it does not need anybody to be reading the lines. A
/// child that never launched delivers nothing into it, and no handle is handed out
/// for one either: this call throws instead. So an ending is only ever waited for
/// when there is a real one coming.
///
/// Cancellation is checked on the way in, as a one shot run checks it, but no
/// cancellation handler is installed: whoever holds the handle decides when the
/// child should stop, because a long lived child outlives the call that spawned it.
///
/// The lines are held to the line ceiling and the runner's line buffer bound, and
/// stderr to the output ceiling. Passing any of them terminates the child at once:
/// a line past the ceiling or a full buffer ends the lines with its own failure,
/// and stderr past the ceiling is reported on the ending. The buffer drops the
/// line that did not fit rather than an older one, so the lines that did arrive
/// are exactly what the child printed first.
private func startLongLived(
    _ description: SpawnDescription,
    limits: RunnerLimits
) async throws -> ProcessHandle {
    try Task.checkCancellation()

    let (lines, lineContinuation) = AsyncThrowingStream<String, any Error>.makeStream(
        bufferingPolicy: .bufferingOldest(limits.runnerLineBufferInLines)
    )
    let launch = DeliveryBox<LaunchOutcome>()
    let finalStatus = DeliveryBox<ProcessExitStatus>()
    let childEnding = DeliveryBox<ProcessEnding>()

    Task.detached(priority: .userInitiated) {
        let process = makeProcess(for: description)

        // A discarded stdout is never a pipe at all, so there is nothing to read,
        // nothing to buffer and nothing a chatty child could fill. Its lines are
        // finished before the launch, so the handle hands them out already over.
        let standardOutputPipe: Pipe?
        switch description.standardOutput {
        case .lines:
            let pipe = Pipe()
            process.standardOutput = pipe
            standardOutputPipe = pipe
        case .discarded:
            process.standardOutput = FileHandle.nullDevice
            standardOutputPipe = nil
            lineContinuation.finish()
        }

        let standardErrorPipe = Pipe()
        process.standardError = standardErrorPipe

        process.terminationHandler = { finished in
            finalStatus.deliver(exitStatus(of: finished))
        }

        do {
            try process.run()
        } catch {
            // A child that never launched never ended either, so nothing is
            // delivered into the ending box. Nobody is left waiting on it: the
            // failure below throws instead of handing a handle out.
            launch.deliver(.failed(reason: String(describing: error)))
            lineContinuation.finish()

            return
        }

        let identifier = process.processIdentifier
        launch.deliver(.launched(identifier: identifier))

        let stop = stopper(for: identifier, limits: limits, finalStatus: finalStatus)

        let standardErrorDescriptor = standardErrorPipe.fileHandleForReading.fileDescriptor

        // Stderr is drained at the same time as stdout, because a child that
        // fills the stderr pipe nobody is reading would block writing to it and
        // never print another line.
        async let standardError = readToEnd(
            standardErrorDescriptor,
            ceiling: limits.outputCeilingInBytes,
            onOverflow: stop
        )
        if let standardOutputPipe {
            let outcome = await readLines(
                standardOutputPipe.fileHandleForReading.fileDescriptor,
                into: lineContinuation,
                ceiling: limits.lineCeilingInBytes,
                onOverflow: stop
            )

            switch outcome {
            case .endOfFile:
                lineContinuation.finish()
            case let .lineTooLarge(limit):
                lineContinuation.finish(throwing: HEYCliKitError.lineTooLarge(limitInBytes: limit))
            case .fellBehind:
                // The watch buffer bound is named rather than this buffer's own,
                // so the one failure carries one number whichever buffer filled.
                lineContinuation.finish(
                    throwing: HEYCliKitError.watchFellBehind(limitInLines: limits.watchBufferInLines)
                )
            }
        }

        let drainedStandardError = await standardError
        let ending: ProcessEnding
        switch drainedStandardError {
        case let .complete(data):
            ending = ProcessEnding(exitStatus: await finalStatus.value, standardError: data)
        case .tooLarge:
            ending = ProcessEnding(
                exitStatus: await finalStatus.value,
                standardError: Data(),
                standardErrorWasTooLarge: true
            )
        }

        // Both reads work on file descriptors, so the process and both pipes have
        // to outlive them: releasing a pipe early would close a descriptor that is
        // still being read.
        withExtendedLifetime(process) {}
        withExtendedLifetime(standardOutputPipe) {}
        withExtendedLifetime(standardErrorPipe) {}

        childEnding.deliver(ending)
    }

    let identifier: pid_t
    switch await launch.value {
    case let .launched(launched):
        identifier = launched
    case let .failed(reason):
        throw HEYCliKitError.processFailure(
            ProcessFailure(exitStatus: nil, standardError: "", reason: reason)
        )
    }

    return ProcessHandle(
        lines: lines,
        terminate: stopper(for: identifier, limits: limits, finalStatus: finalStatus),
        ending: {
            // The launch succeeded, so this handle waits on an ending the child
            // is going to have. A launch that failed threw above and left this
            // box empty, with nobody holding a handle to wait on it.
            await childEnding.value
        }
    )
}

/// The one way a runner stops the child it spawned: its identifier, the grace its
/// limits give it, and its own exit status as the word on whether it has ended.
private func stopper(
    for identifier: pid_t,
    limits: RunnerLimits,
    finalStatus: DeliveryBox<ProcessExitStatus>
) -> @Sendable () -> Void {
    {
        terminateChild(
            identifier,
            grace: limits.terminationGrace,
            unlessEnded: { finalStatus.isDelivered }
        )
    }
}

/// Asks a child to stop, and insists once the grace has passed, unless its exit
/// status says it has already ended.
///
/// The system hands a process identifier back out once the child it named has been
/// reaped, so a signal sent after the ending would land on whatever process now
/// answers to that number. Both entry points stop a child through here, so the one
/// shot path and the long lived one cannot come to disagree about it.
///
/// SIGTERM is a request a child is free to ignore, so a detached task sleeps for
/// the grace and then sends SIGKILL if the ending still has not arrived. It is a
/// task rather than a Dispatch timer, so ADR 0004's exceptions stay what they were,
/// and nothing awaits it, so the grace costs no caller anything. Asking twice
/// starts two escalations, and both are harmless: whichever wakes after the ending
/// sends nothing.
///
/// Foundation reaps the child a moment before it hands the exit status over, so
/// there is a window where the status still says running and the identifier has
/// already been passed on. Closing it would mean waiting on the child ourselves
/// rather than letting Foundation do it, which is a far bigger thing to get wrong
/// than that window is to live with. It is left open on purpose, and the
/// escalation samples the same window a second time, grace later (ADR 0006).
///
/// - Parameters:
///   - identifier: the child's process identifier.
///   - grace: how long the child is given after SIGTERM before SIGKILL.
///   - hasEnded: whether the child's exit status has already arrived.
func terminateChild(
    _ identifier: pid_t,
    grace: Duration,
    unlessEnded hasEnded: @escaping @Sendable () -> Bool
) {
    guard !hasEnded() else { return }

    kill(identifier, SIGTERM)

    Task.detached {
        try? await Task.sleep(for: grace)

        guard !hasEnded() else { return }

        kill(identifier, SIGKILL)
    }
}

/// How a drain of one whole stream ended.
private enum DrainOutcome: Sendable {
    /// End of file, with every byte the stream carried.
    case complete(Data)
    /// The stream carried more than the ceiling, so nothing of it was kept.
    case tooLarge
}

/// How a line by line read of stdout ended.
private enum LineOutcome: Sendable {
    /// End of file, with every line handed on.
    case endOfFile
    /// A line ran past the line ceiling, so it and everything after it was dropped.
    case lineTooLarge(limitInBytes: Int)
    /// The lines' buffer was full, so that line and everything after it was dropped.
    case fellBehind
}

/// What happened when a long lived child was launched.
private enum LaunchOutcome: Sendable {
    case launched(identifier: pid_t)
    case failed(reason: String)
}

/// The process setup both entry points share.
///
/// It is one function so a spawn description cannot come to mean one thing for a
/// one shot run and another for a long lived one. The process is built here and
/// stays with the caller: it is never handed across an isolation boundary.
private func makeProcess(for description: SpawnDescription) -> Process {
    let process = Process()
    process.executableURL = description.executable
    process.arguments = description.arguments
    process.environment = description.environment
    process.currentDirectoryURL = description.workingDirectory

    switch description.standardInput {
    case .devNull:
        process.standardInput = FileHandle.nullDevice
    }

    return process
}

/// How a finished process ended, read from the termination handler's own argument.
private func exitStatus(of finished: Process) -> ProcessExitStatus {
    finished.terminationReason == .uncaughtSignal
        ? .signaled(finished.terminationStatus)
        : .exited(finished.terminationStatus)
}

/// A child that never launched, as the failure the package reports for it.
private func launchFailure(_ error: any Error) -> HEYCliKitError {
    .processFailure(
        ProcessFailure(exitStatus: nil, standardError: "", reason: String(describing: error))
    )
}

/// Carries one value from a callback to whoever is awaiting it, exactly once.
///
/// Every waiter is remembered rather than one, because the ending is awaited from
/// as many places as care to ask: the watch pump, a sign in the app is following,
/// and a test beside either. A value that has already arrived is handed straight
/// back, so asking late is as good as asking early.
///
/// The wait is deliberately not cancellation aware: a cancelled run still has to
/// report how the child it terminated actually ended.
private final class DeliveryBox<Value: Sendable>: Sendable {
    private enum State {
        case waiting([CheckedContinuation<Value, Never>])
        case delivered(Value)
    }

    private let state = Mutex<State>(.waiting([]))

    func deliver(_ value: Value) {
        let waiting: [CheckedContinuation<Value, Never>] = state.withLock { state in
            // The first delivery is the one that counts: a value that arrived has
            // already been handed to everybody who was waiting for it.
            guard case let .waiting(continuations) = state else { return [] }

            state = .delivered(value)
            return continuations
        }

        for continuation in waiting {
            continuation.resume(returning: value)
        }
    }

    /// Whether the value has arrived, without waiting for it.
    ///
    /// Terminating reads this to decide whether there is still a child to signal.
    var isDelivered: Bool {
        state.withLock { state in
            guard case .delivered = state else { return false }

            return true
        }
    }

    var value: Value {
        get async {
            await withCheckedContinuation { continuation in
                let delivered: Value? = state.withLock { state in
                    switch state {
                    case let .delivered(value):
                        return value
                    case let .waiting(continuations):
                        state = .waiting(continuations + [continuation])
                        return nil
                    }
                }

                if let delivered {
                    continuation.resume(returning: delivered)
                }
            }
        }
    }
}

/// Reads one file descriptor to end of file off the cooperative pool, keeping no
/// more than the ceiling.
///
/// The read is blocking, so it runs on a global queue rather than on a thread the
/// cooperative pool needs back.
///
/// Passing the ceiling calls `onOverflow` at that moment, from inside the read,
/// and the read then carries on to end of file keeping nothing. Both halves matter.
/// A read that simply stopped would leave the child blocked writing into a full
/// pipe, never exiting. And a read that only asked the child to stop once it had
/// reached end of file would never ask a child that prints for ever, because such
/// a child never reaches it. The termination escalation bounds how long the rest
/// of the read can take.
private func readToEnd(
    _ fileDescriptor: Int32,
    ceiling: Int,
    onOverflow: @escaping @Sendable () -> Void
) async -> DrainOutcome {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            var data = Data()
            var isTooLarge = false
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)

            while true {
                // `errno` is only meaningful right after the call that set it, so it
                // is read inside the same closure rather than after the buffer access.
                let (count, failure) = buffer.withUnsafeMutableBytes { raw -> (Int, Int32) in
                    let count = read(fileDescriptor, raw.baseAddress, raw.count)

                    return (count, count < 0 ? errno : 0)
                }

                if count > 0 {
                    // Past the ceiling nothing more is kept, but the pipe is still
                    // read to end of file: a child blocked writing into a full pipe
                    // never exits, and then neither the other stream nor the exit
                    // status would ever arrive.
                    guard !isTooLarge else { continue }

                    if data.count + count > ceiling {
                        isTooLarge = true
                        data = Data()
                        onOverflow()
                    } else {
                        data.append(contentsOf: buffer[0 ..< count])
                    }
                } else if count == 0 {
                    break
                } else if failure != EINTR {
                    break
                }
            }

            continuation.resume(returning: isTooLarge ? .tooLarge : .complete(data))
        }
    }
}

/// Reads one file descriptor line by line, yielding each line as it arrives.
///
/// The split runs on bytes and only a complete line is ever turned into text, so a
/// UTF 8 sequence that straddles two reads is never cut in half. Empty lines are
/// dropped, and a last line the child printed without a trailing newline is still
/// delivered before end of file. Like the drain above, the blocking read runs on a
/// global queue rather than on a thread the cooperative pool needs back.
///
/// The read stops handing lines on for one of two reasons. A line longer than the
/// ceiling, which is checked while it is still growing so a child that never
/// prints a newline cannot grow it without bound, is dropped whole: a partial line
/// is not a line. And a line the buffer has no room for is dropped, leaving the
/// buffer as it was, so what the reader already has is a true prefix. Either way
/// `onOverflow` is called at that moment and the rest of the pipe is read to end of
/// file and dropped, for the reasons the drain above gives. A reader that has gone
/// away is neither: it is the reader's own cancellation, which has already asked
/// the child to stop, so the rest is dropped without failing or signalling
/// anything.
private func readLines(
    _ fileDescriptor: Int32,
    into continuation: AsyncThrowingStream<String, any Error>.Continuation,
    ceiling: Int,
    onOverflow: @escaping @Sendable () -> Void
) async -> LineOutcome {
    await withCheckedContinuation { finished in
        DispatchQueue.global(qos: .userInitiated).async {
            let newline = UInt8(ascii: "\n")
            var tail: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            // Set once, when the read stops handing lines on, and never cleared.
            var stopped: LineOutcome?
            // Set once nobody is reading the lines any more.
            var readerIsGone = false

            func stop(_ outcome: LineOutcome) {
                stopped = outcome
                tail.removeAll()
                onOverflow()
            }

            func hand(_ bytes: some Collection<UInt8>) {
                guard !bytes.isEmpty else { return }
                guard bytes.count <= ceiling else {
                    stop(.lineTooLarge(limitInBytes: ceiling))
                    return
                }

                switch continuation.yield(String(decoding: bytes, as: UTF8.self)) {
                case .enqueued:
                    break
                case .dropped:
                    stop(.fellBehind)
                case .terminated:
                    readerIsGone = true
                @unknown default:
                    readerIsGone = true
                }
            }

            while true {
                // `errno` is only meaningful right after the call that set it, so it
                // is read inside the same closure rather than after the buffer access.
                let (count, failure) = buffer.withUnsafeMutableBytes { raw -> (Int, Int32) in
                    let count = read(fileDescriptor, raw.baseAddress, raw.count)

                    return (count, count < 0 ? errno : 0)
                }

                if count > 0 {
                    guard stopped == nil, !readerIsGone else { continue }

                    var lineStart = 0
                    for index in 0 ..< count where buffer[index] == newline {
                        if tail.isEmpty {
                            hand(buffer[lineStart ..< index])
                        } else {
                            tail.append(contentsOf: buffer[lineStart ..< index])
                            let line = tail
                            tail.removeAll(keepingCapacity: true)
                            hand(line)
                        }

                        lineStart = index + 1

                        guard stopped == nil, !readerIsGone else { break }
                    }

                    guard stopped == nil, !readerIsGone else { continue }

                    tail.append(contentsOf: buffer[lineStart ..< count])
                    if tail.count > ceiling {
                        stop(.lineTooLarge(limitInBytes: ceiling))
                    }
                } else if count == 0 {
                    break
                } else if failure != EINTR {
                    break
                }
            }

            if stopped == nil, !readerIsGone {
                hand(tail)
            }

            finished.resume(returning: stopped ?? .endOfFile)
        }
    }
}
