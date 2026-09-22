import Foundation
import Testing

import HEYCliKit

/// What a test reads off a watch line.
///
/// The import is plain rather than `@testable` on purpose: the public surface
/// suite asserts that an app can read a watch through the shipped API alone, and
/// it shares these helpers with the watch suite, so a helper that reached for an
/// internal detail would take that guarantee with it.
extension WatchLine {
    /// Which case a line is, so a test can name one without a `case` pattern for
    /// every kind it is not asking about.
    enum Kind {
        case ready
        case disconnected
        case resync
        case added
        case updated
        case deleted
        case unrecognized
    }

    var kind: Kind {
        switch self {
        case .ready: .ready
        case .disconnected: .disconnected
        case .resync: .resync
        case .added: .added
        case .updated: .updated
        case .deleted: .deleted
        case .unrecognized: .unrecognized
        }
    }

    /// The change an added or an updated line carries, so a test can read one
    /// without spelling out both cases every time.
    var change: Change? {
        switch self {
        case let .added(change), let .updated(change): change
        default: nil
        }
    }

    /// The time the line carries, whichever kind of line it is. An unrecognised
    /// line carries the CLI's text and nothing read out of it, so it has none.
    var at: Date? {
        switch self {
        case let .ready(at), let .disconnected(at), let .resync(at, _): at
        case let .added(change), let .updated(change): change.at
        case let .deleted(deletion): deletion.at
        case .unrecognized: nil
        }
    }

    /// Whether the line describes a change from before the watch began, and nil
    /// for a line that carries no such flag at all.
    var isReplayed: Bool? {
        switch self {
        case let .added(change), let .updated(change): change.isReplayed
        case let .deleted(deletion): deletion.isReplayed
        default: nil
        }
    }
}

/// Compares the time a watch line carries to the text the CLI printed on it.
///
/// It applies to the three digit lines the watch fixtures carry and to nothing
/// finer: the formatter it reads the expected text with keeps three fractional
/// digits, so a line with more is compared with
/// `expect(_:isWithinAMicrosecondOf:)` against a literal instead. The nearest
/// double to those three digits is not always the one the formatter lands on, so
/// the comparison is to the microsecond rather than exact.
func expect(
    _ line: WatchLine?,
    isAt text: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let expected = try #require(formatter.date(from: text), sourceLocation: sourceLocation)
    let at = try #require(line?.at, sourceLocation: sourceLocation)

    #expect(
        abs(at.timeIntervalSince1970 - expected.timeIntervalSince1970) < 0.000_001,
        sourceLocation: sourceLocation
    )
}
