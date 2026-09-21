import Foundation
import Testing

import HEYCliKit

/// The tag the live suite carries, so a maintainer can select it on its own from an
/// Xcode test plan, which is where tags are selectable. SwiftPM's `--filter` matches
/// test names rather than tags, so on the command line the suite is named directly:
/// `swift test --filter LiveContractTests`.
extension Tag {
    @Tag static var live: Self
}

/// How the live suite finds the binary it runs.
///
/// The package never searches for an executable, so the suite is told where one is
/// rather than guessing: the variable names a `hey` binary that is already signed
/// in, and its absence is what keeps the suite off every other machine.
enum LiveContract {
    /// The environment variable that names the signed in binary.
    static let environmentKey = "HEY_CLI_LIVE_EXECUTABLE"

    /// The executable the given environment names, or nothing when it names none.
    ///
    /// An empty value is no value: a variable exported without a path would
    /// otherwise run the suite against the current directory and fail as a launch
    /// failure, which reads as a broken package rather than a missing setting.
    static func executable(in environment: [String: String]) -> URL? {
        guard let path = environment[environmentKey], path.isEmpty == false else { return nil }

        return URL(filePath: path)
    }

    /// The executable this process was told to run, read from its own environment.
    static var executable: URL? {
        executable(in: ProcessInfo.processInfo.environment)
    }
}

/// The read only contract the package holds with a real binary.
///
/// Every other suite scripts the CLI's bytes, so this one exists for the moment the
/// bundled binary is bumped: one command answers whether the fixtures still match.
/// It is serialized because the tests share one account, and it reads only. No test
/// here moves a posting, marks one seen or unseen, answers the Screener, signs in or
/// signs out, so running it can never change the maintainer's own mail.
@Suite(
    "Live contract",
    .serialized,
    .tags(.live),
    .enabled(
        if: LiveContract.executable != nil,
        "Set HEY_CLI_LIVE_EXECUTABLE to a signed in hey binary to run the live contract suite"
    )
)
struct LiveContractTests {
    /// How long a watch is given to print its first ready line.
    private static let readyDeadline = Duration.seconds(20)

    /// The client every test here reads through, built once for each of them.
    private let client: HEYClient

    /// Builds that client, which the suite's own gate keeps from running anywhere
    /// the variable is unset.
    ///
    /// The path is required to exist here rather than left to the spawn, so a typo
    /// in the variable fails loudly with the path it was given instead of arriving
    /// inside each test as a launch failure. The account selection is the default,
    /// so the suite reads whatever the binary is signed in to.
    init() throws {
        let executable = try #require(
            LiveContract.executable,
            "The live suite ran without \(LiveContract.environmentKey) set."
        )
        let path = executable.path(percentEncoded: false)
        try #require(
            FileManager.default.fileExists(atPath: path),
            "\(LiveContract.environmentKey) names a file that does not exist: \(path)"
        )

        client = HEYClient.live(executable: executable)
    }

    @Test("The binary is signed in and its credentials have not expired")
    func binaryIsSignedIn() async throws {
        let status = try await client.signInStatus()

        #expect(
            status.isSignedIn,
            "Run hey auth login with the binary \(LiveContract.environmentKey) names, then run this suite again."
        )
        #expect(status.isExpired == false)
        #expect(status.expiresAt != nil)
    }

    @Test("The binary reports the version the fixtures were captured from")
    func versionMatchesTheTestedVersion() async throws {
        let version = try await client.version()

        // A binary newer than the fixtures is exactly what this suite exists to
        // catch: recapture the fixtures against it and move the tested version with
        // them. The expectation prints both versions, so the failure names both.
        #expect(version.version == HEYCliKit.testedCLIVersion)
        // The commit is whatever the build stamped, so only its presence is read.
        // A released binary always stamps one, and the model allows the build from
        // source that does not.
        #expect(version.commit?.isEmpty == false)
    }

    @Test("One Imbox page reads at the smallest page size HEY serves")
    func imboxPageReads() async throws {
        let page = try await client.boxPage(.imbox, pageSize: .minimum)

        #expect(page.postings.count <= PageSize.minimum.count)
        for posting in page.postings {
            #expect(posting.sender.emailAddress.isEmpty == false)
            // The fixture reads a topic URL and a bundle's own URL off one host, so
            // the live page is held to that host and never to a value: what is on
            // the maintainer's account is theirs, and only the shape is the package's.
            #expect(posting.appURL.host() == "app.hey.com")
            if case let .bundle(bundle) = posting {
                #expect(bundle.bundleAppURL.host() == "app.hey.com")
            }
        }
        // HEY prints a cursor only on a paging boundary, so a page short of the size
        // asked for has nothing more behind it. A full page may carry one or not,
        // which is HEY's own call and not something to assert against a live account.
        if page.postings.count < PageSize.minimum.count {
            #expect(page.nextCursor == nil)
        }
        if let cursor = page.nextCursor {
            #expect(cursor.rawValue.isEmpty == false)
        }
    }

    @Test("The Screener lists no more entries than it counts")
    func screenerReads() async throws {
        let screener = try await client.screener()

        #expect(screener.entries.count <= screener.totalCount)
        // An empty Screener is a healthy account rather than a failure, but it also
        // proves nothing about an entry, so the run says so out loud. It is printed
        // rather than recorded as a warning issue because the severity argument on
        // Issue.record is missing from the Swift Testing that Xcode 16 ships, and a
        // contributor running swift test there has to be able to build this file.
        if screener.entries.isEmpty {
            print("The Screener was empty, so the per entry checks did not run.")
        }
        for entry in screener.entries {
            #expect(entry.name.isEmpty == false)
            #expect(entry.emailAddress.isEmpty == false)
        }
    }

    @Test("A watch reaches its first ready and replays nothing as new mail")
    func watchReachesItsFirstReady() async throws {
        let log = LiveWatchLog()

        try await readToFirstReady(into: log)

        let ready = try #require(await log.readyLine)
        #expect(ready.kind == .ready)
        // A ready line carries the moment the watch began following its boxes.
        #expect(ready.at != nil)
        // Every change the CLI prints before its first ready happened before the
        // watch began, so none of it is new mail arriving now.
        #expect(await log.newMailBeforeReady == 0)
    }

    /// Reads a live watch up to its first ready line, and gives up rather than hang.
    ///
    /// The stream is a local of this function alone, so the child is gone before the
    /// caller reads what the log holds: the reader leaves the loop on the ready line
    /// and the deadline cancels it on the way out, and either ending drops the
    /// iterator, which terminates the stream with a cancelled reason. That reason is
    /// what the watch's own termination handler terminates the child on.
    private func readToFirstReady(into log: LiveWatchLog) async throws {
        let lines = try await client.watch(NonEmptySet(.imbox))

        // The read is raced against a deadline rather than given a time limit trait,
        // so a binary that never prints a ready fails with the lines it did print.
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Whichever task finishes first, the other is cancelled on the way out:
            // the ready returns, and a deadline or an ended child throws.
            defer { group.cancelAll() }

            group.addTask {
                for try await line in lines where await log.record(line) {
                    return
                }

                throw ReadyNotReached(reason: .streamEnded, lineCount: await log.lineCount)
            }
            group.addTask {
                try await Task.sleep(for: Self.readyDeadline)

                throw ReadyNotReached(
                    reason: .deadlinePassed(Self.readyDeadline),
                    lineCount: await log.lineCount
                )
            }

            try await group.next()
        }
    }
}

/// What the watch test read before its first ready line.
///
/// The reading task and the deadline task both touch it, so it is an actor rather
/// than a captured variable.
private actor LiveWatchLog {
    /// How many lines arrived, ready included.
    private(set) var lineCount = 0
    /// The first ready line, and nothing until one arrives.
    private(set) var readyLine: WatchLine?
    /// How many changes before the ready claimed to be new mail.
    private(set) var newMailBeforeReady = 0

    /// Records one line and says whether it was the ready the test is waiting for.
    func record(_ line: WatchLine) -> Bool {
        lineCount += 1

        switch line {
        case .ready:
            readyLine = line

            return true
        case let .added(change), let .updated(change):
            if change.isNewMail {
                newMailBeforeReady += 1
            }
        case let .deleted(deletion):
            // A deletion carries the flag as well, and it is read here rather than
            // through the change helper, which has nothing to give for this case.
            if deletion.isNewMail {
                newMailBeforeReady += 1
            }
        case .disconnected, .resync, .unrecognized:
            break
        }

        return false
    }
}

/// A watch that never printed a ready line.
private struct ReadyNotReached: Error, CustomStringConvertible {
    /// What ended the read short of a ready line.
    enum Reason {
        /// The watch was still running when the time it was given ran out.
        case deadlinePassed(Duration)
        /// The watch ended on its own before it printed a ready line.
        case streamEnded
    }

    /// Why the read gave up.
    let reason: Reason
    /// How many lines arrived before it did.
    let lineCount: Int

    var description: String {
        switch reason {
        case let .deadlinePassed(deadline):
            "The watch printed no ready line within \(deadline). Lines read: \(lineCount)."
        case .streamEnded:
            "The watch exited before it printed a ready line. Lines read: \(lineCount)."
        }
    }
}

/// The gate itself, which runs on every machine.
///
/// The suite above can only be exercised by a maintainer holding a signed in binary,
/// so the one piece of logic that decides whether it runs at all is tested here
/// against a dictionary rather than against the process environment.
@Suite("Live contract gate")
struct LiveContractGateTests {
    @Test("An environment without the variable names no executable")
    func missingVariableNamesNothing() {
        #expect(LiveContract.executable(in: [:]) == nil)
    }

    @Test("An empty value names no executable")
    func emptyVariableNamesNothing() {
        #expect(LiveContract.executable(in: [LiveContract.environmentKey: ""]) == nil)
    }

    @Test("A path names the executable at that path")
    func pathNamesTheExecutable() {
        #expect(
            LiveContract.executable(in: [LiveContract.environmentKey: "/usr/local/bin/hey"])
                == URL(filePath: "/usr/local/bin/hey")
        )
    }
}
