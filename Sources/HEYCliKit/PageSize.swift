/// How many postings one box read asks for.
///
/// HEY serves 30 postings first and 10 at a time after that, so a page size is 30
/// or a larger multiple of 10. Any other number returns rows with no cursor, which
/// silently ends paging, so the size is checked here rather than at a spawn: an
/// invalid size can never reach a command line.
public struct PageSize: Sendable, Hashable {
    /// The number of postings the page holds.
    public let count: Int

    /// Builds a page size, or nothing when HEY does not serve that size.
    ///
    /// Accepts 30 and every larger multiple of 10, and rejects everything else.
    public init?(_ count: Int) {
        guard count >= 30, count.isMultiple(of: 10) else { return nil }

        self.count = count
    }

    /// Builds a size the package itself knows HEY serves, so a constant of its own
    /// does not have to be unwrapped.
    private init(unchecked count: Int) {
        self.count = count
    }

    /// 30, the first page HEY serves and the smallest size it pages from.
    public static let minimum = PageSize(unchecked: 30)
}
