/// The postings one box read returned, with the cursor that reads the next page.
///
/// HEY prints a cursor only when the page sits on a paging boundary and more
/// postings follow, so no cursor means there is nothing more to read at that size.
public struct BoxPage: Sendable, Hashable {
    /// The postings the read returned, in the order HEY printed them.
    public let postings: [Posting]
    /// The cursor to read the next page with, when more postings follow.
    public let nextCursor: Cursor?
    /// How many rows the CLI printed on this page that the package could not
    /// read, and dropped rather than failing the page.
    ///
    /// Any decoding failure inside a row refuses it: a row with no `id`, no
    /// `app_url`, no `active_at` or `observed_at`, no `creator`, an id that is
    /// not an integer, or a row that is not an object at all. `postings.count +
    /// refusedRowCount` is how many rows the CLI printed, so an app comparing
    /// the decoded count against the page size it asked for sees one fewer per
    /// refused row. The cursor is unaffected, since it is opaque and HEY
    /// computed it from the page it served.
    public let refusedRowCount: Int

    init(postings: [Posting], nextCursor: Cursor?, refusedRowCount: Int) {
        self.postings = postings
        self.nextCursor = nextCursor
        self.refusedRowCount = refusedRowCount
    }
}

/// The payload of `hey box view`, as the CLI prints it inside `data`.
///
/// It is `package` so the fixture client in the test support product decodes a
/// scripted page through the same type the live client decodes.
package struct BoxPagePayload: Decodable {
    /// The page this payload stands for.
    package let page: BoxPage

    private enum CodingKeys: String, CodingKey {
        case postings
        case nextPage = "next_page"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The CLI prints plenty besides the postings and the cursor: the box's own
        // id, name and URLs, and the stream addresses a watch uses. None of it is
        // read here, so a page decodes whatever else it carries.
        // An empty `next_page` is not a cursor. Passing it back would spawn a read
        // with an empty `--page`, so an empty value reads the same as no key at all.
        let nextPage = try container.decodeIfPresent(String.self, forKey: .nextPage)
        // The list itself is still required: a page with no postings, or with
        // something other than a list under the key, is not a page at all. Only
        // the rows inside it are read one at a time.
        var rows = try container.nestedUnkeyedContainer(forKey: .postings)
        var postings: [Posting] = []
        var refusedRowCount = 0
        while !rows.isAtEnd {
            // A null row is refused here rather than left to the wrapper, so
            // counting it never depends on how the decoder treats null.
            if try rows.decodeNil() {
                refusedRowCount += 1
            } else if let posting = try rows.decode(RefusableRow.self).posting {
                postings.append(posting)
            } else {
                refusedRowCount += 1
            }
        }
        page = BoxPage(
            postings: postings,
            nextCursor: nextPage.flatMap { $0.isEmpty ? nil : Cursor(rawValue: $0) },
            refusedRowCount: refusedRowCount
        )
    }

    /// One row of a page, which decodes whatever the row holds.
    ///
    /// Its own decoding never throws, so the list it is read from always moves on
    /// to the next row, and a row whose posting fails is nil rather than the
    /// failure of the page around it.
    private struct RefusableRow: Decodable {
        let posting: Posting?

        init(from decoder: any Decoder) throws {
            posting = try? Posting(from: decoder)
        }
    }
}
