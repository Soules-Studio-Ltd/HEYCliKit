import Foundation
import Testing

@testable import HEYCliKit
import HEYCliKitTestSupport

/// Every expectation here is written from the fixture by hand, so a decoder that
/// quietly changes what it reads has to disagree with the bytes on disk.
@Suite("Box page")
struct BoxPageTests {
    /// Reads one box page from a scripted answer, so nothing spawns the CLI.
    private func boxPage(
        fixture: String,
        kind: BoxKind = .imbox,
        pageSize: PageSize = .minimum,
        cursor: Cursor? = nil
    ) async throws -> BoxPage {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: fixture))]
        )

        return try await client.boxPage(kind, pageSize: pageSize, cursor: cursor)
    }

    @Test("The captured Imbox decodes into single postings and bundles")
    func imboxDecodes() async throws {
        let pageSize = try #require(PageSize(50))

        let page = try await boxPage(fixture: "imbox.json", pageSize: pageSize)

        #expect(page.postings.count == 50)
        #expect(page.postings.filter(\.isSingle).count == 46)
        #expect(page.postings.filter(\.isBundle).count == 4)
        #expect(page.postings.filter { $0.isSeen == false }.map(\.id.rawValue) == [
            100_007, 100_010, 100_012, 100_016,
        ])
        #expect(page.postings.filter(\.isBundle).map(\.id.rawValue) == [
            100_033, 100_035, 100_047, 100_056,
        ])
    }

    @Test("A single posting carries its subject, its sender and its topic")
    func firstSinglePostingDecodes() async throws {
        let page = try await boxPage(fixture: "imbox.json")

        guard case let .single(posting) = try #require(page.postings.first) else {
            Issue.record("The first posting was expected to be a single posting.")
            return
        }

        #expect(posting.id == Posting.ID(100_007))
        #expect(posting.subject == "Test subject 1")
        #expect(posting.isSeen == false)
        #expect(posting.sender.name == "Test contact 2")
        #expect(posting.sender.id == Contact.ID(100_006))
        #expect(posting.sender.emailAddress == "test2@example.com")
        #expect(posting.sender.initials == "TC")
        #expect(posting.sender.avatarBackgroundColor == "#CFF523")
        #expect(posting.sender.avatarURL == URL(string: "https://example.com/avatar.png"))
        #expect(posting.topicID == TopicID(100_005))
        #expect(posting.entryKind == "message")
        #expect(posting.summary == "Test summary 1")
        #expect(posting.visibleEntryCount == 1)
        #expect(posting.alternativeSenderName == "Test sender")
        #expect(posting.contacts.map(\.name) == ["Test contact 1", "Test contact 2"])
        #expect(posting.addressedContacts.map(\.name) == ["Test contact 1"])
        #expect(posting.appURL == URL(string: "https://app.hey.com/topics/100005"))
        #expect(posting.boxID == BoxID(100_001))
        // The CLI prints six fractional digits on observed_at and none on active_at,
        // so both forms have to decode. The fraction free one is compared exactly,
        // and the fractional one to the microsecond the CLI printed.
        expect(posting.observedAt, isWithinAMicrosecondOf: 1_788_471_615.793452)
        #expect(posting.activeAt == Date(timeIntervalSince1970: 1_788_471_614))
    }

    @Test("A bundle carries the URL that opens the bundle itself")
    func firstBundleDecodes() async throws {
        let page = try await boxPage(fixture: "imbox.json")

        let bundles = page.postings.compactMap { posting -> Posting.Bundle? in
            guard case let .bundle(bundle) = posting else { return nil }

            return bundle
        }
        let bundle = try #require(bundles.first)

        #expect(bundle.id == Posting.ID(100_033))
        #expect(bundle.subject == "Test subject 10")
        #expect(bundle.isSeen)
        #expect(bundle.bundleAppURL == URL(string: "https://app.hey.com/contacts/100032"))
        #expect(bundle.appURL == URL(string: "https://app.hey.com/contacts/100032"))
        #expect(bundle.boxID == BoxID(100_001))
        expect(bundle.observedAt, isWithinAMicrosecondOf: 1_788_349_315.364658)
    }

    @Test("A page on a boundary carries the cursor that reads the next one")
    func imboxCarriesACursor() async throws {
        let pageSize = try #require(PageSize(50))
        let (client, script) = makeScriptedClient(
            outputs: [scriptedOutput(try HEYFixtures.data(named: "imbox.json"))]
        )

        let page = try await client.boxPage(.imbox, pageSize: pageSize)

        // The cursor was captured at a page size of 50, so the size the read asked
        // for is asserted alongside it: a page read at another size is another page.
        #expect(script.recordedSpawns.first?.arguments.argument(after: "--limit") == "50")
        #expect(
            page.nextCursor?.rawValue
                == """
                eyJwYWdlX251bWJlciI6NCwidmFsdWVzIjp7InNlZW4iOiJzZWVuIiwib2JzZXJ2ZWRfYXQiOiIyMDI2LTAxL\
                TAxVDAwOjAwOjAwLjAwMDAwMFoiLCJpZCI6MTAwMTMwfX0
                """
        )
    }

    @Test("The first captured page carries the cursor the second page was read with")
    func firstPageCarriesTheCursorOfTheSecond() async throws {
        let page = try await boxPage(fixture: "imbox-page-1.json")

        #expect(page.postings.count == 30)
        #expect(page.postings.filter { $0.isSeen == false }.map(\.id.rawValue) == [100_008])
        #expect(
            page.nextCursor?.rawValue
                == """
                eyJwYWdlX251bWJlciI6MiwidmFsdWVzIjp7InNlZW4iOiJzZWVuIiwib2JzZXJ2ZWRfYXQiOiIyMDI2LTAxL\
                TAxVDAwOjAwOjAwLjAwMDAwMFoiLCJpZCI6MTAwMDc4fX0
                """
        )
    }

    @Test("The cursor of one page reads the page that follows it")
    func secondPageReadsWithTheFirstPagesCursor() async throws {
        let (client, script) = makeScriptedClient(
            outputs: [
                scriptedOutput(try HEYFixtures.data(named: "imbox-page-1.json")),
                scriptedOutput(try HEYFixtures.data(named: "imbox-page-2.json")),
            ]
        )

        let first = try await client.boxPage(.imbox)
        let cursor = try #require(first.nextCursor)
        let second = try await client.boxPage(.imbox, cursor: cursor)

        #expect(second.postings.count == 30)
        #expect(second.postings.filter { $0.isSeen == false }.isEmpty)
        #expect(second.nextCursor != nil)
        #expect(second.nextCursor != first.nextCursor)
        #expect(script.recordedSpawns.first?.arguments.contains("--page") == false)
        #expect(script.recordedSpawns.last?.arguments.argument(after: "--page") == cursor.rawValue)
    }

    @Test("A page with no next page carries no cursor")
    func lastPageCarriesNoCursor() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(#"{"ok":true,"data":{"postings":[]}}"#)]
        )

        let page = try await client.boxPage(.imbox)

        #expect(page.postings.isEmpty)
        #expect(page.nextCursor == nil)
    }

    @Test("An empty next_page carries no cursor")
    func emptyNextPageCarriesNoCursor() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(#"{"ok":true,"data":{"postings":[],"next_page":""}}"#)]
        )

        let page = try await client.boxPage(.imbox)

        #expect(page.nextCursor == nil)
    }

    @Test("A single posting decodes without the keys the CLI does not always print")
    func singlePostingWithoutOptionalKeysDecodes() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [scriptedOutput(Self.singlePostingWithoutOptionalKeys)]
        )

        let page = try await client.boxPage(.imbox)

        guard case let .single(posting) = try #require(page.postings.first) else {
            Issue.record("The posting was expected to be a single posting.")
            return
        }

        #expect(posting.entryKind == nil)
        #expect(posting.alternativeSenderName == nil)
        #expect(posting.isSeen == false)
    }

    @Test("A posting kind the package does not know is a decoding failure naming it")
    func unknownPostingKindFails() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [
                scriptedOutput(
                    """
                    {"ok":true,"data":{"postings":[{"kind":"parcel","id":1,"name":"Test subject 1"}]}}
                    """
                )
            ]
        )

        do {
            _ = try await client.boxPage(.imbox)
            Issue.record("The operation was expected to fail but returned a value.")
        } catch let HEYCliKitError.decodingFailure(failure) {
            #expect(failure.description.contains("parcel"))
        }
    }

    @Test("An error envelope on a box read maps the way every other operation maps")
    func errorEnvelopeMaps() async throws {
        let (client, _) = makeScriptedClient(
            outputs: [
                scriptedOutput(try HEYFixtures.data(named: "error-not-found-box.json"), exitCode: 2)
            ]
        )

        do {
            _ = try await client.boxPage(.feedbox)
            Issue.record("The operation was expected to fail but returned a value.")
        } catch let HEYCliKitError.notFound(details) {
            #expect(details.code == "not_found")
            #expect(details.message == "box \"feed\" not found")
        }
    }

    /// One single posting carrying only the keys the CLI always prints.
    ///
    /// It is written by hand rather than trimmed from a capture, so the keys it
    /// leaves out are exactly the optional ones: `entry_kind`, `seen` and
    /// `alternative_sender_name`.
    private static let singlePostingWithoutOptionalKeys = """
        {
          "ok": true,
          "data": {
            "postings": [
              {
                "kind": "topic",
                "id": 100007,
                "name": "Test subject 1",
                "active_at": "2026-09-03T21:40:14Z",
                "observed_at": "2026-09-03T21:40:15Z",
                "app_url": "https://app.hey.com/topics/100005",
                "box_id": 100001,
                "creator": {
                  "id": 100006,
                  "name": "Test contact 2",
                  "email_address": "test2@example.com",
                  "initials": "TC",
                  "avatar_url": "https://example.com/avatar.png",
                  "avatar_background_color": "#CFF523"
                },
                "topic_id": 100005,
                "summary": "Test summary 1",
                "contacts": [],
                "addressed_contacts": [],
                "visible_entry_count": 1
              }
            ]
          }
        }
        """
}

/// Compares a captured timestamp to the microsecond the CLI printed.
///
/// The CLI prints six fractional digits on `observed_at`, and the nearest double to
/// those digits is not always the nearest double to the literal a test writes, so
/// an exact comparison would fail on a value that decoded correctly.
private func expect(
    _ date: Date,
    isWithinAMicrosecondOf seconds: TimeInterval,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(date.timeIntervalSince1970 - seconds) < 0.000_001,
        sourceLocation: sourceLocation
    )
}

extension Posting {
    /// True when this posting stands for exactly one topic.
    fileprivate var isSingle: Bool {
        if case .single = self { return true }

        return false
    }

    /// True when this posting groups several topics from one contact.
    fileprivate var isBundle: Bool {
        if case .bundle = self { return true }

        return false
    }
}
