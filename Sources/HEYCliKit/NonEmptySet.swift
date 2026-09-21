/// A set of at least one member that keeps the order it was built in.
///
/// Every operation that acts on several things at once takes one of these, so an
/// app can never spawn a command with nothing to act on: emptiness is a type error
/// rather than a usage error the CLI reports at run time. Duplicates are dropped,
/// because naming the same thing twice on a command line asks for the same work
/// twice.
///
/// Insertion order is preserved because it is the order that reaches the command
/// line. Equality and hashing are on the members alone, though, so two sets of the
/// same members are equal whatever order they were written in, and a test can
/// assert what was asked for without caring how the app happened to order it.
/// There is no `Sequence` conformance, so the members are only ever reached
/// through ``elements``.
public struct NonEmptySet<Element: Hashable>: Hashable {
    /// The members, in the order they were first given.
    public let elements: [Element]

    /// Builds a set from one member and any number of others.
    ///
    /// Passing one array builds a set whose single member is that array, so use
    /// ``init(elements:)`` to build a set from the members of a sequence.
    public init(_ first: Element, _ rest: Element...) {
        elements = Self.deduplicated(CollectionOfOne(first) + rest)
    }

    /// Builds a set from the members of a sequence, or nothing when it holds none.
    ///
    /// Duplicates are dropped and the first time each member appears decides its
    /// place. The label is required on purpose: without it, `NonEmptySet(ids)` is
    /// the initialiser for one or more members, and builds a set of one array.
    /// Write `NonEmptySet(elements: ids)` whenever the members are in a sequence.
    public init?(elements: some Sequence<Element>) {
        let deduplicated = Self.deduplicated(elements)
        guard !deduplicated.isEmpty else { return nil }

        self.elements = deduplicated
    }

    /// The first member, which a set of at least one member always has.
    public var first: Element { elements[0] }

    /// How many members the set holds, which is never zero.
    public var count: Int { elements.count }

    /// Two sets are equal when they hold the same members, in whatever order.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        Set(lhs.elements) == Set(rhs.elements)
    }

    /// Hashes the members alone, so equal sets in different orders hash alike.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(Set(elements))
    }

    private static func deduplicated(_ elements: some Sequence<Element>) -> [Element] {
        var seen: Set<Element> = []

        return elements.filter { seen.insert($0).inserted }
    }
}

extension NonEmptySet: Sendable where Element: Sendable {}
