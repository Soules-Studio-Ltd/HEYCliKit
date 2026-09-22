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

/// A row in a box: one topic, a bundle of them, or a kind the package does not
/// model.
///
/// The CLI tells them apart with `kind`, which it spells `topic` and `bundle` for
/// the two the package models. The cases are named single and bundle instead, so
/// topic only ever means the conversation a single posting points at. Any other
/// kind, `entry` included, is an other posting carrying the CLI's `kind` as it
/// printed it, so a row HEY adds later still reaches the app instead of failing
/// the page or the watch line it sits in.
///
/// The fields every kind carries are stored on every case and forwarded here, so
/// a list that only shows a subject and a sender never has to know which kind it
/// is holding, while a view that opens one still gets the fields only its kind
/// has.
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
    /// A posting of a kind the package does not model, carrying the fields every
    /// kind shares and the kind the CLI printed.
    case other(Other)

    /// A posting that stands for exactly one topic. The CLI spells this kind `topic`.
    public struct Single: Sendable, Hashable, Identifiable {
        public let id: Posting.ID
        /// The subject line of the posting's topic. The CLI calls it `name` and
        /// leaves it out when it is empty, so a posting with a blank subject
        /// reads as an empty string rather than failing the page it sits on.
        public let subject: String
        /// When the topic last had activity.
        public let activeAt: Date
        /// When HEY last placed the posting in its box. Paging runs on this.
        public let observedAt: Date
        /// The web address that opens the posting in HEY.
        public let appURL: URL
        /// The box the posting was read from. The CLI leaves `box_id` out at
        /// zero, and zero names no box, so an absent one is nil.
        public let boxID: BoxID?
        /// Who the posting is from. The CLI calls it `creator`.
        public let sender: Contact
        /// Whether the user has opened the posting. A missing `seen` means unseen.
        public let isSeen: Bool
        /// The topic the posting points at.
        ///
        /// The CLI derives `topic_id` from the posting's app URL and leaves it
        /// out when it has none, and a topic id of zero is a broken link, so a
        /// box read can leave this nil. Inside a watch line the line's own
        /// `thread_id` fills it, since the CLI prints no topic id on a posting
        /// it carries there.
        public let topicID: TopicID?
        /// What kind of entry the topic holds, as opaque CLI text such as `message`
        /// or `announcement`. It is optional because the CLI may not print one.
        public let entryKind: String?
        /// HEY's own one line summary of the topic. The CLI prints none for a
        /// single posting it shows inside a bundle, which is where this is nil.
        public let summary: String?
        /// Everyone on the topic. The CLI leaves the key out when the list is
        /// empty, so an absent list reads as no contacts.
        public let contacts: [Contact]
        /// Everyone the topic is addressed to. The CLI leaves the key out when
        /// the list is empty, which is what a Bcc only mail prints, so an absent
        /// list reads as nobody addressed.
        public let addressedContacts: [Contact]
        /// How many entries of the topic HEY shows. The CLI leaves the key out
        /// at zero, so an absent count reads as zero.
        public let visibleEntryCount: Int
        /// The name HEY shows instead of the sender's own, when it prints one.
        public let alternativeSenderName: String?
    }

    /// A posting that groups several topics from one contact into one row.
    public struct Bundle: Sendable, Hashable, Identifiable {
        public let id: Posting.ID
        /// The bundle's title. The CLI calls it `name` and leaves it out when it
        /// is empty, so a bundle with a blank title reads as an empty string.
        public let subject: String
        /// When the bundle last had activity.
        public let activeAt: Date
        /// When HEY last placed the bundle in its box. Paging runs on this.
        public let observedAt: Date
        /// The web address that opens the bundle's row in HEY.
        public let appURL: URL
        /// The box the bundle was read from. The CLI leaves `box_id` out at
        /// zero, and zero names no box, so an absent one is nil.
        public let boxID: BoxID?
        /// Who the bundle is from. The CLI calls it `creator`.
        public let sender: Contact
        /// Whether the user has opened the bundle. A missing `seen` means unseen.
        public let isSeen: Bool
        /// The web address that opens the bundle itself. The CLI calls it
        /// `app_bundle_url` and leaves it out when it has none, so a bundle with
        /// no address of its own is nil. The row's own `appURL` is still there.
        public let bundleAppURL: URL?
    }

    /// A posting of a kind the package does not model.
    ///
    /// It carries the fields every posting shares, read exactly as a single
    /// posting and a bundle read them, and the CLI's `kind` as it printed it, so
    /// an app can draw it as a plain row, open it through `appURL`, or leave it
    /// out, which is the app's decision rather than the package's.
    public struct Other: Sendable, Hashable, Identifiable {
        public let id: Posting.ID
        /// The posting's subject or title. The CLI calls it `name` and leaves it
        /// out when it is empty, so a blank one reads as an empty string.
        public let subject: String
        /// When the posting last had activity.
        public let activeAt: Date
        /// When HEY last placed the posting in its box. Paging runs on this.
        public let observedAt: Date
        /// The web address that opens the posting in HEY.
        public let appURL: URL
        /// The box the posting was read from. The CLI leaves `box_id` out at
        /// zero, and zero names no box, so an absent one is nil.
        public let boxID: BoxID?
        /// Who the posting is from. The CLI calls it `creator`.
        public let sender: Contact
        /// Whether the user has opened the posting. A missing `seen` means unseen.
        public let isSeen: Bool
        /// The CLI's `kind`, as opaque text such as `entry`.
        ///
        /// It is a schema token and never a value out of a mailbox, so an app
        /// may log the distinct kinds it sees. It can be empty: the CLI leaves a
        /// key out instead of printing an empty string, so a posting printed
        /// with no `kind` at all reads as an other posting whose kind is `""`.
        public let kind: String
    }

    public var id: ID {
        switch self {
        case let .single(posting): posting.id
        case let .bundle(bundle): bundle.id
        case let .other(other): other.id
        }
    }

    /// The subject line of the posting's topic, the bundle's title, or an other
    /// posting's subject.
    public var subject: String {
        switch self {
        case let .single(posting): posting.subject
        case let .bundle(bundle): bundle.subject
        case let .other(other): other.subject
        }
    }

    /// When the posting last had activity.
    public var activeAt: Date {
        switch self {
        case let .single(posting): posting.activeAt
        case let .bundle(bundle): bundle.activeAt
        case let .other(other): other.activeAt
        }
    }

    /// When HEY last placed the posting in its box.
    public var observedAt: Date {
        switch self {
        case let .single(posting): posting.observedAt
        case let .bundle(bundle): bundle.observedAt
        case let .other(other): other.observedAt
        }
    }

    /// The web address that opens the posting in HEY.
    public var appURL: URL {
        switch self {
        case let .single(posting): posting.appURL
        case let .bundle(bundle): bundle.appURL
        case let .other(other): other.appURL
        }
    }

    /// The box the posting was read from, when the CLI named one.
    public var boxID: BoxID? {
        switch self {
        case let .single(posting): posting.boxID
        case let .bundle(bundle): bundle.boxID
        case let .other(other): other.boxID
        }
    }

    /// Who the posting is from.
    public var sender: Contact {
        switch self {
        case let .single(posting): posting.sender
        case let .bundle(bundle): bundle.sender
        case let .other(other): other.sender
        }
    }

    /// Whether the user has opened the posting.
    public var isSeen: Bool {
        switch self {
        case let .single(posting): posting.isSeen
        case let .bundle(bundle): bundle.isSeen
        case let .other(other): other.isSeen
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

/// The fields every posting carries, read once for whichever kind it is.
private struct SharedPostingFields {
    let id: Posting.ID
    let subject: String
    let activeAt: Date
    let observedAt: Date
    let appURL: URL
    let boxID: BoxID?
    let sender: Contact
    let isSeen: Bool

    init(_ container: KeyedDecodingContainer<PostingCodingKeys>) throws {
        // The id is the one shared field with no honest default: a row with no
        // identity is not a row, so a posting without one is refused.
        id = Posting.ID(try container.decode(Int.self, forKey: .id))
        // The CLI leaves `name` out when the subject is empty, so an absent key
        // is an empty subject rather than a posting the package cannot read.
        subject = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        activeAt = try container.decode(Date.self, forKey: .activeAt)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        appURL = try container.decode(URL.self, forKey: .appURL)
        // The CLI leaves `box_id` out at zero, and a box id of zero names no
        // box, so an absent key is no box id rather than a broken one.
        boxID = try container.decodeIfPresent(Int.self, forKey: .boxID).map(BoxID.init)
        sender = try container.decode(Contact.self, forKey: .creator)
        // The CLI omits `seen` for a posting the user has not opened, so a missing
        // key is unseen rather than a posting the package cannot read.
        isSeen = try container.decodeIfPresent(Bool.self, forKey: .seen) ?? false
    }
}

extension Posting: Decodable {
    /// What the CLI spells the two kinds the package models.
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
    /// line's topic. A box read has no line and passes nil.
    static func decode(
        from container: KeyedDecodingContainer<PostingCodingKeys>,
        fallbackTopicID: TopicID?
    ) throws -> Posting {
        // The CLI leaves a key out instead of printing an empty string, so an
        // absent kind is the empty kind, which is an other posting like any kind
        // the package does not model. A kind that is there but is not text still
        // fails the posting.
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""

        switch kind {
        case Self.singleKindValue:
            let shared = try SharedPostingFields(container)
            // The printed topic wins, then the line beside the posting, and a
            // posting with neither points at no topic at all.
            let topicID =
                try container.decodeIfPresent(Int.self, forKey: .topicID).map(TopicID.init)
                ?? fallbackTopicID

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
                    contacts: try container.decodeIfPresent([Contact].self, forKey: .contacts) ?? [],
                    addressedContacts: try container.decodeIfPresent(
                        [Contact].self,
                        forKey: .addressedContacts
                    ) ?? [],
                    visibleEntryCount: try container.decodeIfPresent(
                        Int.self,
                        forKey: .visibleEntryCount
                    ) ?? 0,
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
                    bundleAppURL: try container.decodeIfPresent(URL.self, forKey: .bundleAppURL)
                )
            )
        default:
            // A kind the package does not model is still a row: it carries the
            // shared fields, so the app decides whether and how to draw it, and a
            // watch line that holds one is still the change it is.
            let shared = try SharedPostingFields(container)

            return .other(
                Other(
                    id: shared.id,
                    subject: shared.subject,
                    activeAt: shared.activeAt,
                    observedAt: shared.observedAt,
                    appURL: shared.appURL,
                    boxID: shared.boxID,
                    sender: shared.sender,
                    isSeen: shared.isSeen,
                    kind: kind
                )
            )
        }
    }
}
