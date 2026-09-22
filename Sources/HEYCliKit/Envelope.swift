import Foundation

/// The JSON object every `hey <command> --json` prints.
///
/// The envelope carries `ok`, then either `data` or an `error` with a `code` and
/// an optional `hint`. The CLI also prints `summary`, `notice`, `breadcrumbs` and
/// `meta`. Those are never parsed: they are human wording that can change without
/// notice, and they are only ever carried as opaque text inside the raw stdout of
/// a decoding failure. They are deliberately absent from the coding keys, so the
/// envelope decodes whether they are missing, strings, numbers, objects or arrays.
///
/// The one exception is `meta.total_count`, which the Screener list needs and
/// nothing else reads. It is read leniently: a `meta` that is missing, or that is
/// a number, a string or an array, or an object without a `total_count`, leaves it
/// nil rather than failing an envelope that is otherwise fine.
struct Envelope<Payload: Decodable>: Decodable {
    let ok: Bool
    let data: Payload?
    let error: String?
    let code: String?
    let hint: String?
    let totalCount: Int?

    private enum CodingKeys: String, CodingKey {
        case ok
        case data
        case error
        case code
        case hint
        case meta
    }

    private enum MetaCodingKeys: String, CodingKey {
        case totalCount = "total_count"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        totalCount = try? container
            .nestedContainer(keyedBy: MetaCodingKeys.self, forKey: .meta)
            .decodeIfPresent(Int.self, forKey: .totalCount)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        // A failed envelope never carries data, so its payload shape is not the
        // package's business: decoding it would turn an error into a decoding
        // failure and lose the CLI's own code, message and hint.
        data = ok ? try container.decodeIfPresent(Payload.self, forKey: .data) : nil
    }
}

/// The decoder every envelope goes through.
///
/// It is the single decoder behind the envelope mapping and the watch line
/// decoder, so its one date strategy reads every date the package reads: a page's
/// `observed_at` and `active_at`, every watch line's `at`, and a sign in status's
/// `expires_at`.
///
/// The CLI is written in Go, which prints a date as RFC 3339 with from none to
/// nine fraction digits, trailing zeros trimmed, so the same field can carry six
/// digits on one row and four on the next. Most dates end in `Z`, but `expires_at`
/// carries the machine's local offset, such as `+02:00`. The ISO 8601 strategy
/// cannot be trusted with that: the Foundation before 6.2, which macOS 15 ships,
/// refuses any fraction under `.iso8601`, and on that Foundation the fractional
/// option of `ISO8601DateFormatter` is a three digit pattern. So the strategy here
/// takes the fraction out itself, parses the date without its fraction with the
/// ISO 8601 style both Foundations read, and adds the fraction back.
func makeEnvelopeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(decodeCLIDate)

    return decoder
}

/// The whole second RFC 3339 style every date is parsed with once its fraction is
/// taken out. It reads both `Z` and an offset such as `+02:00`, and one instance
/// serves every decode rather than one being built per date.
private let wholeSecondDateStyle = Date.ISO8601FormatStyle()

/// Reads one date the CLI printed, or refuses it in the package's own words.
///
/// The refusal never quotes the text and never carries Foundation's own error,
/// since Foundation's wording quotes the input. It is a ``SchemaRefusal``, whose
/// message is the one underlying error a decoding failure's description quotes.
private func decodeCLIDate(_ decoder: any Decoder) throws -> Date {
    let text = try decoder.singleValueContainer().decode(String.self)

    guard let date = parseCLIDate(text) else {
        throw SchemaRefusal(
            message: "Expected an RFC 3339 date, with or without a fraction of a second."
        ).decodingError(at: decoder.codingPath)
    }

    return date
}

/// Parses an RFC 3339 date with any number of fraction digits, or returns nil.
///
/// The fraction is the run of ASCII digits after the first `.`, and what follows
/// the run, `Z` or an offset, stays on the text that is parsed. A `.` with no digit
/// after it is not a fraction, so that date is refused rather than read as whole.
private func parseCLIDate(_ text: String) -> Date? {
    let bytes = text.utf8
    guard let dot = bytes.firstIndex(of: UInt8(ascii: ".")) else {
        return try? wholeSecondDateStyle.parse(text)
    }

    let asciiDigits = UInt8(ascii: "0")...UInt8(ascii: "9")
    let digitsStart = bytes.index(after: dot)
    let digitsEnd = bytes[digitsStart...].firstIndex { !asciiDigits.contains($0) } ?? bytes.endIndex
    guard digitsStart < digitsEnd else { return nil }

    // Each index here is an ASCII byte or the byte after one, so each falls on a
    // scalar boundary and slices the text exactly where it slices its bytes.
    let digits = text[digitsStart..<digitsEnd]
    let withoutFraction = String(text[..<dot] + text[digitsEnd...])
    guard
        let whole = try? wholeSecondDateStyle.parse(withoutFraction),
        let fraction = Double("0." + digits)
    else { return nil }

    return whole.addingTimeInterval(fraction)
}
