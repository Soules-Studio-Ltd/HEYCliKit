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
/// The CLI prints RFC 3339 dates with a Z, which is what the ISO 8601 strategy
/// reads. Some of them carry fractional seconds, `observed_at` among them, and the
/// strategy on the Foundation this package supports accepts those too, which the
/// box page tests guard.
func makeEnvelopeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    return decoder
}
