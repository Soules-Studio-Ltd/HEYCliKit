/// A Swift wrapper around the official HEY command line interface.
///
/// Every piece of data this package exposes comes from the `hey` executable, run
/// as a child process. The package never talks to HEY's servers directly, never
/// reads the CLI's stored credentials, and never holds a token of its own. If the
/// CLI cannot answer a question, neither can this package.
///
/// This is an unofficial, community project. It is not affiliated with, endorsed
/// by, or supported by 37signals. HEY is a trademark of 37signals.
public enum HEYCliKit {
    /// The version of the HEY CLI this package's fixtures were captured from, and
    /// the version its tests decode. It moves only when the fixtures are recaptured.
    public static let testedCLIVersion = "1.4.0"
}
