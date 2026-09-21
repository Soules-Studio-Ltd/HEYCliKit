import Foundation
import Testing

@testable import HEYCliKit

/// The environment builder on its own, with nothing spawned.
///
/// Every key the builder is allowed to pass through is spelled out here rather than
/// read off ``ChildEnvironment``. A test that read the constant would pass whatever
/// the constant became, which is the one thing this suite exists to catch.
@Suite("Child environment")
struct ChildEnvironmentTests {
    /// The home folder the builder is handed, standing in for the user's own.
    private let home = URL(filePath: "/Users/tester")

    /// An inherited environment holding one of everything: the four keys that are
    /// allowed through, the two that are pinned over, and a spread of the ones a
    /// hostile or merely careless session can export.
    private let inherited = [
        "HOME": "/x",
        "PATH": "/evil",
        "LANG": "en_GB.UTF-8",
        "TMPDIR": "/var/folders/zz/T/",
        "LC_ALL": "en_GB.UTF-8",
        "LC_CTYPE": "UTF-8",
        "HEY_TOKEN": "a-real-token",
        "HEY_BASE_URL": "https://hey.attacker.example",
        "XDG_CONFIG_HOME": "/tmp/hostile-config",
        "GODEBUG": "http2client=0",
        "HTTPS_PROXY": "http://attacker.example:8080",
        "SHELL": "/bin/zsh",
    ]

    @Test("The child gets the allowlist, the pinned values, the caller's extras and nothing else")
    func theResultIsExactlyTheAllowedKeys() {
        let environment = ChildEnvironment.build(
            inherited: inherited,
            extra: ["HEY_CLI_KIT_TEST": "yes"],
            home: home,
            nonInteractive: true
        )

        // Equality rather than a handful of presence checks: a key added to the
        // allowlist by accident only shows up as a failure if the whole dictionary
        // is the assertion.
        #expect(
            environment == [
                "LANG": "en_GB.UTF-8",
                "TMPDIR": "/var/folders/zz/T/",
                "LC_ALL": "en_GB.UTF-8",
                "LC_CTYPE": "UTF-8",
                "HOME": "/Users/tester",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HEY_CLI_KIT_TEST": "yes",
                "HEY_NONINTERACTIVE": "1",
            ]
        )
    }

    @Test("An allowlisted key the session never exported is absent, not empty")
    func anUnsetAllowlistedKeyStaysUnset() {
        let environment = ChildEnvironment.build(
            inherited: ["LANG": "en_GB.UTF-8"],
            extra: [:],
            home: home,
            nonInteractive: true
        )

        #expect(environment["LANG"] == "en_GB.UTF-8")
        #expect(environment.keys.contains("TMPDIR") == false)
        #expect(environment.keys.contains("LC_ALL") == false)
        #expect(environment.keys.contains("LC_CTYPE") == false)
    }

    @Test("An inherited path is ignored and the pinned one is used")
    func pathIsPinnedOverTheInheritedOne() {
        let environment = ChildEnvironment.build(
            inherited: ["PATH": "/evil:/usr/bin"],
            extra: [:],
            home: home,
            nonInteractive: true
        )

        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("An inherited home is ignored and the home the builder was given is used")
    func homeIsPinnedOverTheInheritedOne() {
        let environment = ChildEnvironment.build(
            inherited: ["HOME": "/tmp/fakehome"],
            extra: [:],
            home: home,
            nonInteractive: true
        )

        #expect(environment["HOME"] == "/Users/tester")
    }

    @Test("An extra overrides an inherited allowlisted key")
    func anExtraWinsOverTheInheritedValue() {
        let environment = ChildEnvironment.build(
            inherited: ["LANG": "en_GB.UTF-8"],
            extra: ["LANG": "fr_FR.UTF-8"],
            home: home,
            nonInteractive: true
        )

        #expect(environment["LANG"] == "fr_FR.UTF-8")
    }

    @Test("A HEY variable the app passed itself reaches the child, since the caller is trusted")
    func anExtraHEYVariableSurvives() {
        let environment = ChildEnvironment.build(
            inherited: inherited,
            extra: ["HEY_CACHE_DIR": "/Users/tester/Library/Caches/hey"],
            home: home,
            nonInteractive: true
        )

        #expect(environment["HEY_CACHE_DIR"] == "/Users/tester/Library/Caches/hey")
        // The inherited HEY variables are still dropped beside it.
        #expect(environment.keys.contains("HEY_TOKEN") == false)
        #expect(environment.keys.contains("HEY_BASE_URL") == false)
    }

    @Test("Neither the session nor the caller can switch the non interactive flag off")
    func nonInteractiveIsForcedOnLast() {
        let environment = ChildEnvironment.build(
            inherited: ["HEY_NONINTERACTIVE": "0"],
            extra: ["HEY_NONINTERACTIVE": "0"],
            home: home,
            nonInteractive: true
        )

        #expect(environment["HEY_NONINTERACTIVE"] == "1")
    }

    @Test("Neither the session nor the caller can force the non interactive flag on for a login")
    func nonInteractiveIsRemovedLast() {
        let environment = ChildEnvironment.build(
            inherited: ["HEY_NONINTERACTIVE": "1"],
            extra: ["HEY_NONINTERACTIVE": "1"],
            home: home,
            nonInteractive: false
        )

        #expect(environment.keys.contains("HEY_NONINTERACTIVE") == false)
    }
}
