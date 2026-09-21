import Foundation

/// A decoded success envelope: its payload, the one meta field the package reads,
/// and the raw stdout it came from.
///
/// The raw text travels with the payload so an operation that finds the envelope
/// short of something it needs can report what the CLI actually printed, exactly
/// as a decoding failure inside the envelope would have.
package struct DecodedEnvelope<Payload> {
    package let data: Payload
    let totalCount: Int?
    let rawText: String
}

/// Turns one finished spawn into the envelope the CLI printed, or throws the
/// mapped error.
///
/// A child killed by a signal is a process failure whatever it printed: it never
/// reached its own ending, so its stdout is not its account of what happened.
///
/// Every other ending decodes the envelope first, because the envelope is the
/// CLI's own account and it carries a code, a message and a hint the exit code
/// cannot. A decoded envelope therefore decides the meaning whatever the exit code
/// was, so an exit code this package has not seen never costs an app the CLI's own
/// words.
///
/// When stdout is not an envelope and the exit code is not zero, stderr is read
/// as an envelope next, because the CLI prints some failures there, a signed out
/// read among them. Only an envelope whose `ok` is false counts, and it maps by
/// the same rule as one from stdout, carrying its code, message and hint. Stderr
/// must hold that envelope alone: an envelope followed by a log line or any other
/// text is not an envelope, and falls through to the exit code. That gap is
/// accepted, since the CLI prints the bare envelope.
///
/// Only when neither stream yields an envelope does the exit code decide alone:
/// exit 3 is signed out, a clean exit is a decoding failure, and anything else is
/// a process failure. At a clean exit stderr is never read as an envelope, so a
/// success is never reinterpreted from the error stream.
///
/// What is left is what a success means, which is not the same for a read and for
/// a mutation, so the entry points below decide that for themselves.
private func decodeSuccessEnvelope<Payload: Decodable>(
    _ payloadType: Payload.Type,
    exitStatus: ProcessExitStatus,
    standardOutput: Data,
    standardError: Data
) throws -> Envelope<Payload> {
    let exitCode: Int32
    switch exitStatus {
    case let .exited(code):
        exitCode = code
    case .signaled:
        throw HEYCliKitError.processFailure(
            ProcessFailure(
                exitStatus: exitStatus,
                standardError: String(decoding: standardError, as: UTF8.self),
                reason: nil
            )
        )
    }

    let decoder = makeEnvelopeDecoder()
    let envelope: Envelope<Payload>
    do {
        envelope = try decoder.decode(Envelope<Payload>.self, from: standardOutput)
    } catch {
        // A failing command whose stdout is not an envelope may have printed its
        // failed envelope on stderr instead, which is where hey 1.4.0 prints a
        // signed out read's. Only a failed envelope is the CLI's account of a
        // failure, so a success envelope there is ignored, and a clean exit never
        // reads stderr at all.
        if exitCode != 0,
            let failure = try? decoder.decode(Envelope<OpaquePayload>.self, from: standardError),
            !failure.ok
        {
            throw mappedError(
                code: failure.code,
                exitCode: exitCode,
                details: CLIErrorDetails(code: failure.code, message: failure.error, hint: failure.hint)
            )
        }

        switch exitCode {
        case 3:
            // Exit 3 means signed out, whatever else the CLI printed. Nothing is
            // invented to fill the details it did not print.
            throw HEYCliKitError.signedOut(CLIErrorDetails(code: nil, message: nil, hint: nil))
        case 0:
            throw HEYCliKitError.decodingFailure(
                DecodingFailure(
                    description: String(describing: error),
                    rawText: String(decoding: standardOutput, as: UTF8.self)
                )
            )
        default:
            throw HEYCliKitError.processFailure(
                ProcessFailure(
                    exitStatus: exitStatus,
                    standardError: String(decoding: standardError, as: UTF8.self),
                    reason: nil
                )
            )
        }
    }

    guard envelope.ok, exitCode == 0 else {
        throw mappedError(
            code: envelope.code,
            exitCode: exitCode,
            details: CLIErrorDetails(code: envelope.code, message: envelope.error, hint: envelope.hint)
        )
    }

    return envelope
}

/// Turns one finished read into its decoded envelope, or throws the mapped error.
///
/// It adds the one rule a read has of its own: an envelope that reports success
/// but carries no data is a decoding failure, because the caller asked for a value
/// and there is none to give it. The envelope's own fields travel with the payload
/// for the operation that reads something beside it.
///
/// It is `package` rather than internal so the fixture client in the test support
/// product answers scripted bytes through this exact mapping. It is never public:
/// the package's contract is the client (ADR 0003).
package func decodeEnvelope<Payload: Decodable>(
    _ payloadType: Payload.Type,
    exitStatus: ProcessExitStatus,
    standardOutput: Data,
    standardError: Data
) throws -> DecodedEnvelope<Payload> {
    let envelope = try decodeSuccessEnvelope(
        payloadType,
        exitStatus: exitStatus,
        standardOutput: standardOutput,
        standardError: standardError
    )

    func rawText() -> String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    guard let data = envelope.data else {
        throw HEYCliKitError.decodingFailure(
            DecodingFailure(
                description: "The envelope reported success but carried no data.",
                rawText: rawText()
            )
        )
    }

    return DecodedEnvelope(data: data, totalCount: envelope.totalCount, rawText: rawText())
}

/// Turns one finished read into its payload, or throws the mapped error.
///
/// It is ``decodeEnvelope(_:exitStatus:standardOutput:standardError:)`` without the
/// envelope's own fields, for the reads that only want the value.
package func decodePayload<Payload: Decodable>(
    _ payloadType: Payload.Type,
    exitStatus: ProcessExitStatus,
    standardOutput: Data,
    standardError: Data
) throws -> Payload {
    try decodeEnvelope(
        payloadType,
        exitStatus: exitStatus,
        standardOutput: standardOutput,
        standardError: standardError
    ).data
}

/// Throws the mapped error for a spawn that did not succeed, and returns quietly
/// when it did.
///
/// It is the envelope and exit code reading with nothing decoded out of it, for
/// the callers that have no payload to read. A mutation is one: HEY confirms it
/// with `ok` and a summary in its own wording, so there is nothing to decode and
/// nothing to return, and a mutation that carried data would be confirmed just the
/// same. A watch that ended is the other, and its parting words are whatever it
/// printed after its last watch line. Either way the envelope and the exit code
/// are read exactly as a read reads them, so both fail with the same mapped errors.
///
/// It is `package` for the same reason the read above is: the fixture client
/// answers scripted bytes through it.
package func throwIfFailed(
    exitStatus: ProcessExitStatus,
    standardOutput: Data,
    standardError: Data
) throws {
    _ = try decodeSuccessEnvelope(
        OpaquePayload.self,
        exitStatus: exitStatus,
        standardOutput: standardOutput,
        standardError: standardError
    )
}

/// A payload that decodes from anything and holds none of it.
///
/// A mutation envelope's `data` key is not the package's business, so it is read
/// as whatever it is and dropped, rather than being a shape a future CLI could
/// break.
private struct OpaquePayload: Decodable {
    init(from decoder: any Decoder) throws {}
}

/// Maps a failed envelope to a meaning, by its `code` first and by the exit code
/// when it carries none. A code the package does not know is never guessed at.
private func mappedError(code: String?, exitCode: Int32, details: CLIErrorDetails) -> HEYCliKitError {
    switch code {
    case "auth": return .signedOut(details)
    case "api": return .unreachableOrFailed(details)
    case "not_found": return .notFound(details)
    case "usage": return .usage(details)
    case "rate_limit": return .rateLimited(details)
    case .some: return .unknownCode(details)
    case nil: break
    }

    switch exitCode {
    case 3: return .signedOut(details)
    case 7: return .unreachableOrFailed(details)
    case 2: return .notFound(details)
    case 5: return .rateLimited(details)
    default: return .unknownCode(details)
    }
}
