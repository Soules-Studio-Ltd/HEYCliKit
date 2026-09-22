/// The stderr `hey auth login` writes for a sign in that failed, around the error
/// the CLI wrapped.
///
/// With stdout not a terminal, which is how the package spawns it, hey 1.4.0,
/// 1.4.3 and 1.6.0 all log their progress to stderr first, the sign in address
/// included, and then print the failed envelope there, indented, before exiting 3.
/// The address here is shaped like the real one with made up values in it, so a
/// test that classifies this text also shows the address never decides anything:
/// the real one carries the install id, which is why an app may only ever send the
/// kind a failure was classified as.
///
/// The fixture client builds the same text in `failedSignInStandardError(error:)`,
/// without the address line. The two stay separate copies because they live in
/// different products: the test support product ships to apps, and it must not
/// export a helper for this target's sake.
func signInStandardError(failingWith error: String) -> String {
    """

    Opening browser for authentication...
    If the browser doesn't open, visit: \(fakeSignInAddress)

    Waiting for authentication...
    {
      "ok": false,
      "error": "login failed: \(error)",
      "code": "auth",
      "hint": "Run: hey auth login"
    }

    """
}

/// A sign in address with the real one's shape and none of its values.
private let fakeSignInAddress =
    "https://app.hey.com/oauth/authorizations/new?client_id=fake-client-id"
    + "&install_id=fake-install-id&state=fake-state"
