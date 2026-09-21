/// Which mail accounts a command covers.
///
/// The selection is fixed when the client is built and passed on every spawn, so
/// a change made in the user's terminal cannot alter what an app sees.
public enum AccountSelection: Sendable, Hashable {
    /// Every mail account linked to the signed in user.
    case all
    /// One mail account.
    case mailAccount(MailAccount.ID)
}

extension AccountSelection {
    /// The CLI's own name for the every account selection. It arrives in the
    /// account list as a row, but it is a selection, not a mail account.
    static let allArgumentValue = "all"

    /// The value passed to the CLI's `--account` argument.
    var argumentValue: String {
        switch self {
        case .all: Self.allArgumentValue
        case let .mailAccount(id): id.rawValue
        }
    }
}
