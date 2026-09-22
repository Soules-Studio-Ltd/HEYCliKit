/// One HEY mailbox linked to the signed in user.
///
/// The CLI's `active` flag is not exposed: it reports the selection made in the
/// user's own terminal, which an app must never be affected by.
public struct MailAccount: Sendable, Hashable, Identifiable {
    /// The identifier of a mail account, as the CLI spells it.
    public struct ID: Sendable, Hashable {
        public let rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public let id: ID
    /// The account's display name.
    public let name: String
    /// The account's email address.
    public let emailAddress: String
    /// What the account is for, such as home or work.
    public let purpose: String
    /// The account's status, as the CLI reports it.
    public let status: String

    init(id: ID, name: String, emailAddress: String, purpose: String, status: String) {
        self.id = id
        self.name = name
        self.emailAddress = emailAddress
        self.purpose = purpose
        self.status = status
    }
}

extension MailAccount.ID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// The payload of `hey account list`, with the account selection row dropped.
///
/// It is `package` so the fixture client can decode a scripted account list through
/// the same type the live client decodes.
package struct MailAccountList: Decodable {
    package let mailAccounts: [MailAccount]

    private struct Row: Decodable {
        let id: String
        let name: String
        let email: String?
        let purpose: String?
        let status: String?
    }

    package init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var accounts: [MailAccount] = []

        while !container.isAtEnd {
            let row = try container.decode(Row.self)
            guard row.id != AccountSelection.allArgumentValue else { continue }

            // The refusal names the field and never the account, since its id is
            // a value the CLI printed.
            func require(_ value: String?, or refusal: StaticString) throws -> String {
                guard let value else {
                    throw SchemaRefusal(message: refusal).decodingError(at: container.codingPath)
                }

                return value
            }

            accounts.append(
                MailAccount(
                    id: MailAccount.ID(row.id),
                    name: row.name,
                    emailAddress: try require(
                        row.email,
                        or: "The mail account is missing its email address."
                    ),
                    purpose: try require(row.purpose, or: "The mail account is missing its purpose."),
                    status: try require(row.status, or: "The mail account is missing its status.")
                )
            )
        }

        mailAccounts = accounts
    }
}
