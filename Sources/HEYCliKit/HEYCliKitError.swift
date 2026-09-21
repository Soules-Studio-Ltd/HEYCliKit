/// The raw error fields of a CLI envelope, carried as opaque text.
///
/// The package never interprets these values. They are the envelope's `code`,
/// `error` and `hint` exactly as the CLI printed them, so an app can show or log
/// what actually happened.
public struct CLIErrorDetails: Sendable, Hashable {
    /// The envelope's `code`, when it carried one.
    public let code: String?
    /// The envelope's `error` text, when it carried one.
    public let message: String?
    /// The envelope's `hint` text, when it carried one.
    public let hint: String?

    /// Builds one, so an app can build a ``HEYCliKitError`` of its own: to stage a
    /// failure through the fixture client, or to test what it shows for one. The
    /// package builds its own from the envelope the CLI printed.
    ///
    /// Every field is optional because the CLI's own are: an envelope carries the
    /// ones it has, and details with none of them are the details a signed out
    /// command that printed no envelope on either stream arrives with.
    public init(code: String? = nil, message: String? = nil, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }
}

/// What the CLI printed when it could not be decoded as an envelope.
public struct DecodingFailure: Sendable, Hashable {
    /// A description of the underlying decoding error.
    public let description: String
    /// The CLI's stdout as text, decoded leniently.
    public let rawText: String

    /// Builds one, so an app can build a ``HEYCliKitError`` of its own: to stage a
    /// failure through the fixture client, or to test what it shows for one. The
    /// package builds its own from the bytes it could not decode.
    public init(description: String, rawText: String) {
        self.description = description
        self.rawText = rawText
    }
}

/// What the child process did when it failed outside the envelope contract.
public struct ProcessFailure: Sendable, Hashable {
    /// How the process ended, or nil when it could not be launched at all.
    public let exitStatus: ProcessExitStatus?
    /// The process's stderr as text, decoded leniently. Never parsed.
    public let standardError: String
    /// A description of the launch error, when the process could not be launched.
    public let reason: String?

    /// Builds one, so an app can build a ``HEYCliKitError`` of its own: to stage a
    /// failure through the fixture client, or to test what it shows for one. The
    /// package builds its own from the child it spawned.
    ///
    /// A nil exit status is the process that never launched, which is how an app
    /// stages a bundled executable that is missing: there is no exit code and no
    /// envelope to say it, so no scripted bytes can produce it and only a built
    /// failure can.
    public init(exitStatus: ProcessExitStatus?, standardError: String = "", reason: String? = nil) {
        self.exitStatus = exitStatus
        self.standardError = standardError
        self.reason = reason
    }
}

/// Everything the live client can fail with.
///
/// The cases that come from an envelope carry the CLI's raw `code`, `error` and
/// `hint` as opaque text, so an app can log exactly what the CLI said while still
/// branching on a meaning. The three ceiling cases carry the ceiling that was
/// passed instead, because the package stopped reading before there was anything
/// of the CLI's to carry: a read cut short is never decoded into a short answer
/// and a partial line is never handed on as a line.
public enum HEYCliKitError: Error, Sendable, Hashable {
    /// The CLI holds no valid credentials. The package never signs in on its own
    /// initiative and never retries after this.
    case signedOut(CLIErrorDetails)
    /// HEY could not be reached, or answered with a failure. The package does not
    /// guess whether the machine is offline.
    case unreachableOrFailed(CLIErrorDetails)
    /// The thing the command named does not exist.
    case notFound(CLIErrorDetails)
    /// The CLI rejected the command line itself.
    case usage(CLIErrorDetails)
    /// HEY asked for the command to be tried again later.
    case rateLimited(CLIErrorDetails)
    /// The envelope carried a code this version of the package does not know.
    case unknownCode(CLIErrorDetails)
    /// The CLI's stdout was not an envelope this package can decode.
    case decodingFailure(DecodingFailure)
    /// The process failed outside the envelope contract, or never launched.
    case processFailure(ProcessFailure)
    /// The process wrote more than the output ceiling on stdout or stderr, so the
    /// package stopped keeping it, terminated the process and decoded nothing.
    case outputTooLarge(limitInBytes: Int)
    /// A watch printed a line longer than the line ceiling, so the package dropped
    /// that line, terminated the process and ended the watch.
    case lineTooLarge(limitInBytes: Int)
    /// A watch's buffer filled because its lines were not being read, so the
    /// package terminated the process and ended the watch after the lines it had
    /// kept. Nothing after them is fabricated: the app starts another watch, with
    /// a since date if it wants what it missed.
    ///
    /// The number is the watch buffer bound whichever buffer filled, the one the
    /// app reads or the larger one inside the package behind it, so either way
    /// more lines than that were printed and waiting unread.
    case watchFellBehind(limitInLines: Int)
}

extension HEYCliKitError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .signedOut(details):
            "Signed out. \(details.text)"
        case let .unreachableOrFailed(details):
            "HEY unreachable or failed. \(details.text)"
        case let .notFound(details):
            "Not found. \(details.text)"
        case let .usage(details):
            "Usage error. \(details.text)"
        case let .rateLimited(details):
            "Rate limited. \(details.text)"
        case let .unknownCode(details):
            "Unknown error code. \(details.text)"
        case let .decodingFailure(failure):
            "The CLI output could not be decoded. \(failure.description)"
        case let .processFailure(failure):
            failure.text
        case let .outputTooLarge(limit):
            "The hey process wrote more than \(limit) bytes on one stream, so its output was not read."
        case let .lineTooLarge(limit):
            "The hey process printed a line longer than \(limit) bytes, so the watch was ended."
        case let .watchFellBehind(limit):
            "The watch fell more than \(limit) lines behind the CLI, so it was ended."
        }
    }
}

extension CLIErrorDetails {
    /// A one line rendering of the raw fields, for logs.
    fileprivate var text: String {
        var parts: [String] = []
        if let code { parts.append("code: \(code)") }
        if let message { parts.append("message: \(message)") }
        if let hint { parts.append("hint: \(hint)") }

        return parts.isEmpty ? "The CLI gave no details." : parts.joined(separator: ", ")
    }
}

extension ProcessFailure {
    /// A one line rendering of the failure, for logs.
    fileprivate var text: String {
        if let exitStatus {
            let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "The hey process failed with \(exitStatus)."
                : "The hey process failed with \(exitStatus): \(trimmed)"
        }

        return "The hey process could not be launched. \(reason ?? "No reason was reported.")"
    }
}
