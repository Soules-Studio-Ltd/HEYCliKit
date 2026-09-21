/// Everything one approve decides: which senders, where their mail lands, and
/// whether what they already sent counts as read.
///
/// The destination and the seen flag are parameters of the approval rather than of
/// the client's operation, because the operations are closures and a closure
/// cannot carry default arguments.
public struct ScreenerApproval: Sendable, Hashable {
    /// The entries whose senders are being let through.
    public let entryIDs: NonEmptySet<ScreenerEntry.ID>
    /// The box the senders' mail lands in from now on.
    public let destination: BoxKind
    /// Whether what the senders already sent is marked seen, so approving a
    /// newsletter does not fill the destination with unseen rows.
    public let markSeen: Bool

    public init(
        entryIDs: NonEmptySet<ScreenerEntry.ID>,
        destination: BoxKind = .imbox,
        markSeen: Bool = false
    ) {
        self.entryIDs = entryIDs
        self.destination = destination
        self.markSeen = markSeen
    }
}
