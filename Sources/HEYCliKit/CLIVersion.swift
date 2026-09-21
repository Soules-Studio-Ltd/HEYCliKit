import Foundation

/// The version of the `hey` executable the client is running.
///
/// The semantic version is the only field the CLI always prints. A binary built
/// from source stamps its commit and its build date as `unknown`, or leaves them
/// out entirely, so both are optional here and neither can fail the read: a date
/// that is not a date is nil rather than a decoding failure. An app logging the
/// version next to a problem report is told what the binary said, for exactly the
/// binaries most likely to have something worth reporting.
public struct CLIVersion: Sendable, Hashable, Decodable {
    /// The semantic version, such as 1.4.0.
    public let version: String
    /// The commit the executable was built from, when it stamped one. Carried as
    /// the CLI printed it, so a build from source reads as `unknown` rather than
    /// as nothing.
    public let commit: String?
    /// When the executable was built, when it stamped a date that reads as one.
    public let date: Date?

    private enum CodingKeys: String, CodingKey {
        case version
        case commit
        case date
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        commit = try? container.decodeIfPresent(String.self, forKey: .commit)
        // The date goes through the envelope decoder's ISO 8601 strategy, which
        // throws on anything that is not a date, `unknown` among them. That is a
        // field the CLI could not fill, not output the package cannot read, so it
        // reads as nil and the version still answers.
        date = try? container.decodeIfPresent(Date.self, forKey: .date)
    }
}
