/// HEY's confirmation of one approve or deny, and the sender it was about.
///
/// A Screener decision is the one mutation HEY answers with data rather than a
/// summary, so the package returns what HEY confirmed rather than a bare success.
public struct ScreenerDecision: Sendable, Hashable {
    /// What was decided about the sender.
    public enum Outcome: String, Sendable, Hashable, Decodable {
        /// The sender may write to the account from now on.
        case approved
        /// The sender is turned away from now on.
        case denied
    }

    /// The entry the decision was about.
    public let entryID: ScreenerEntry.ID
    /// The sender's display name, as HEY confirmed it.
    public let name: String
    /// The sender's email address, as HEY confirmed it.
    public let emailAddress: String
    /// What HEY says it did.
    public let outcome: Outcome

    init(entryID: ScreenerEntry.ID, name: String, emailAddress: String, outcome: Outcome) {
        self.entryID = entryID
        self.name = name
        self.emailAddress = emailAddress
        self.outcome = outcome
    }
}

extension ScreenerDecision: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case name
        case emailAddress = "email_address"
    }

    /// A status the package does not know fails the decode on purpose, so the
    /// package never tells an app a sender was approved when HEY said otherwise.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryID = ScreenerEntry.ID(try container.decode(Int.self, forKey: .id))
        name = try container.decode(String.self, forKey: .name)
        emailAddress = try container.decode(String.self, forKey: .emailAddress)
        outcome = try container.decode(Outcome.self, forKey: .status)
    }
}
