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

    @Test("A single posting decodes without entry_kind, seen or alternative_sender_name")
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

    /// Reads the captured Imbox with one key removed from one place in it.
    ///
    /// The envelope is derived here rather than committed beside the captures,
    /// because the fixtures folder ships to every app.
    private func imboxPage(without key: String, at place: [JSONPathStep]) async throws -> BoxPage {
        let envelope = try FixtureJSON.removing(
            key,
            at: place,
            from: try HEYFixtures.data(named: "imbox.json")
        )
        let (client, _) = makeScriptedClient(outputs: [scriptedOutput(envelope)])

        return try await client.boxPage(.imbox)
    }

    /// A key the CLI leaves out of a single posting when its value is empty.
    ///
    /// The raw value is the key the derived envelope drops, so the test name
    /// says which one this case is about.
    enum SinglePostingZeroValueKey: String, CaseIterable, CustomTestStringConvertible {
        case name
        case contacts
        case addressedContacts = "addressed_contacts"
        case visibleEntryCount = "visible_entry_count"

        var testDescription: String { rawValue }

        /// What the field reads as once the CLI has left the key out.
        var expectedValue: AnyHashable {
            switch self {
            case .name: AnyHashable("")
            case .contacts, .addressedContacts: AnyHashable([Contact]())
            case .visibleEntryCount: AnyHashable(0)
            }
        }

        func decodedValue(_ posting: Posting.Single) -> AnyHashable {
            switch self {
            case .name: AnyHashable(posting.subject)
            case .contacts: AnyHashable(posting.contacts)
            case .addressedContacts: AnyHashable(posting.addressedContacts)
            case .visibleEntryCount: AnyHashable(posting.visibleEntryCount)
            }
        }
    }

    @Test(
        "A single posting decodes an absent key as the CLI's zero value",
        arguments: SinglePostingZeroValueKey.allCases
    )
    func singlePostingDecodesAnAbsentKeyAsAZeroValue(key: SinglePostingZeroValueKey) async throws {
        let page = try await imboxPage(without: key.rawValue, at: .firstSinglePosting)

        let posting = try #require(page.postings.first?.single)
        #expect(key.decodedValue(posting) == key.expectedValue)
        // A sibling the derived envelope left alone, so the test says the row
        // itself decoded and not merely the page around it.
        #expect(posting.id == Posting.ID(100_007))
    }

    /// A key the CLI leaves out of a single posting where a zero would be a lie.
    ///
    /// A topic id of zero is a broken link and a box id of zero names no box, so
    /// the field is optional and an absent key is no value at all.
    enum SinglePostingOptionalKey: String, CaseIterable, CustomTestStringConvertible {
        case topicID = "topic_id"
        case boxID = "box_id"

        var testDescription: String { rawValue }

        /// What the field reads as once the CLI has left the key out.
        var expectedValue: AnyHashable {
            switch self {
            case .topicID: AnyHashable(TopicID?.none)
            case .boxID: AnyHashable(BoxID?.none)
            }
        }

        func decodedValue(_ posting: Posting.Single) -> AnyHashable {
            switch self {
            case .topicID: AnyHashable(posting.topicID)
            case .boxID: AnyHashable(posting.boxID)
            }
        }
    }

    @Test(
        "A single posting decodes an absent key as no value",
        arguments: SinglePostingOptionalKey.allCases
    )
    func singlePostingDecodesAnAbsentKeyAsNoValue(key: SinglePostingOptionalKey) async throws {
        let page = try await imboxPage(without: key.rawValue, at: .firstSinglePosting)

        let posting = try #require(page.postings.first?.single)
        #expect(key.decodedValue(posting) == key.expectedValue)
        #expect(posting.id == Posting.ID(100_007))
    }

    /// A key the CLI leaves out of a bundle when its value is empty.
    enum BundleAbsentKey: String, CaseIterable, CustomTestStringConvertible {
        case name
        case boxID = "box_id"
        case bundleAppURL = "app_bundle_url"

        var testDescription: String { rawValue }

        /// What the field reads as once the CLI has left the key out: the zero
        /// value where the type has an honest one, and nothing where it has not.
        var expectedValue: AnyHashable {
            switch self {
            case .name: AnyHashable("")
            case .boxID: AnyHashable(BoxID?.none)
            case .bundleAppURL: AnyHashable(URL?.none)
            }
        }

        func decodedValue(_ bundle: Posting.Bundle) -> AnyHashable {
            switch self {
            case .name: AnyHashable(bundle.subject)
            case .boxID: AnyHashable(bundle.boxID)
            case .bundleAppURL: AnyHashable(bundle.bundleAppURL)
            }
        }
    }

    @Test(
        "A bundle decodes an absent key as the CLI's zero value or no value",
        arguments: BundleAbsentKey.allCases
    )
    func bundleDecodesAnAbsentKey(key: BundleAbsentKey) async throws {
        let page = try await imboxPage(without: key.rawValue, at: .firstBundle)

        let bundle = try #require(page.postings.compactMap(\.bundle).first)
        #expect(key.decodedValue(bundle) == key.expectedValue)
        #expect(bundle.id == Posting.ID(100_033))
    }

    /// A key the CLI leaves out of a contact when its value is empty.
    enum ContactZeroValueKey: String, CaseIterable, CustomTestStringConvertible {
        case name
        case emailAddress = "email_address"
        case initials
        case avatarBackgroundColor = "avatar_background_color"

        var testDescription: String { rawValue }

        /// Every one of them is text, so an absent key is an empty string.
        var expectedValue: AnyHashable { AnyHashable("") }

        func decodedValue(_ contact: Contact) -> AnyHashable {
            switch self {
            case .name: AnyHashable(contact.name)
            case .emailAddress: AnyHashable(contact.emailAddress)
            case .initials: AnyHashable(contact.initials)
            case .avatarBackgroundColor: AnyHashable(contact.avatarBackgroundColor)
            }
        }
    }

    @Test(
        "A contact decodes an absent key as the CLI's zero value",
        arguments: ContactZeroValueKey.allCases
    )
    func contactDecodesAnAbsentKeyAsAZeroValue(key: ContactZeroValueKey) async throws {
        let page = try await imboxPage(without: key.rawValue, at: .firstSinglePostingCreator)

        let posting = try #require(page.postings.first?.single)
        #expect(key.decodedValue(posting.sender) == key.expectedValue)
        #expect(posting.sender.id == Contact.ID(100_006))
    }

    /// Reads a box page from an envelope a test derived from a capture.
    private func decodedPage(from envelope: Data) async throws -> BoxPage {
        let (client, _) = makeScriptedClient(outputs: [scriptedOutput(envelope)])

        return try await client.boxPage(.imbox)
    }

    @Test(
        "The captured pages refuse no rows",
        arguments: ["imbox.json", "imbox-page-1.json", "imbox-page-2.json"]
    )
    func capturedPagesRefuseNoRows(fixture: String) async throws {
        let page = try await boxPage(fixture: fixture)

        #expect(page.refusedRowCount == 0)
    }

    @Test(
        "A posting of a kind the package does not model is an other posting carrying the shared fields",
        arguments: ["entry", "parcel"]
    )
    func unknownPostingKindIsAnOtherPosting(kind: String) async throws {
        // `entry` is declared by hey-sdk's schema and never modelled here, and
        // `parcel` stands for a kind nobody has declared at all. Both read the
        // same way, which is what a kind the package has never seen has to do.
        let captured = try HEYFixtures.data(named: "imbox.json")
        let untouched = try #require(try await decodedPage(from: captured).postings.first?.single)
        let envelope = try FixtureJSON.replacing(
            "kind",
            with: kind,
            at: .firstSinglePosting,
            in: captured
        )

        let page = try await decodedPage(from: envelope)

        let other = try #require(page.postings.first?.other)
        #expect(other.kind == kind)
        #expect(other.id == untouched.id)
        #expect(other.subject == untouched.subject)
        #expect(other.activeAt == untouched.activeAt)
        #expect(other.observedAt == untouched.observedAt)
        #expect(other.appURL == untouched.appURL)
        #expect(other.boxID == untouched.boxID)
        #expect(other.sender == untouched.sender)
        #expect(other.isSeen == untouched.isSeen)
        // The forwarding properties read an other posting as they read the
        // other two, so a list that shows a subject and a sender draws it.
        #expect(page.postings.first?.subject == untouched.subject)
        #expect(page.postings.first?.sender == untouched.sender)
        #expect(page.postings.count == 50)
        #expect(page.refusedRowCount == 0)
    }

    @Test("A posting without a kind is an other posting with an empty kind")
    func postingWithoutAKindIsAnOtherPosting() async throws {
        let page = try await imboxPage(without: "kind", at: .firstSinglePosting)

        let other = try #require(page.postings.first?.other)
        #expect(other.kind == "")
        #expect(other.id == Posting.ID(100_007))
        #expect(page.refusedRowCount == 0)
    }

    /// Checks that the Imbox's first row alone was refused: the row after it is
    /// now the first, so nothing but the refused row went missing and nothing
    /// moved out of order.
    private func expectOnlyTheFirstRowRefused(
        _ page: BoxPage,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(page.postings.count == 49, sourceLocation: sourceLocation)
        #expect(page.refusedRowCount == 1, sourceLocation: sourceLocation)
        #expect(page.postings.first?.id == Posting.ID(100_010), sourceLocation: sourceLocation)
    }

    /// The keys that stay required even though the CLI can drop them, because a
    /// row the app cannot open, that HEY never observed, that has no identity or
    /// that is from nobody, is not a row. Such a row is dropped and counted, and
    /// the page around it still decodes.
    @Test(
        "A posting without a required key is refused and counted, and the page still decodes",
        arguments: ["id", "app_url", "active_at", "observed_at", "creator"]
    )
    func postingWithoutARequiredKeyIsRefusedAndCounted(key: String) async throws {
        let page = try await imboxPage(without: key, at: .firstSinglePosting)

        expectOnlyTheFirstRowRefused(page)
    }

    /// An id written as text and a kind written as a number: each key is there,
    /// but not as the type the CLI writes it.
    @Test(
        "A posting whose key has the wrong type is refused and counted",
        arguments: [("id", "100007"), ("kind", 7)] as [(String, any Sendable)]
    )
    func postingWithAWronglyTypedKeyIsRefusedAndCounted(
        key: String,
        value: any Sendable
    ) async throws {
        let envelope = try FixtureJSON.replacing(
            key,
            with: value,
            at: .firstSinglePosting,
            in: try HEYFixtures.data(named: "imbox.json")
        )

        let page = try await decodedPage(from: envelope)

        expectOnlyTheFirstRowRefused(page)
    }

    @Test("A refused bundle in the middle of a page leaves its neighbours in order")
    func refusedMiddleRowKeepsItsNeighbors() async throws {
        let page = try await imboxPage(without: "app_url", at: .firstBundle)

        #expect(page.postings.count == 49)
        #expect(page.refusedRowCount == 1)
        #expect(page.postings[8].id == Posting.ID(100_031))
        #expect(page.postings[9].id == Posting.ID(100_035))
    }

    @Test("A refused last row leaves the rows before it in place")
    func refusedLastRowKeepsTheRowsBeforeIt() async throws {
        let page = try await imboxPage(without: "app_url", at: .lastImboxPosting)

        #expect(page.postings.count == 49)
        #expect(page.refusedRowCount == 1)
        #expect(page.postings.first?.id == Posting.ID(100_007))
        #expect(page.postings.last?.id == Posting.ID(100_127))
    }

    @Test("Two refused rows on one page are both counted")
    func twoRefusedRowsAreBothCounted() async throws {
        let envelope = try FixtureJSON.removing(
            "app_url",
            at: .firstBundle,
            from: try FixtureJSON.removing(
                "id",
                at: .firstSinglePosting,
                from: try HEYFixtures.data(named: "imbox.json")
            )
        )

        let page = try await decodedPage(from: envelope)

        #expect(page.postings.count == 48)
        #expect(page.refusedRowCount == 2)
        #expect(page.postings.first?.id == Posting.ID(100_010))
    }

    @Test(
        "A row that is not an object is refused and counted",
        arguments: ["7", #""a row""#, "[]", "null"]
    )
    func rowThatIsNotAnObjectIsRefusedAndCounted(row: String) async throws {
        let envelope = try FixtureJSON.replacingElement(
            0,
            withJSON: row,
            at: .boxPagePostings,
            in: try HEYFixtures.data(named: "imbox.json")
        )

        let page = try await decodedPage(from: envelope)

        expectOnlyTheFirstRowRefused(page)
    }

    @Test("A page without postings is a decoding failure")
    func pageWithoutPostingsFails() async throws {
        do {
            _ = try await imboxPage(without: "postings", at: .boxPageData)
            Issue.record("The read was expected to fail but returned a page.")
        } catch let HEYCliKitError.decodingFailure(failure) {
            #expect(failure.description.contains("postings"))
        }
    }

    @Test("A page whose postings are not a list is a decoding failure")
    func pageWhosePostingsAreNotAListFails() async throws {
        let envelope = try FixtureJSON.replacing(
            "postings",
            with: "not a list",
            at: .boxPageData,
            in: try HEYFixtures.data(named: "imbox.json")
        )

        do {
            _ = try await decodedPage(from: envelope)
            Issue.record("The read was expected to fail but returned a page.")
        } catch let HEYCliKitError.decodingFailure(failure) {
            #expect(failure.description.contains("postings"))
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

    /// One single posting without the three keys that were already optional.
    ///
    /// It is written by hand rather than trimmed from a capture, so `entry_kind`,
    /// `seen` and `alternative_sender_name` are the keys it leaves out on
    /// purpose. They are not the only ones the CLI can drop: the derived tests
    /// above remove each of the others in turn and say what an absent one reads
    /// as.
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

    /// The single posting this is, so a test can require one in a line.
    fileprivate var single: Single? {
        guard case let .single(posting) = self else { return nil }

        return posting
    }

    /// The bundle this is, so a test can require one in a line.
    fileprivate var bundle: Bundle? {
        guard case let .bundle(bundle) = self else { return nil }

        return bundle
    }

    /// The other posting this is, so a test can require one in a line.
    fileprivate var other: Other? {
        guard case let .other(other) = self else { return nil }

        return other
    }
}
