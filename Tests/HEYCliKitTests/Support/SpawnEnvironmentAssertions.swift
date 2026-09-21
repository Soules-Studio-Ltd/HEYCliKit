import Foundation
import Testing

@testable import HEYCliKit

/// Every key a spawn is allowed to carry, spelled out rather than read off
/// ``ChildEnvironment``.
///
/// The four allowlisted keys, the two pinned ones, the non interactive flag and the
/// marker the suites pass as their extra environment. Reading the package's own
/// constant here would make the assertion agree with whatever the constant became,
/// so the list is duplicated on purpose and a key added to the allowlist has to be
/// added here too, deliberately.
private let allowedSpawnEnvironmentKeys: Set<String> = [
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "HOME",
    "PATH",
    "HEY_NONINTERACTIVE",
    "HEY_CLI_KIT_TEST",
]

/// Asserts that a recorded spawn carries nothing beyond the allowed keys, and that
/// no `HEY_*` variable but the non interactive flag and the suites' own marker
/// reached the child.
///
/// The suite runs inside a process whose own environment is a shell's, dozens of
/// keys wide, so the subset check would pass on a builder that simply copied a
/// short environment. The `#require` first is what rules that out: it fails the
/// test if this process inherited nothing worth dropping, which would mean the
/// assertion below proved nothing.
func expectOnlyAllowedEnvironmentKeys(
    _ spawn: SpawnDescription,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let droppedByTheAllowlist = Set(ProcessInfo.processInfo.environment.keys)
        .subtracting(allowedSpawnEnvironmentKeys)
    try #require(
        droppedByTheAllowlist.isEmpty == false,
        "The test process inherited nothing outside the allowlist, so this assertion would pass on any builder",
        sourceLocation: sourceLocation
    )

    #expect(
        Set(spawn.environment.keys).subtracting(allowedSpawnEnvironmentKeys) == [],
        sourceLocation: sourceLocation
    )
    #expect(
        spawn.environment.keys.filter {
            $0.hasPrefix("HEY_") && $0 != "HEY_NONINTERACTIVE" && $0 != "HEY_CLI_KIT_TEST"
        } == [],
        sourceLocation: sourceLocation
    )
}
