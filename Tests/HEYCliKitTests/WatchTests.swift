import Foundation
import Testing

@testable import HEYCliKit
import HEYCliKitTestSupport

/// The watch is exercised over the scripted runner: the client is the real one,
/// and the only thing replaced is the child it would have spawned.
@Suite("Watch")
struct WatchTests {
    /// Starts a watch and hands back its lines, the child the test drives and the
    /// script that recorded the spawn.
    private func startWatch(
        _ boxKinds: NonEmptySet<BoxKind> = NonEmptySet(.imbox),
        since: Date? = nil
    ) async throws -> (
        lines: AsyncThrowingStream<WatchLine, any Error>,
        process: ScriptedProcess,
        script: ProcessRunnerScript
    ) {
        let (client, script) = makeScriptedClient(outputs: [])
        let lines = try await client.watch(boxKinds, since: since)

        return (lines, try #require(script.startedProcesses.first), script)
    }

    /// Replays a shipped ndjson fixture as a whole watch that then exits cleanly.
    private func replay(_ fixture: String) async throws -> [WatchLine] {
        let watch = try await startWatch()
        try watch.process.emit(contentsOf: fixture)
        watch.process.end(.exited(0))

        var decoded: [WatchLine] = []
        for try await line in watch.lines {
            decoded.append(line)
        }

        return decoded
    }

    @Test("A watch spawns the watch command with one box argument for the kind it was given")
    func watchSpawnShape() async throws {
        let watch = try await startWatch()

        let spawn = try #require(watch.script.recordedSpawns.first)
        #expect(spawn.arguments == ["watch", "--json", "--account", "all", "--box", "imbox"])
        #expect(spawn.executable == testExecutable)
        #expect(spawn.workingDirectory == FileManager.default.homeDirectoryForCurrentUser)
        #expect(spawn.standardInput == .devNull)
        #expect(spawn.environment["HEY_NONINTERACTIVE"] == "1")
        // A watch is started rather than run, so the allowlist is asserted here too:
        // the two entry points build their spawn the same way and must stay that way.
        try expectOnlyAllowedEnvironmentKeys(spawn)
        #expect(spawn.arguments.contains("--since") == false)
        #expect(spawn.arguments.contains("--calendar") == false)
    }

    @Test("A watch over two box kinds names each one, in the order the set was built")
    func watchNamesEveryBoxKind() async throws {
        let watch = try await startWatch(NonEmptySet(.feedbox, .imbox))

        let spawn = try #require(watch.script.recordedSpawns.first)
        #expect(
            spawn.arguments
                == ["watch", "--json", "--account", "all", "--box", "feedbox", "--box", "imbox"]
        )
    }

    @Test("A since date reaches the command line as RFC 3339 in whole seconds")
    func watchPassesItsSinceDate() async throws {
        let watch = try await startWatch(since: Date(timeIntervalSince1970: 1_788_476_400))

        let spawn = try #require(watch.script.recordedSpawns.first)
        #expect(spawn.arguments.argument(after: "--since") == "2026-09-03T23:00:00Z")
    }

    @Test("A captured watch session decodes line by line, in fixture order")
    func watchSessionDecodesLineByLine() async throws {
        let decoded = try await replay("watch-session.ndjson")

        #expect(decoded.count == 28)
        #expect(decoded.first?.kind == .ready)
        try expect(decoded.first, isAt: "2026-09-03T20:55:14.906Z")
        #expect(decoded[1].kind == .disconnected)
        try expect(decoded[1], isAt: "2026-09-03T20:57:11.599Z")
        // The fixture opens with a ready, so nothing in it was replayed.
        #expect(decoded.compactMap(\.change).allSatisfy { $0.isReplayed == false })
        #expect(decoded.filter { $0.kind == .ready }.count == 5)

        let newMail = try #require(decoded[7].change)
        #expect(newMail.postingID == Posting.ID(100_002))
        #expect(newMail.topicID == TopicID(100_003))
        #expect(newMail.isNewMail)
        #expect(newMail.box == .imbox)
        #expect(newMail.posting.id == Posting.ID(100_002))
        if case let .single(posting) = newMail.posting {
            #expect(posting.topicID == TopicID(100_003))
        } else {
            Issue.record("Line 8 was expected to carry a single posting.")
        }

        #expect(decoded[12].change?.isNewMail == false)
        #expect(decoded[14].change?.isNewMail == false)

        // The CLI prints no thread_id beside a bundle it only touched, and one
        // beside the bundle whose topic changed.
        let bundleWithoutTopic = try #require(decoded[19].change)
        #expect(bundleWithoutTopic.topicID == nil)
        #expect(bundleWithoutTopic.postingID == Posting.ID(100_020))
        if case .bundle = bundleWithoutTopic.posting {} else {
            Issue.record("Line 20 was expected to carry a bundle.")
        }

        let bundleWithTopic = try #require(decoded[21].change)
        #expect(bundleWithTopic.topicID == TopicID(100_022))
        #expect(bundleWithTopic.postingID == Posting.ID(100_020))
    }

    @Test(
        "A change line whose posting has no addressed contacts is a change and not an unrecognised line",
        arguments: ["added", "updated"]
    )
    func changeLineWithoutAddressedContactsIsAChange(change: String) async throws {
        // The captured arrival of a new mail, with the key the CLI drops from a
        // Bcc only or undisclosed recipients mail taken out of its posting. Any
        // decoding failure inside a line makes the whole line unrecognised, so
        // before this the app was told nothing at all about such a mail.
        let captured = try FixtureJSON.line(.newMailArrival, ofFixtureNamed: "watch-session.ndjson")
        let derived = try FixtureJSON.replacing(
            "change",
            with: change,
            at: .watchLine,
            in: try FixtureJSON.removing(
                "addressed_contacts",
                at: .watchLinePosting,
                from: captured
            )
        )

        let watch = try await startWatch()
        watch.process.emit(String(decoding: derived, as: UTF8.self))
        // The child ends before anything reads the stream, so a line the package
        // cannot read fails the test rather than leaving it waiting for another.
        watch.process.end(.exited(0))

        var decoded: [WatchLine] = []
        for try await line in watch.lines {
            decoded.append(line)
        }

        #expect(decoded.count == 1)
        let line = try #require(decoded.first)
        #expect(line.kind == (change == "added" ? .added : .updated))
        let changed = try #require(line.change)
        guard case let .single(posting) = changed.posting else {
            Issue.record("The line was expected to carry a single posting.")
            return
        }

        #expect(posting.addressedContacts.isEmpty)
        // The CLI prints no topic id on a posting inside a watch line, so the
        // line's own thread_id is what names the topic on both kinds of change.
        #expect(posting.topicID == TopicID(100_003))
    }

    @Test("A captured bundle growth decodes its replayed lines and then its live ones")
    func watchBundleGrowthDecodesLineByLine() async throws {
        let decoded = try await replay("watch-bundle-growth.ndjson")

        #expect(decoded.count == 27)

        let replayed = decoded.prefix(15).compactMap(\.change)
        #expect(replayed.count == 15)
        #expect(replayed.allSatisfy { $0.isReplayed })
        #expect(replayed.allSatisfy { $0.isNewMail == false })
        #expect(decoded.prefix(15).filter { $0.kind == .added }.count == 11)
        #expect(decoded.prefix(15).filter { $0.kind == .updated }.count == 4)

        // The CLI omits the summary of a single posting it prints inside a bundle.
        if case let .single(posting) = try #require(decoded[6].change).posting {
            #expect(posting.summary == nil)
            #expect(posting.id == Posting.ID(100_021))
        } else {
            Issue.record("Line 7 was expected to carry a single posting.")
        }

        #expect(decoded[15].kind == .ready)
        try expect(decoded[15], isAt: "2026-09-03T23:43:56.432Z")

        // Five pairs follow the ready: a posting arrives, and the bundle it joined
        // is updated with no thread_id of its own.
        for pair in 0 ..< 5 {
            let arrival = try #require(decoded[16 + pair * 2].change)
            let growth = try #require(decoded[17 + pair * 2].change)

            #expect(decoded[16 + pair * 2].kind == .added)
            #expect(decoded[17 + pair * 2].kind == .updated)
            #expect(arrival.topicID != nil)
            #expect(growth.postingID == Posting.ID(100_023))
            #expect(growth.topicID == nil)
            #expect(arrival.isNewMail)
            #expect(growth.isNewMail)
            #expect(arrival.isReplayed == false)
            #expect(growth.isReplayed == false)
        }

        let last = try #require(decoded[26].change)
        #expect(decoded[26].kind == .added)
        #expect(last.postingID == Posting.ID(100_049))
        #expect(last.topicID == TopicID(100_050))
        #expect(last.isReplayed == false)
    }

    @Test("An idle capture decodes a backlog of unseen postings and a bundle with no topic")
    func watchIdleImboxDecodesLineByLine() async throws {
        let decoded = try await replay("watch-idle-imbox.ndjson")

        #expect(decoded.count == 8)

        // The capture's only ready is its last line, so every change in it is a
        // replayed one, and the CLI printed `new: false` beside each of them.
        let replayed = decoded.prefix(7).compactMap(\.change)
        #expect(replayed.count == 7)
        #expect(replayed.allSatisfy { $0.isReplayed })
        #expect(replayed.allSatisfy { $0.isNewMail == false })
        #expect(replayed.allSatisfy { $0.box == .imbox })
        // Not one posting in this capture carries a `seen` key, and a posting the
        // CLI prints no `seen` for is unseen rather than one it could not read.
        #expect(replayed.allSatisfy { $0.posting.isSeen == false })

        // The six mails the replay brought back, read off the fixture: the posting
        // each line was about, the topic it named, the subject and summary of that
        // topic, and the time the line carried.
        let arrivals: [
            (postingID: Int, topicID: Int, subject: String, summary: String, at: String)
        ] = [
            (100_072, 100_073, "Test subject 12", "Test summary 13", "2026-09-03T23:46:10.883Z"),
            (100_075, 100_076, "Test subject 13", "Test summary 14", "2026-09-03T23:46:54.959Z"),
            (100_077, 100_078, "Test subject 14", "Test summary 15", "2026-09-03T23:47:29.459Z"),
            (100_079, 100_080, "Test subject 15", "Test summary 16", "2026-09-03T23:48:02.634Z"),
            (100_081, 100_082, "Test subject 16", "Test summary 17", "2026-09-03T23:48:36.393Z"),
            (100_083, 100_003, "Test subject 17", "Test summary 18", "2026-09-03T23:50:05.721Z"),
        ]

        for (index, expected) in arrivals.enumerated() {
            let arrival = try #require(decoded[index].change)
            #expect(decoded[index].kind == .added)
            #expect(arrival.postingID == Posting.ID(expected.postingID))
            #expect(arrival.topicID == TopicID(expected.topicID))
            try expect(decoded[index], isAt: expected.at)

            guard case let .single(posting) = arrival.posting else {
                Issue.record("Line \(index + 1) was expected to carry a single posting.")

                continue
            }

            #expect(posting.id == Posting.ID(expected.postingID))
            // The CLI prints no topic_id inside a watch line's posting, so the
            // topic a posting points at is the one its line named.
            #expect(posting.topicID == TopicID(expected.topicID))
            #expect(posting.subject == expected.subject)
            #expect(posting.summary == expected.summary)
            #expect(posting.entryKind == "message")
            #expect(posting.boxID == BoxID(100_071))
            #expect(posting.visibleEntryCount == 1)
            #expect(posting.isSeen == false)
        }

        // The CLI prints no thread_id beside a bundle it only touched, so this
        // line names the bundle's posting and no topic at all.
        let touched = try #require(decoded[6].change)
        #expect(decoded[6].kind == .updated)
        #expect(touched.topicID == nil)
        #expect(touched.postingID == Posting.ID(100_085))
        try expect(decoded[6], isAt: "2026-09-03T23:48:36.441Z")

        guard case let .bundle(bundle) = touched.posting else {
            Issue.record("Line 7 was expected to carry a bundle.")

            return
        }

        #expect(bundle.id == Posting.ID(100_085))
        #expect(bundle.subject == "Test subject 18")
        #expect(bundle.sender.emailAddress == "test12@example.com")
        #expect(bundle.appURL == URL(string: "https://app.hey.com/contacts/100074"))
        #expect(
            bundle.bundleAppURL == URL(string: "https://app.hey.com/postings/100085/bundles/unseen")
        )
        #expect(bundle.isSeen == false)

        #expect(decoded[7].kind == .ready)
        try expect(decoded[7], isAt: "2026-09-04T15:07:22.118Z")
    }

    @Test("A deleted, a resync and a change nobody knows each decode without ending the watch")
    func syntheticLinesDecodeAndTheWatchGoesOn() async throws {
        let watch = try await startWatch()
        watch.process.emit(#"{"change":"ready","at":"2026-09-03T20:55:14.906Z"}"#)
        watch.process.emit(
            """
            {"change":"deleted","at":"2026-09-03T20:56:00.100Z",\
            "box":{"id":100001,"kind":"laterbox","name":"Reply Later"},\
            "posting_id":100002,"thread_id":100003,"new":true}
            """
        )
        watch.process.emit(
            """
            {"change":"resync","at":"2026-09-03T20:57:00.200Z",\
            "box":{"id":100001,"kind":"feedbox","name":"The Feed"}}
            """
        )
        watch.process.emit(#"{"change":"something_new","at":"2026-09-03T20:58:00.300Z"}"#)
        watch.process.emit("hey: this is not JSON at all")
        watch.process.emit(#"{"change":"ready","at":"2026-09-03T20:59:00.400Z"}"#)
        watch.process.end(.exited(0))

        var decoded: [WatchLine] = []
        for try await line in watch.lines {
            decoded.append(line)
        }

        #expect(decoded.count == 6)

        guard case let .deleted(deletion) = decoded[1] else {
            Issue.record("The second line was expected to be a deletion.")

            return
        }
        #expect(deletion.box == .laterbox)
        #expect(deletion.postingID == Posting.ID(100_002))
        #expect(deletion.topicID == TopicID(100_003))
        #expect(deletion.isNewMail)
        #expect(deletion.isReplayed == false)
        try expect(decoded[1], isAt: "2026-09-03T20:56:00.100Z")

        guard case let .resync(_, box) = decoded[2] else {
            Issue.record("The third line was expected to be a resync.")

            return
        }
        #expect(box == .feedbox)
        try expect(decoded[2], isAt: "2026-09-03T20:57:00.200Z")

        #expect(
            decoded[3]
                == .unrecognized(rawText: #"{"change":"something_new","at":"2026-09-03T20:58:00.300Z"}"#)
        )
        #expect(decoded[4] == .unrecognized(rawText: "hey: this is not JSON at all"))
        // A line the package could not read never ends the watch, so the ready
        // behind it still arrives.
        #expect(decoded[5].kind == .ready)
    }

    @Test("A deletion before the first ready is a replayed line")
    func aDeletionBeforeTheFirstReadyIsReplayed() async throws {
        let watch = try await startWatch()
        // A watch replays what changed while nobody was watching before it says
        // it is following, so a deletion can arrive before the first ready.
        watch.process.emit(
            """
            {"change":"deleted","at":"2026-09-03T20:56:00.100Z",\
            "box":{"id":100001,"kind":"imbox","name":"Imbox"},\
            "posting_id":100002,"thread_id":100003}
            """
        )
        watch.process.emit(#"{"change":"ready","at":"2026-09-03T20:57:00.200Z"}"#)
        watch.process.end(.exited(0))

        var decoded: [WatchLine] = []
        for try await line in watch.lines {
            decoded.append(line)
        }

        #expect(decoded.count == 2)
        guard case let .deleted(deletion) = decoded[0] else {
            Issue.record("The first line was expected to be a deletion.")

            return
        }
        #expect(deletion.isReplayed)
        // A replayed line is never new mail, and the CLI omits `new` for false.
        #expect(deletion.isNewMail == false)
        #expect(deletion.box == .imbox)
        #expect(deletion.postingID == Posting.ID(100_002))
        try expect(decoded[0], isAt: "2026-09-03T20:56:00.100Z")
        #expect(decoded[1].kind == .ready)
    }

    @Test(
        "A change line whose posting is of a kind the package does not model is a change carrying an other posting",
        arguments: ["added", "updated"]
    )
    func changeLineOfAnUnknownKindIsAChange(change: String) async throws {
        // The captured arrival of a new mail, with its posting's kind swapped for
        // one nobody has declared. The same decode runs inside a line as on a
        // page, so before this an unknown kind made the whole line unrecognised
        // and the app was told nothing about the mail.
        let captured = try FixtureJSON.line(.newMailArrival, ofFixtureNamed: "watch-session.ndjson")
        let derived = try FixtureJSON.replacing(
            "change",
            with: change,
            at: .watchLine,
            in: try FixtureJSON.replacing("kind", with: "parcel", at: .watchLinePosting, in: captured)
        )

        let watch = try await startWatch()
        watch.process.emit(String(decoding: derived, as: UTF8.self))
        watch.process.end(.exited(0))

        var decoded: [WatchLine] = []
        for try await line in watch.lines {
            decoded.append(line)
        }

        #expect(decoded.count == 1)
        let line = try #require(decoded.first)
        #expect(line.kind == (change == "added" ? .added : .updated))
        let changed = try #require(line.change)
        guard case let .other(posting) = changed.posting else {
            Issue.record("The line was expected to carry an other posting.")
            return
        }

        #expect(posting.kind == "parcel")
        #expect(posting.id == Posting.ID(100_002))
        #expect(posting.subject == "Test subject 1")
        #expect(changed.topicID == TopicID(100_003))
    }

    @Test("A change whose posting's shared fields fail arrives as an unrecognised line")
    func aPostingWhoseSharedFieldsFailIsAnUnrecognizedLine() async throws {
        // A line holds one posting, so there is nothing to count a refused one
        // against as a page does, and the line is unrecognised instead. A
        // restarted watch would ask for this same line again with --since, so a
        // line that ended the stream would end every watch after it too.
        let captured = try FixtureJSON.line(.newMailArrival, ofFixtureNamed: "watch-session.ndjson")
        let derived = String(
            decoding: try FixtureJSON.removing("app_url", at: .watchLinePosting, from: captured),
            as: UTF8.self
        )
        let watch = try await startWatch()
        watch.process.emit(#"{"change":"ready","at":"2026-09-03T20:55:14.906Z"}"#)
        watch.process.emit(derived)
        watch.process.emit(#"{"change":"ready","at":"2026-09-03T20:59:00.400Z"}"#)
        watch.process.end(.exited(0))

        var decoded: [WatchLine] = []
        for try await line in watch.lines {
            decoded.append(line)
        }

        #expect(decoded.count == 3)
        #expect(decoded[1] == .unrecognized(rawText: derived))
        #expect(decoded[2].kind == .ready)
    }

    @Test("Cancelling the task that reads the watch terminates the child and throws nothing")
    func cancellingTheReaderTerminatesTheChild() async throws {
        let watch = try await startWatch()
        let (arrived, arrival) = AsyncStream<Void>.makeStream()

        let reader = Task {
            var seen = 0
            for try await _ in watch.lines {
                seen += 1
                arrival.yield()
            }

            return seen
        }

        watch.process.emit(#"{"change":"ready","at":"2026-09-03T20:55:14.906Z"}"#)
        // The reader has to be inside the loop before it is cancelled, or the
        // cancellation would be racing the first line rather than the watch.
        var arrivals = arrived.makeAsyncIterator()
        await arrivals.next()
        reader.cancel()

        #expect(try await reader.value == 1)
        #expect(watch.process.terminateCallCount == 1)
    }

    @Test("A watch nobody reads terminates its child once its stream is dropped")
    func droppingTheStreamTerminatesTheChild() async throws {
        let (client, script) = makeScriptedClient(outputs: [])
        var lines: AsyncThrowingStream<WatchLine, any Error>? = try await client.watch(
            NonEmptySet(.imbox),
            since: nil
        )
        let watched = try #require(script.startedProcesses.first)

        #expect(lines != nil)
        #expect(watched.terminateCallCount == 0)
        // Nothing here reads a line: releasing the stream is what cancels it, and
        // the cancellation is what asks the child to stop.
        lines = nil

        // The handler runs on whoever released the stream rather than on this
        // task, so the count is polled instead of read once.
        for _ in 0 ..< 200 where watched.terminateCallCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(watched.terminateCallCount == 1)
    }

    @Test("A watch whose child exits cleanly ends its stream normally")
    func aCleanExitEndsTheStreamNormally() async throws {
        let watch = try await startWatch()
        watch.process.emit(#"{"change":"ready","at":"2026-09-03T20:55:14.906Z"}"#)
        watch.process.emit(#"{"change":"disconnected","at":"2026-09-03T20:57:11.599Z"}"#)
        watch.process.end(.exited(0))

        // The caller decides whether to start another watch, so an exit nobody
        // asked for is the end of a stream and not a failure.
        var decoded: [WatchLine] = []
        for try await line in watch.lines {
            decoded.append(line)
        }

        #expect(decoded.count == 2)
    }

    @Test("A reader that falls behind the watch buffer gets the lines that fit, then a failure, and the child is terminated")
    func aReaderThatFallsBehindEndsTheWatch() async throws {
        let (client, script) = makeScriptedClient(
            outputs: [],
            limits: .standard.with(watchBufferInLines: 3)
        )
        let lines = try await client.watch(NonEmptySet(.imbox))
        let watched = try #require(script.startedProcesses.first)

        let times = (0 ..< 5).map { "2026-09-03T20:55:1\($0).000Z" }
        for time in times {
            watched.emit(#"{"change":"ready","at":"\#(time)"}"#)
        }

        // Nothing reads the watch while the lines are emitted, so the fourth one is
        // the first that does not fit. The pump runs on a task of its own, so the
        // terminate it sends is polled for rather than read once.
        for _ in 0 ..< 200 where watched.terminateCallCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(watched.terminateCallCount == 1)

        var decoded: [WatchLine] = []
        do {
            for try await line in lines {
                decoded.append(line)
            }
            Issue.record("The watch was expected to end with its reader fallen behind.")
        } catch let error as HEYCliKitError {
            #expect(error == .watchFellBehind(limitInLines: 3))
        }

        // The lines the app does get are the first ones the CLI printed, in order,
        // and nothing stands in for the ones that were dropped.
        #expect(decoded.count == 3)
        for (index, line) in decoded.enumerated() {
            try expect(line, isAt: times[index])
        }
    }

    @Test("A watch whose child wrote more stderr than the output ceiling throws that, not the signal")
    func aWatchWithTooMuchStandardErrorThrowsOutputTooLarge() async throws {
        let watch = try await startWatch()
        watch.process.emit(#"{"change":"ready","at":"2026-09-03T20:55:14.906Z"}"#)
        watch.process.endWithStandardErrorTooLarge()

        var decoded: [WatchLine] = []
        do {
            for try await line in watch.lines {
                decoded.append(line)
            }
            Issue.record("The watch was expected to end with its output too large.")
        } catch let error as HEYCliKitError {
            #expect(error == .outputTooLarge(limitInBytes: RunnerLimits.standard.outputCeilingInBytes))
        }

        #expect(decoded.count == 1)
    }

    @Test("A failure the runner ends the lines with ends the watch with that same failure")
    func aRunnerFailureEndsTheWatch() async throws {
        let watch = try await startWatch()
        watch.process.emit(#"{"change":"ready","at":"2026-09-03T20:55:14.906Z"}"#)
        watch.process.failLines(with: HEYCliKitError.lineTooLarge(limitInBytes: 65_536))

        var decoded: [WatchLine] = []
        do {
            for try await line in watch.lines {
                decoded.append(line)
            }
            Issue.record("The watch was expected to end with a line too large.")
        } catch let error as HEYCliKitError {
            #expect(error == .lineTooLarge(limitInBytes: 65_536))
        }

        #expect(decoded.count == 1)
    }

    @Test("A watch that ends signed out throws the CLI's own signed out error")
    func aSignedOutWatchThrowsSignedOut() async throws {
        let watch = try await startWatch()
        // The CLI's parting words are its error envelope, which it prints over
        // several lines, so the watch reads every line it could not recognise at
        // the end as the envelope it is.
        for line in String(decoding: try HEYFixtures.data(named: "error-auth.json"), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        {
            watch.process.emit(String(line))
        }
        watch.process.end(.exited(3))

        var decoded: [WatchLine] = []
        do {
            for try await line in watch.lines {
                decoded.append(line)
            }
            Issue.record("The watch was expected to end signed out.")
        } catch let HEYCliKitError.signedOut(details) {
            #expect(details.code == "auth")
            #expect(details.hint == "Run: hey auth login")
        }

        #expect(decoded.allSatisfy { $0.kind == .unrecognized })
        #expect(decoded.isEmpty == false)
    }

    @Test("A watch that ends signed out with its envelope on stderr throws the CLI's own details")
    func aSignedOutWatchReadsTheEnvelopeOnStandardError() async throws {
        let watch = try await startWatch()
        let envelope = String(decoding: try HEYFixtures.data(named: "error-auth.json"), as: UTF8.self)
        watch.process.end(.exited(3), standardError: envelope)

        do {
            for try await _ in watch.lines {}
            Issue.record("The watch was expected to end signed out.")
        } catch let HEYCliKitError.signedOut(details) {
            #expect(details.code == "auth")
            #expect(details.message == "Not logged in")
            #expect(details.hint == "Run: hey auth login")
        }
    }
}
