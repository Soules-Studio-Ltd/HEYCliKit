/// One sender waiting in the Screener, with the first topic they sent.
///
/// The entry stands for the sender, not for their mail: approving or denying it
/// decides what happens to everything that sender sends from now on, which is why
/// the id the CLI calls a clearance id is the entry's own identity.
public struct ScreenerEntry: Sendable, Hashable, Identifiable {
    /// The identifier of a Screener entry, which the CLI calls a clearance id.
    public struct ID: Sendable, Hashable {
        /// The number the CLI prints, and the one passed back on a decision.
        public let rawValue: Int

        public init(_ rawValue: Int) {
            self.rawValue = rawValue
        }
    }

    /// The clearance id, which is the one key with no honest default: an entry
    /// with no identity cannot be approved or denied, so it is refused instead.
    public let id: ID
    /// The sender's display name. The CLI leaves the key out when it is empty,
    /// which is what a sender HEY knows only by address prints, so an absent
    /// name reads as an empty string.
    public let name: String
    /// The sender's email address. The CLI leaves the key out when it is empty,
    /// so an absent address reads as an empty string.
    public let emailAddress: String
    /// The subject of what the sender sent. The CLI leaves the key out when it
    /// is empty, so a blank subject reads as an empty string.
    public let subject: String
    /// HEY's own short summary of what the sender sent. The CLI leaves the key
    /// out when it is empty, so an absent summary reads as an empty string.
    public let summary: String
    /// The topic the sender started, so an app can relate the entry to a posting.
    ///
    /// The CLI leaves `topic_id` out at zero, and a topic id of zero is a broken
    /// link, so an entry the package cannot relate to a posting is nil rather
    /// than a link that goes nowhere.
    public let topicID: TopicID?

    init(
        id: ID,
        name: String,
        emailAddress: String,
        subject: String,
        summary: String,
        topicID: TopicID?
    ) {
        self.id = id
        self.name = name
        self.emailAddress = emailAddress
        self.subject = subject
        self.summary = summary
        self.topicID = topicID
    }
}

extension ScreenerEntry.ID: CustomStringConvertible {
    public var description: String { String(rawValue) }
}

extension ScreenerEntry.ID {
    /// The value passed to the CLI, which names an entry by its number alone.
    var argumentValue: String { String(rawValue) }
}

extension ScreenerEntry: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case emailAddress = "email_address"
        case subject
        case summary
        case topicID = "topic_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = ID(try container.decode(Int.self, forKey: .id))
        // Every one of these is a key the CLI drops when its value is empty, so
        // an absent one is the zero value rather than an entry the package
        // cannot read, and with it the whole Screener list it sits in.
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress) ?? ""
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        topicID = try container.decodeIfPresent(Int.self, forKey: .topicID).map(TopicID.init)
    }
}
