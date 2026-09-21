/// The postings one box read returned, with the cursor that reads the next page.
///
/// HEY prints a cursor only when the page sits on a paging boundary and more
/// postings follow, so no cursor means there is nothing more to read at that size.
public struct BoxPage: Sendable, Hashable {
    /// The postings the read returned, in the order HEY printed them.
    public let postings: [Posting]
    /// The cursor to read the next page with, when more postings follow.
    public let nextCursor: Cursor?

    init(postings: [Posting], nextCursor: Cursor?) {
        self.postings = postings
        self.nextCursor = nextCursor
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
        page = BoxPage(
            postings: try container.decode([Posting].self, forKey: .postings),
            nextCursor: nextPage.flatMap { $0.isEmpty ? nil : Cursor(rawValue: $0) }
        )
    }
}
