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

    public let id: ID
    /// The sender's display name.
    public let name: String
    /// The sender's email address.
    public let emailAddress: String
    /// The subject of what the sender sent.
    public let subject: String
    /// HEY's own short summary of what the sender sent.
    public let summary: String
    /// The topic the sender started, so an app can relate the entry to a posting.
    public let topicID: TopicID

    init(id: ID, name: String, emailAddress: String, subject: String, summary: String, topicID: TopicID) {
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
        name = try container.decode(String.self, forKey: .name)
        emailAddress = try container.decode(String.self, forKey: .emailAddress)
        subject = try container.decode(String.self, forKey: .subject)
        summary = try container.decode(String.self, forKey: .summary)
        topicID = TopicID(try container.decode(Int.self, forKey: .topicID))
    }
}
