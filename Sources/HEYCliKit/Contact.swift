import Foundation

/// A person, a service or the signed in user, as a posting names them.
///
/// Only what a row realistically shows is exposed. The CLI also prints the
/// contact's `account_id`, its `updated_at` and a `contactable_type`, none of
/// which an app needs to render a name, so none of them are decoded.
public struct Contact: Sendable, Hashable, Identifiable {
    /// The identifier of a contact, as the CLI spells it.
    public struct ID: Sendable, Hashable {
        public let rawValue: Int

        public init(_ rawValue: Int) {
            self.rawValue = rawValue
        }
    }

    /// The contact's own identity, which is the one key with no honest default:
    /// a contact with no id is not a contact, so a posting carrying one is
    /// refused rather than read.
    public let id: ID
    /// The contact's display name. The CLI leaves the key out when it is empty,
    /// so a contact HEY knows only by address reads as an empty name.
    public let name: String
    /// The contact's email address. The CLI leaves the key out when it is empty,
    /// so an absent address reads as an empty string.
    public let emailAddress: String
    /// The initials HEY shows when there is no avatar. The CLI leaves the key
    /// out when it is empty, which is what a name with no letters prints, so an
    /// absent one reads as an empty string.
    public let initials: String
    /// The contact's avatar, when the CLI printed one.
    public let avatarURL: URL?
    /// The colour HEY draws behind the initials, as the hex text the CLI printed.
    /// It is carried as opaque text: the package never turns it into a colour.
    /// The CLI leaves the key out when it is empty, so an absent one reads as an
    /// empty string.
    public let avatarBackgroundColor: String

    init(
        id: ID,
        name: String,
        emailAddress: String,
        initials: String,
        avatarURL: URL?,
        avatarBackgroundColor: String
    ) {
        self.id = id
        self.name = name
        self.emailAddress = emailAddress
        self.initials = initials
        self.avatarURL = avatarURL
        self.avatarBackgroundColor = avatarBackgroundColor
    }
}

extension Contact.ID: CustomStringConvertible {
    public var description: String { String(rawValue) }
}

extension Contact: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case emailAddress = "email_address"
        case initials
        case avatarURL = "avatar_url"
        case avatarBackgroundColor = "avatar_background_color"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = ID(try container.decode(Int.self, forKey: .id))
        // Every one of these is text the CLI drops when it is empty, so an
        // absent key is an empty string rather than a contact the package
        // cannot read, and with it a whole page or watch line it sits on.
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress) ?? ""
        initials = try container.decodeIfPresent(String.self, forKey: .initials) ?? ""
        avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL)
        avatarBackgroundColor =
            try container.decodeIfPresent(String.self, forKey: .avatarBackgroundColor) ?? ""
    }
}
