import Foundation
import Testing

@testable import HEYCliKit

/// The meaning a mapped error carries, without its raw fields.
enum MappedMeaning: String, Sendable {
    case signedOut
    case unreachableOrFailed
    case notFound
    case usage
    case rateLimited
    case unknownCode
    case decodingFailure
    case processFailure
    case outputTooLarge
    case lineTooLarge
    case watchFellBehind
}

extension HEYCliKitError {
    /// The meaning this error stands for, so a table can name an expectation.
    var meaning: MappedMeaning {
        switch self {
        case .signedOut: .signedOut
        case .unreachableOrFailed: .unreachableOrFailed
        case .notFound: .notFound
        case .usage: .usage
        case .rateLimited: .rateLimited
        case .unknownCode: .unknownCode
        case .decodingFailure: .decodingFailure
        case .processFailure: .processFailure
        case .outputTooLarge: .outputTooLarge
        case .lineTooLarge: .lineTooLarge
        case .watchFellBehind: .watchFellBehind
        }
    }

    /// The CLI's raw fields, for the cases that carry them.
    var details: CLIErrorDetails? {
        switch self {
        case let .signedOut(details),
            let .unreachableOrFailed(details),
            let .notFound(details),
            let .usage(details),
            let .rateLimited(details),
            let .unknownCode(details):
            details
        case .decodingFailure, .processFailure, .outputTooLarge, .lineTooLarge, .watchFellBehind:
            nil
        }
    }
}

/// How the child process ended, named here rather than reused from the package so
/// the row type does not collide with the testing library's own exit status.
enum Ending: Sendable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    var description: String {
        switch self {
        case let .exited(code): "exit code \(code)"
        case let .signaled(signal): "signal \(signal)"
        }
    }
}

/// One row of the mapping table: what the CLI printed and how it ended, against
/// the meaning the package must report and the raw code it must keep.
struct MappingRow: Sendable, CustomStringConvertible {
    let standardOutput: String
    let standardError: String
    let ending: Ending
    let meaning: MappedMeaning
    let code: String?

    /// Whether what the CLI printed means one thing to a read and another to a
    /// mutation, which keeps the row out of the table a mutation is run against.
    let meansSomethingElseThroughAMutation: Bool

    var description: String {
        let printed = standardOutput.isEmpty ? "no output" : standardOutput

        return "\(meaning.rawValue) from \(ending) and \(printed) with stderr \(standardError)"
    }
}

/// A well formed error envelope carrying a code.
private func envelope(code: String) -> String {
    #"{"ok":false,"error":"Something happened","code":"\#(code)","hint":"Try this"}"#
}

/// A well formed error envelope with no code, so only the exit code is left.
private let codelessEnvelope = #"{"ok":false,"error":"Something happened"}"#

/// A well formed success envelope carrying a sign in status the client can decode.
private let successEnvelope = #"{"ok":true,"data":{"authenticated":true,"expired":false}}"#

/// The stderr every row is scripted with, so a process failure has something to
/// carry and an assertion on it means something.
private let standardErrorText = "stderr text"

extension Ending {
    /// One scripted answer that ends the way this row says.
    func output(standardOutput: String, standardError: String) -> ProcessOutput {
        let stdout = Data(standardOutput.utf8)
        let stderr = Data(standardError.utf8)

        switch self {
        case let .exited(code):
            return ProcessOutput(stdout: stdout, stderr: stderr, exitStatus: .exited(code))
        case let .signaled(signal):
            return ProcessOutput(stdout: stdout, stderr: stderr, exitStatus: .signaled(signal))
        }
    }
}

@Suite("Error mapping table")
struct ErrorMappingTableTests {
    /// One row, written short enough that the table reads as a table.
    static func row(
        _ standardOutput: String,
        _ ending: Ending,
        _ meaning: MappedMeaning,
        code: String? = nil,
        standardError: String = standardErrorText,
        meansSomethingElseThroughAMutation: Bool = false
    ) -> MappingRow {
        MappingRow(
            standardOutput: standardOutput,
            standardError: standardError,
            ending: ending,
            meaning: meaning,
            code: code,
            meansSomethingElseThroughAMutation: meansSomethingElseThroughAMutation
        )
    }

    /// Every row the package maps, by envelope code, by exit code, and by neither.
    static let rows: [MappingRow] = [
        // A code the package knows decides the meaning, whatever the exit code is.
        row(envelope(code: "auth"), .exited(3), .signedOut, code: "auth"),
        row(envelope(code: "api"), .exited(7), .unreachableOrFailed, code: "api"),
        row(envelope(code: "not_found"), .exited(2), .notFound, code: "not_found"),
        row(envelope(code: "usage"), .exited(1), .usage, code: "usage"),
        row(envelope(code: "rate_limit"), .exited(5), .rateLimited, code: "rate_limit"),
        row(envelope(code: "brand_new"), .exited(1), .unknownCode, code: "brand_new"),
        // An exit code outside the set the CLI documents never costs a well formed
        // envelope its own code, message and hint.
        row(envelope(code: "rate_limit"), .exited(9), .rateLimited, code: "rate_limit"),
        row(envelope(code: "auth"), .exited(0), .signedOut, code: "auth"),
        // A codeless envelope falls back to the exit code.
        row(codelessEnvelope, .exited(3), .signedOut),
        row(codelessEnvelope, .exited(7), .unreachableOrFailed),
        row(codelessEnvelope, .exited(2), .notFound),
        row(codelessEnvelope, .exited(5), .rateLimited),
        row(codelessEnvelope, .exited(9), .unknownCode),
        row(codelessEnvelope, .exited(1), .unknownCode),
        // Stdout that is not an envelope is read from the exit code alone: exit 3
        // means signed out whatever the CLI printed, a clean exit means the output
        // could not be decoded, and anything else means the process failed.
        row("not json at all", .exited(3), .signedOut),
        row("", .exited(3), .signedOut),
        row("not json at all", .exited(0), .decodingFailure),
        row("not json at all", .exited(1), .processFailure),
        row("", .exited(9), .processFailure),
        // A child killed by a signal never finished, so whatever it printed is not
        // its account of what happened: not an error envelope, not a success one.
        row("", .signaled(15), .processFailure),
        row(envelope(code: "auth"), .signaled(15), .processFailure),
        row(successEnvelope, .signaled(15), .processFailure),
        // Stdout that is not an envelope at a failing exit code leaves stderr to be
        // read, and a failed envelope there maps exactly as it would from stdout.
        // That is where hey 1.4.0 prints a signed out read's account.
        row("", .exited(3), .signedOut, code: "auth", standardError: envelope(code: "auth")),
        row("", .exited(1), .usage, code: "usage", standardError: envelope(code: "usage")),
        row("", .exited(2), .notFound, standardError: codelessEnvelope),
        // A signal still decides before either stream is read, and a clean exit
        // never reads stderr as an envelope.
        row("", .signaled(15), .processFailure, standardError: envelope(code: "auth")),
        row("not json at all", .exited(0), .decodingFailure, standardError: envelope(code: "auth")),
        // Stderr that is not a lone failed envelope falls through to the exit code:
        // prose, a success envelope, and an envelope followed by a log line.
        row("", .exited(3), .signedOut, standardError: "hey: not signed in"),
        row("", .exited(1), .processFailure, standardError: successEnvelope),
        row(
            "",
            .exited(3),
            .signedOut,
            standardError: envelope(code: "auth") + "\nlevel=info msg=\"shutting down\""
        ),
        // An envelope that reports success but carries no data is a decoding failure
        // for a read and a confirmation for a mutation, so only a read maps it here.
        row(
            #"{"ok":true}"#,
            .exited(0),
            .decodingFailure,
            meansSomethingElseThroughAMutation: true
        ),
    ]

    @Test("Every row maps to its meaning and keeps the CLI's own code", arguments: rows)
    func mapsEveryRow(row: MappingRow) async throws {
        let scripted = row.ending.output(
            standardOutput: row.standardOutput,
            standardError: row.standardError
        )
        let (client, _) = makeScriptedClient(outputs: [scripted])

        do {
            _ = try await client.signInStatus()
            Issue.record("The operation was expected to fail but returned a value.")
        } catch let error as HEYCliKitError {
            #expect(error.meaning == row.meaning)
            #expect(error.details?.code == row.code)

            // The two cases that carry no details carry the CLI's raw output
            // instead, and a row is only worth writing if that survives too.
            switch error {
            case let .decodingFailure(failure):
                #expect(failure.rawText == row.standardOutput)
            case let .processFailure(failure):
                #expect(failure.standardError == row.standardError)
                #expect(failure.exitStatus == scripted.exitStatus)
                #expect(failure.reason == nil)
            default:
                break
            }
        }
    }

    /// The rows a mutation reads exactly as a read reads them.
    ///
    /// Only one row is left out: an envelope that reports success but carries no
    /// data is a decoding failure for a read and a confirmation for a mutation,
    /// which the error mapping suite asserts on both sides.
    static let mutationRows = rows.filter { !$0.meansSomethingElseThroughAMutation }

    @Test(
        "Every row a mutation shares maps to the same meaning through a mutation",
        arguments: mutationRows
    )
    func mapsEveryRowThroughAMutation(row: MappingRow) async throws {
        let scripted = row.ending.output(
            standardOutput: row.standardOutput,
            standardError: row.standardError
        )
        let (client, _) = makeScriptedClient(outputs: [scripted])
        let postingIDs = NonEmptySet(Posting.ID(1))

        do {
            try await client.markSeen(postingIDs)
            Issue.record("The mutation was expected to fail but confirmed.")
        } catch let error as HEYCliKitError {
            #expect(error.meaning == row.meaning)
            #expect(error.details?.code == row.code)
        }
    }

    @Test("Signed out from an undecodable exit 3 carries no invented details")
    func signedOutWithoutAnEnvelope() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput("hey: not signed in", exitCode: 3, standardError: "boom")]
        )

        do {
            _ = try await client.signInStatus()
            Issue.record("The operation was expected to fail but returned a value.")
        } catch let HEYCliKitError.signedOut(details) {
            #expect(details.code == nil)
            #expect(details.message == nil)
            #expect(details.hint == nil)
        }
    }

    @Test("A well formed envelope at an unknown exit code keeps its message and hint")
    func envelopeSurvivesAnUnknownExitCode() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(envelope(code: "api"), exitCode: 9)]
        )

        do {
            _ = try await client.signInStatus()
            Issue.record("The operation was expected to fail but returned a value.")
        } catch let HEYCliKitError.unreachableOrFailed(details) {
            #expect(details.message == "Something happened")
            #expect(details.hint == "Try this")
        }
    }
}
