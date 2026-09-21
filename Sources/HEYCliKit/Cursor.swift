/// The opaque value a page carries when more postings follow.
///
/// A cursor is only ever handed back to read the next page, so its text is HEY's
/// business and never the package's: it is read but never parsed. There is no
/// public initialiser on purpose, because the only cursor HEY answers to is one it
/// printed itself, and a cursor built by hand would fail at the CLI rather than at
/// the call site.
public struct Cursor: Sendable, Hashable {
    /// The cursor exactly as the CLI printed it, so an app can log it.
    public let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension Cursor: CustomStringConvertible {
    public var description: String { rawValue }
}
