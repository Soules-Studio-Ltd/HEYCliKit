import Foundation
import Testing

@testable import HEYCliKit
import HEYCliKitTestSupport

/// Calls the operation the case names on the client, discarding whatever it returns.
///
/// The switch is exhaustive on purpose: an operation added to the client fails to
/// compile here until a test knows how to call it.
func perform(
    _ operation: HEYClientOperation,
    on client: HEYClient,
    postingIDs: NonEmptySet<Posting.ID>? = nil
) async throws {
    let postingIDs = postingIDs ?? NonEmptySet(Posting.ID(1))

    switch operation {
    case .signInStatus: _ = try await client.signInStatus()
    case .version: _ = try await client.version()
    case .mailAccounts: _ = try await client.mailAccounts()
    case .boxPage: _ = try await client.boxPage(.imbox)
    case .screener: _ = try await client.screener()
    case .approveScreenerEntries:
        _ = try await client.approveScreenerEntries(ScreenerApproval(entryIDs: NonEmptySet(anEntryID)))
    case .denyScreenerEntries: _ = try await client.denyScreenerEntries(NonEmptySet(anEntryID))
    case .move: try await client.move(postingIDs, to: .laterbox)
    case .markSeen: try await client.markSeen(postingIDs)
    case .markUnseen: try await client.markUnseen(postingIDs)
    case .watch:
        // The stream is drained, because a watch that was not scripted fails at
        // the call and one that was has lines the caller is meant to read.
        for try await _ in try await client.watch(NonEmptySet(.imbox)) {}
    case .login:
        // The handle is discarded: what a login does after it started is the
        // handle's business, and this only has to make the call.
        _ = try await client.login()
    case .logout: try await client.logout()
    }
}

/// The entry the Screener fixtures were captured with.
private let anEntryID = ScreenerEntry.ID(100_001)
