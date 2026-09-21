import Foundation

/// The environment a child sees: a fixed allowlist over the app's own, plus
/// whatever the app passed in, plus the non interactive flag settled last.
///
/// It is an allowlist rather than a denylist because the list of variables that
/// matter belongs to the CLI, not to the package. `hey` reads `HEY_BASE_URL`,
/// `HEY_TOKEN`, `HEY_CACHE_DIR`, `HEY_NO_KEYRING` and more today, `XDG_CONFIG_HOME`
/// decides where its config and its credentials file live, and the Go runtime under
/// it reads `GODEBUG` and the proxy variables. A denylist would have to stay right
/// about every one of those forever, including the ones a CLI version the package
/// was never built against adds. An allowlist is only ever wrong about a variable
/// somebody wanted, which is a feature request rather than a token sent to a host
/// the user never chose (ADR 0005).
enum ChildEnvironment {
    /// Keys copied from the inherited environment when present. Every other
    /// inherited key, `HEY_*` included, is dropped.
    ///
    /// These four say how the child formats text and where it writes scratch files.
    /// None of them can decide which host the CLI talks to, which credentials it
    /// reads or where it writes them, so passing them through keeps a child that
    /// behaves like the session it was launched from without giving that session a
    /// say in anything that matters.
    static let inheritedKeys: Set<String> = ["TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]

    /// Pinned rather than inherited: the child needs it only to find `open`.
    ///
    /// Nothing about credentials rests on it, because the CLI's keyring provider
    /// runs `/usr/bin/security` by absolute path. Login does: the CLI opens the sign
    /// in page with a bare `open` and lets Go search for it, so a child with no
    /// `PATH` could not start a sign in at all. These are the four system
    /// directories, which is also what launchd hands a Finder launched app, so for
    /// the way the apps are actually started this pins the value that was already
    /// there, while a directory a user's shell prepended can no longer decide which
    /// `open` runs.
    static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Builds the environment for one spawn.
    ///
    /// `HOME` and `PATH` are pinned, never inherited, whatever the inherited
    /// environment holds. `HOME` matters as much as `HEY_BASE_URL` does: the CLI
    /// resolves its config directory as `$XDG_CONFIG_HOME/hey-cli` or else
    /// `$HOME/.config/hey-cli`, and that config carries a `base_url` of its own, so
    /// a home folder somebody else chose is a host somebody else chose. The pinned
    /// value comes from `FileManager`, which reads the user record rather than
    /// `$HOME`, so the value being pinned is not itself the thing being defended
    /// against.
    ///
    /// The caller's extras go on top and are honoured verbatim, `HEY_*` keys
    /// included. The inherited environment is ambient state anybody with a
    /// `launchctl setenv` can write; the caller is the app, which chose the
    /// executable and the account selection already. So an app that genuinely needs
    /// a proxy or a cache directory passes it, and the allowlist is not in its way.
    ///
    /// `HEY_NONINTERACTIVE` is settled last, after the extras, so neither an
    /// inherited value nor a caller's can switch it off for a command or force it on
    /// for a login. It is settled here rather than in the spawn builder so that the
    /// rule is covered by the tests that need nothing spawned.
    ///
    /// An allowlisted key the inherited environment does not hold is absent from the
    /// result rather than present and empty, because a variable exported as empty
    /// and a variable never set are different things to the child.
    static func build(
        inherited: [String: String],
        extra: [String: String],
        home: URL,
        nonInteractive: Bool
    ) -> [String: String] {
        var environment = inherited.filter { inheritedKeys.contains($0.key) }
        environment["HOME"] = home.path
        environment["PATH"] = path
        for (key, value) in extra {
            environment[key] = value
        }
        environment["HEY_NONINTERACTIVE"] = nonInteractive ? "1" : nil

        return environment
    }
}
