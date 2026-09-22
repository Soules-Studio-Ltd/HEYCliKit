import Foundation
import Testing

/// Compares a decoded date to the microsecond the CLI printed.
///
/// The CLI prints up to nine fractional digits, and the nearest double to those
/// digits is not always the nearest double to the literal a test writes, so an
/// exact comparison would fail on a value that decoded correctly.
func expect(
    _ date: Date,
    isWithinAMicrosecondOf seconds: TimeInterval,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(date.timeIntervalSince1970 - seconds) < 0.000_001,
        sourceLocation: sourceLocation
    )
}
