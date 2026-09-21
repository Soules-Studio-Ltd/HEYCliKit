import Foundation
import Testing

@testable import HEYCliKit
import HEYCliKitTestSupport

@Suite("Spawn shape")
struct SpawnShapeTests {
    /// Runs one operation against a scripted answer and returns the spawn it asked for.
    private func recordedSpawn(
        fixture: String,
        accountSelection: AccountSelection = .all,
        environment: [String: String] = ["HEY_CLI_KIT_TEST": "yes"],
        operation: (HEYClient) async throws -> Void
    ) async throws -> SpawnDescription {
        let (client, script) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: fixture))],
            accountSelection: accountSelection,
            environment: environment
        )

        try await operation(client)

        return try #require(script.recordedSpawns.first)
    }

    @Test(
        "Every operation spawns the executable it was given, from the home folder, with stdin closed",
        arguments: [
            ("auth-status.json", ["auth", "status"]),
            ("version.json", ["version"]),
            ("accounts.json", ["account", "list"]),
            ("imbox.json", ["box", "view", "imbox"]),
            ("screener.json", ["screener", "list"]),
            ("screener-approve.json", ["screener", "approve"]),
            ("screener-deny.json", ["screener", "deny"]),
            ("mutation-move.json", ["move", "1"]),
            ("mutation-seen.json", ["seen", "1"]),
            ("mutation-seen.json", ["unseen", "1"]),
            // Logout has no captured envelope of its own, and capturing one means
            // signing the machine out. The shape test reads only `ok`, so the move
            // confirmation stands in for it.
            ("mutation-move.json", ["auth", "logout"]),
        ]
    )
    func spawnRules(fixture: String, commandWords: [String]) async throws {
        let postingIDs = NonEmptySet(Posting.ID(1))

        let spawn = try await recordedSpawn(fixture: fixture) { client in
            switch commandWords {
            case ["auth", "status"]: _ = try await client.signInStatus()
            case ["version"]: _ = try await client.version()
            case ["account", "list"]: _ = try await client.mailAccounts()
            case ["box", "view", "imbox"]: _ = try await client.boxPage(.imbox)
            case ["screener", "list"]: _ = try await client.screener()
            case ["screener", "approve"]:
                _ = try await client.approveScreenerEntries(
                    ScreenerApproval(entryIDs: NonEmptySet(anEntryID))
                )
            case ["screener", "deny"]:
                _ = try await client.denyScreenerEntries(NonEmptySet(anEntryID))
            case ["move", "1"]: try await client.move(postingIDs, to: .laterbox)
            case ["seen", "1"]: try await client.markSeen(postingIDs)
            case ["auth", "logout"]: try await client.logout()
            default: try await client.markUnseen(postingIDs)
            }
        }

        #expect(spawn.executable == testExecutable)
        #expect(spawn.workingDirectory == FileManager.default.homeDirectoryForCurrentUser)
        #expect(spawn.standardInput == .devNull)
        #expect(spawn.standardOutput == .lines)
        #expect(spawn.environment["HEY_NONINTERACTIVE"] == "1")
        #expect(spawn.environment["HEY_CLI_KIT_TEST"] == "yes")
        // Nothing the app's own session exported reaches the child but the four
        // keys the allowlist copies, and no HEY variable at all beside the flag and
        // the marker this suite passes as its extra environment.
        try expectOnlyAllowedEnvironmentKeys(spawn)
        #expect(spawn.arguments.starts(with: commandWords))
        #expect(spawn.arguments.contains("--json"))
        #expect(spawn.arguments.argument(after: "--account") == "all")
    }

    @Test("A sign in discards the child's stdout, and a watch reads it as lines")
    func standardOutputPolicyOfTheLongLivedSpawns() async throws {
        let (client, script) = makeScriptedClient(outputs: [])

        // A sign in's stdout is an envelope nobody reads, so it goes nowhere rather
        // than into a buffer that a chatty CLI could fill.
        _ = try await client.login()
        _ = try await client.watch(NonEmptySet(.imbox))

        let spawns = script.recordedSpawns
        try #require(spawns.count == 2)
        #expect(spawns[0].arguments == ["auth", "login"])
        #expect(spawns[0].standardOutput == .discarded)
        #expect(spawns[1].arguments.first == "watch")
        #expect(spawns[1].standardOutput == .lines)
    }

    @Test("A single mail account selection is passed on the account argument")
    func singleMailAccountSelection() async throws {
        let spawn = try await recordedSpawn(
            fixture: "accounts.json",
            accountSelection: .mailAccount(MailAccount.ID("123456"))
        ) { client in
            _ = try await client.mailAccounts()
        }

        #expect(spawn.arguments.argument(after: "--account") == "123456")
    }

    @Test("A box read names the box kind and the page size it asked for")
    func boxReadCarriesItsKindAndPageSize() async throws {
        let pageSize = try #require(PageSize(50))

        let spawn = try await recordedSpawn(fixture: "imbox.json") { client in
            _ = try await client.boxPage(.feedbox, pageSize: pageSize)
        }

        #expect(spawn.arguments.starts(with: ["box", "view", "feedbox"]))
        #expect(spawn.arguments.argument(after: "--limit") == "50")
        #expect(spawn.arguments.contains("--page") == false)
    }

    @Test("A box read passes a cursor only when it was given one")
    func boxReadPassesACursorOnlyWhenGiven() async throws {
        let (client, script) = makeScriptedClient(
            outputs: [
                scriptedOutput(try HEYFixtures.data(named: "imbox-page-1.json")),
                scriptedOutput(try HEYFixtures.data(named: "imbox-page-2.json")),
            ]
        )

        let first = try await client.boxPage(.imbox)
        let cursor = try #require(first.nextCursor)
        _ = try await client.boxPage(.imbox, cursor: cursor)

        let second = try #require(script.recordedSpawns.last)
        #expect(script.recordedSpawns.first?.arguments.contains("--page") == false)
        #expect(second.arguments.argument(after: "--page") == cursor.rawValue)
        #expect(second.arguments.argument(after: "--limit") == "30")
        #expect(second.arguments.argument(after: "--account") == "all")
    }

    @Test(
        "A move names its destination box kind",
        arguments: [BoxKind.laterbox, .asidebox]
    )
    func moveNamesItsDestination(kind: BoxKind) async throws {
        let postingIDs = NonEmptySet(Posting.ID(1))

        let spawn = try await recordedSpawn(fixture: "mutation-move.json") { client in
            try await client.move(postingIDs, to: kind)
        }

        #expect(spawn.arguments.argument(after: "--to") == kind.rawValue)
    }

    @Test("A move passes its posting ids in the order it was given them")
    func moveKeepsItsPostingIDOrder() async throws {
        let postingIDs = NonEmptySet(Posting.ID(3), Posting.ID(1), Posting.ID(2))

        let spawn = try await recordedSpawn(fixture: "mutation-move.json") { client in
            try await client.move(postingIDs, to: .laterbox)
        }

        #expect(spawn.arguments.starts(with: ["move", "3", "1", "2"]))
    }

    @Test("A seen change names its posting ids and no destination")
    func seenChangesCarryTheirPostingIDs() async throws {
        let postingIDs = NonEmptySet(Posting.ID(2), Posting.ID(1))

        let seen = try await recordedSpawn(fixture: "mutation-seen.json") { client in
            try await client.markSeen(postingIDs)
        }
        let unseen = try await recordedSpawn(fixture: "mutation-seen.json") { client in
            try await client.markUnseen(postingIDs)
        }

        #expect(seen.arguments.starts(with: ["seen", "2", "1"]))
        #expect(unseen.arguments.starts(with: ["unseen", "2", "1"]))
        #expect(seen.arguments.contains("--to") == false)
        #expect(unseen.arguments.contains("--to") == false)
    }

    @Test("The caller's environment cannot switch off the non interactive flag")
    func nonInteractiveIsForced() async throws {
        let spawn = try await recordedSpawn(
            fixture: "version.json",
            environment: ["HEY_NONINTERACTIVE": "0", "HEY_CLI_KIT_TEST": "yes"]
        ) { client in
            _ = try await client.version()
        }

        #expect(spawn.environment["HEY_NONINTERACTIVE"] == "1")
    }

    @Test("Approving to the Imbox leaves the box argument off, since it is where a sender lands anyway")
    func approveToTheImboxHasNoBoxArgument() async throws {
        let spawn = try await recordedSpawn(fixture: "screener-approve.json") { client in
            _ = try await client.approveScreenerEntries(ScreenerApproval(entryIDs: NonEmptySet(anEntryID)))
        }

        #expect(spawn.arguments.contains("--box") == false)
        #expect(spawn.arguments.contains("--seen") == false)
        #expect(spawn.arguments.starts(with: ["screener", "approve", "100001"]))
    }

    @Test("Approving to another box passes that box's kind, never its display name")
    func approveToAnotherBoxPassesItsKind() async throws {
        let spawn = try await recordedSpawn(fixture: "screener-approve.json") { client in
            _ = try await client.approveScreenerEntries(
                ScreenerApproval(entryIDs: NonEmptySet(anEntryID), destination: .feedbox)
            )
        }

        #expect(spawn.arguments.argument(after: "--box") == "feedbox")
    }

    @Test("Marking what a sender already sent as seen adds the seen flag")
    func approveWithMarkSeenAddsTheFlag() async throws {
        let spawn = try await recordedSpawn(fixture: "screener-approve.json") { client in
            _ = try await client.approveScreenerEntries(
                ScreenerApproval(entryIDs: NonEmptySet(anEntryID), markSeen: true)
            )
        }

        #expect(spawn.arguments.contains("--seen"))
    }

    @Test("Several entries are passed as consecutive arguments in the order they were given")
    func entryIDsKeepTheirOrder() async throws {
        let spawn = try await recordedSpawn(fixture: "screener-approve.json") { client in
            _ = try await client.approveScreenerEntries(
                ScreenerApproval(entryIDs: NonEmptySet(ScreenerEntry.ID(100_003), anEntryID))
            )
        }

        #expect(spawn.arguments.starts(with: ["screener", "approve", "100003", "100001"]))
    }

    @Test("Denying takes the entries and nothing else")
    func denyPassesEntriesOnly() async throws {
        let spawn = try await recordedSpawn(fixture: "screener-deny.json") { client in
            _ = try await client.denyScreenerEntries(NonEmptySet(anEntryID))
        }

        #expect(spawn.arguments.starts(with: ["screener", "deny", "100001"]))
        #expect(spawn.arguments.contains("--box") == false)
        #expect(spawn.arguments.contains("--seen") == false)
    }
}

/// The entry the Screener fixtures were captured with.
private let anEntryID = ScreenerEntry.ID(100_001)
