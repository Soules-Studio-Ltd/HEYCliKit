/// The senders waiting in the Screener, and how many are waiting in all.
///
/// The total count is the Screener's own count rather than the number of entries
/// read, so an app can show a badge that is right even when a later version of the
/// CLI stops printing every entry at once.
public struct Screener: Sendable, Hashable {
    /// The entries the CLI printed, in the order it printed them.
    public let entries: [ScreenerEntry]
    /// How many senders are waiting in all, from the envelope's `meta.total_count`.
    public let totalCount: Int

    init(entries: [ScreenerEntry], totalCount: Int) {
        self.entries = entries
        self.totalCount = totalCount
    }
}

extension Screener {
    /// Builds the Screener from a decoded envelope, or fails when it carried no count.
    ///
    /// A Screener with no count is a decoding failure rather than a count invented
    /// from the entries read: a badge the package guessed at would be wrong exactly
    /// when it matters. It is `package` so the live client and the fixture client
    /// build the Screener through this one path.
    package init(_ decoded: DecodedEnvelope<[ScreenerEntry]>) throws {
        guard let totalCount = decoded.totalCount else {
            throw HEYCliKitError.decodingFailure(
                DecodingFailure(
                    description: "The Screener list carried no meta.total_count.",
                    rawText: decoded.rawText
                )
            )
        }

        self.init(entries: decoded.data, totalCount: totalCount)
    }
}
