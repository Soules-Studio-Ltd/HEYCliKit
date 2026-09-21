import Foundation

/// The numeric identifier of a box, as the CLI prints it on a posting.
///
/// A box is asked for by its kind, never by this id, so the id is carried only so
/// a posting can be related to the box it came from.
public struct BoxID: Sendable, Hashable {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// The identifier of one conversation in HEY.
public struct TopicID: Sendable, Hashable {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// A row in a box: one topic, or a bundle of them.
///
/// The CLI tells the two apart with `kind`, which it spells `topic` and `bundle`.
/// The cases are named single and bundle instead, so topic only ever means the
/// conversation a single posting points at.
///
/// The fields both kinds carry are stored on both cases and forwarded here, so a
/// list that only shows a subject and a sender never has to know which kind it is
/// holding, while a view that opens one still gets the fields only its kind has.
public enum Posting: Sendable, Hashable, Identifiable {
    /// The identifier of a posting, as the CLI spells it.
    public struct ID: Sendable, Hashable {
        public let rawValue: Int

        public init(_ rawValue: Int) {
            self.rawValue = rawValue
        }
    }

    /// A posting that stands for exactly one topic.
    case single(Single)
    /// A posting that groups several topics from one contact into one row.
    case bundle(Bundle)

    /// A posting that stands for exactly one topic. The CLI spells this kind `topic`.
    public struct Single: Sendable, Hashable, Identifiable {
        public let id: Posting.ID
        /// The subject line of the posting's topic. The CLI calls it `name`.
        public let subject: String
        /// When the topic last had activity.
        public let activeAt: Date
        /// When HEY last placed the posting in its box. Paging runs on this.
        public let observedAt: Date
        /// The web address that opens the posting in HEY.
        public let appURL: URL
        /// The box the posting was read from.
        public let boxID: BoxID
        /// Who the posting is from. The CLI calls it `creator`.
        public let sender: Contact
        /// Whether the user has opened the posting. A missing `seen` means unseen.
        public let isSeen: Bool
        /// The conversation the posting points at.
        public let topicID: TopicID
        /// What kind of entry the topic holds, as opaque CLI text such as `message`
        /// or `announcement`. It is optional because the CLI may not print one.
        public let entryKind: String?
        /// HEY's own one line summary of the topic. The CLI prints none for a
        /// single posting it shows inside a bundle, which is where this is nil.
        public let summary: String?
        /// Everyone on the topic.
        public let contacts: [Contact]
        /// Everyone the topic is addressed to.
        public let addressedContacts: [Contact]
        /// How many entries of the topic HEY shows.
        public let visibleEntryCount: Int
        /// The name HEY shows instead of the sender's own, when it prints one.
        public let alternativeSenderName: String?
    }

    /// A posting that groups several topics from one contact into one row.
    public struct Bundle: Sendable, Hashable, Identifiable {
        public let id: Posting.ID
        /// The bundle's title. The CLI calls it `name`.
        public let subject: String
        /// When the bundle last had activity.
        public let activeAt: Date
        /// When HEY last placed the bundle in its box. Paging runs on this.
        public let observedAt: Date
        /// The web address that opens the bundle's row in HEY.
        public let appURL: URL
        /// The box the bundle was read from.
        public let boxID: BoxID
        /// Who the bundle is from. The CLI calls it `creator`.
        public let sender: Contact
        /// Whether the user has opened the bundle. A missing `seen` means unseen.
        public let isSeen: Bool
        /// The web address that opens the bundle itself. The CLI calls it
        /// `app_bundle_url`.
        public let bundleAppURL: URL
    }

    public var id: ID {
        switch self {
        case let .single(posting): posting.id
        case let .bundle(bundle): bundle.id
        }
    }

    /// The subject line of the posting's topic, or the bundle's title.
    public var subject: String {
        switch self {
        case let .single(posting): posting.subject
        case let .bundle(bundle): bundle.subject
        }
    }

    /// When the posting last had activity.
    public var activeAt: Date {
        switch self {
        case let .single(posting): posting.activeAt
        case let .bundle(bundle): bundle.activeAt
        }
    }

    /// When HEY last placed the posting in its box.
    public var observedAt: Date {
        switch self {
        case let .single(posting): posting.observedAt
        case let .bundle(bundle): bundle.observedAt
        }
    }

    /// The web address that opens the posting in HEY.
    public var appURL: URL {
        switch self {
        case let .single(posting): posting.appURL
        case let .bundle(bundle): bundle.appURL
        }
    }

    /// The box the posting was read from.
    public var boxID: BoxID {
        switch self {
        case let .single(posting): posting.boxID
        case let .bundle(bundle): bundle.boxID
        }
    }

    /// Who the posting is from.
    public var sender: Contact {
        switch self {
        case let .single(posting): posting.sender
        case let .bundle(bundle): bundle.sender
        }
    }

    /// Whether the user has opened the posting.
    public var isSeen: Bool {
        switch self {
        case let .single(posting): posting.isSeen
        case let .bundle(bundle): bundle.isSeen
        }
    }
}

extension Posting.ID: CustomStringConvertible {
    public var description: String { String(rawValue) }
}

/// The keys of one posting, whichever kind it is.
///
/// They are declared once at file scope so the shared fields can be decoded by one
/// helper and each kind can then read only the keys it adds. They are internal
/// rather than private because a watch line holds its posting under a key of its
/// own and reads it through the container these name.
enum PostingCodingKeys: String, CodingKey {
    case kind
    case id
    case name
    case activeAt = "active_at"
    case observedAt = "observed_at"
    case appURL = "app_url"
    case boxID = "box_id"
    case creator
    case seen
    case topicID = "topic_id"
    case entryKind = "entry_kind"
    case summary
    case contacts
    case addressedContacts = "addressed_contacts"
    case visibleEntryCount = "visible_entry_count"
    case alternativeSenderName = "alternative_sender_name"
    case bundleAppURL = "app_bundle_url"
}

/// The fields every posting carries, read once for either kind.
private struct SharedPostingFields {
    let id: Posting.ID
    let subject: String
    let activeAt: Date
    let observedAt: Date
    let appURL: URL
    let boxID: BoxID
    let sender: Contact
    let isSeen: Bool

    init(_ container: KeyedDecodingContainer<PostingCodingKeys>) throws {
        id = Posting.ID(try container.decode(Int.self, forKey: .id))
        subject = try container.decode(String.self, forKey: .name)
        activeAt = try container.decode(Date.self, forKey: .activeAt)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        appURL = try container.decode(URL.self, forKey: .appURL)
        boxID = BoxID(try container.decode(Int.self, forKey: .boxID))
        sender = try container.decode(Contact.self, forKey: .creator)
        // The CLI omits `seen` for a posting the user has not opened, so a missing
        // key is unseen rather than a posting the package cannot read.
        isSeen = try container.decodeIfPresent(Bool.self, forKey: .seen) ?? false
    }
}

extension Posting: Decodable {
    /// What the CLI spells the two kinds it prints.
    private static let singleKindValue = "topic"
    private static let bundleKindValue = "bundle"

    public init(from decoder: any Decoder) throws {
        // A box read prints a posting whole, so there is no line beside it to take
        // a topic id from.
        self = try Self.decode(
            from: try decoder.container(keyedBy: PostingCodingKeys.self),
            fallbackTopicID: nil
        )
    }

    /// Reads one posting from the container its keys were found in.
    ///
    /// A watch line prints its single posting without a `topic_id` and carries the
    /// topic beside the posting instead, as `thread_id`, so the fallback is that
    /// line's topic. A box read has no line and passes nil, which leaves a single
    /// posting without a topic id a posting the package cannot read, as before.
    static func decode(
        from container: KeyedDecodingContainer<PostingCodingKeys>,
        fallbackTopicID: TopicID?
    ) throws -> Posting {
        // The kind is read before anything else, so a posting the package does not
        // know is reported as an unknown kind rather than as the first field of a
        // shape it was never going to fit.
        let kind = try container.decode(String.self, forKey: .kind)

        switch kind {
        case Self.singleKindValue:
            let shared = try SharedPostingFields(container)
            let topicID: TopicID
            if let printed = try container.decodeIfPresent(Int.self, forKey: .topicID) {
                topicID = TopicID(printed)
            } else if let fallbackTopicID {
                topicID = fallbackTopicID
            } else {
                throw DecodingError.keyNotFound(
                    PostingCodingKeys.topicID,
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: """
                            A single posting carries no topic_id, and nothing beside it named its topic.
                            """
                    )
                )
            }

            return .single(
                Single(
                    id: shared.id,
                    subject: shared.subject,
                    activeAt: shared.activeAt,
                    observedAt: shared.observedAt,
                    appURL: shared.appURL,
                    boxID: shared.boxID,
                    sender: shared.sender,
                    isSeen: shared.isSeen,
                    topicID: topicID,
                    entryKind: try container.decodeIfPresent(String.self, forKey: .entryKind),
                    summary: try container.decodeIfPresent(String.self, forKey: .summary),
                    contacts: try container.decode([Contact].self, forKey: .contacts),
                    addressedContacts: try container.decode([Contact].self, forKey: .addressedContacts),
                    visibleEntryCount: try container.decode(Int.self, forKey: .visibleEntryCount),
                    alternativeSenderName: try container.decodeIfPresent(
                        String.self,
                        forKey: .alternativeSenderName
                    )
                )
            )
        case Self.bundleKindValue:
            let shared = try SharedPostingFields(container)

            return .bundle(
                Bundle(
                    id: shared.id,
                    subject: shared.subject,
                    activeAt: shared.activeAt,
                    observedAt: shared.observedAt,
                    appURL: shared.appURL,
                    boxID: shared.boxID,
                    sender: shared.sender,
                    isSeen: shared.isSeen,
                    bundleAppURL: try container.decode(URL.self, forKey: .bundleAppURL)
                )
            )
        default:
            // A kind the package has not seen is a decoding failure that names it,
            // rather than a row an app would silently never show.
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "A posting of kind \"\(kind)\" is neither a single posting nor a bundle."
            )
        }
    }
}
