import Foundation

/// Whether the CLI is signed in.
///
/// This is the one operation that answers rather than fails while the CLI is
/// signed out. `hey auth status --json` exits 0 and prints a success envelope
/// either way, so an app that asks the session first is handed a value with
/// ``isSignedIn`` false and is never thrown ``HEYCliKitError/signedOut(_:)``.
/// Every other command exits 3 while signed out and throws that error instead,
/// which is why this is the call an app makes before anything else.
///
/// A signed out status carries `authenticated` and nothing about credentials,
/// because there are none: ``isExpired`` is false and ``expiresAt`` is nil, and
/// neither says anything an app should read while ``isSignedIn`` is false.
///
/// The package reports this state and never signs in on its own initiative.
public struct SignInStatus: Sendable, Hashable {
    /// True when the CLI holds credentials it considers valid.
    public let isSignedIn: Bool
    /// True when those credentials have expired.
    ///
    /// False while signed out, where the CLI prints no `expired` key at all:
    /// there are no credentials to have expired.
    public let isExpired: Bool
    /// When the credentials expire, when the CLI reports it.
    ///
    /// Nil while signed out, for the same reason.
    public let expiresAt: Date?

    init(isSignedIn: Bool, isExpired: Bool, expiresAt: Date?) {
        self.isSignedIn = isSignedIn
        self.isExpired = isExpired
        self.expiresAt = expiresAt
    }
}

extension SignInStatus: Decodable {
    private enum CodingKeys: String, CodingKey {
        case isSignedIn = "authenticated"
        case isExpired = "expired"
        case expiresAt = "expires_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSignedIn = try container.decode(Bool.self, forKey: .isSignedIn)
        // `authenticated` is the only key both captured statuses share. A signed
        // out status stops there, so an absent `expired` is false rather than a
        // decoding failure that would cost an app the one answer it asked for.
        isExpired = try container.decodeIfPresent(Bool.self, forKey: .isExpired) ?? false
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    }
}
