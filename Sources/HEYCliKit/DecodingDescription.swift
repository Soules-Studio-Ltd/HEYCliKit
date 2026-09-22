/// The package's own refusal of a value it read but will not accept, carried as
/// the underlying error of a corrupted data error.
///
/// Its message is a `StaticString`, so it is written once in the source and can
/// never interpolate the value it refuses. That is what makes it the one
/// underlying error a decoding failure's description quotes.
struct SchemaRefusal: Error {
    let message: StaticString

    /// Builds the corrupted data error that carries this refusal, at the path the
    /// refused value was read from.
    ///
    /// The context's own description repeats the message, for whoever reads the
    /// error directly, but the package never builds a description from it.
    func decodingError(at codingPath: [any CodingKey]) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: String(describing: message),
                underlyingError: self
            )
        )
    }
}

/// Describes a decoding error by its kind and its path, in the package's own words.
///
/// A decoding failure's description may be logged verbatim by an app, so it must
/// never carry a value out of a mailbox. Foundation's own wording does: the error
/// under a corrupted data error quotes the character it choked on or the number it
/// could not represent, and the description of a raw value enum it could not read
/// quotes the raw value. So this never reads a context's description nor its
/// underlying error, not even as a fallback, apart from the message of the
/// package's own ``SchemaRefusal``, which cannot hold a value.
///
/// What it does read is the expected type, which is a schema token, and the
/// coding path, whose keys are the package's own coding keys and whose indices
/// are positions. That guarantee rests on no container being keyed by what the
/// CLI printed: no `[String: X]` is decoded and no super decoder is taken, so no
/// key in a path ever came from the CLI's data. A future dictionary keyed by data
/// would put that data in a path, and so in the description, and would break it.
///
/// A corrupted data error at the root is not only output that is not JSON: the
/// current Foundation reports a number it cannot represent there too, such as one
/// too large for an `Int` or a fraction where an `Int` belongs, even when the
/// output is valid JSON. So the root is described in a sentence true of both.
func describeDecodingError(_ error: any Error) -> String {
    let undecodable = "The output could not be decoded."

    guard let error = error as? DecodingError else {
        return undecodable
    }

    switch error {
    case let .typeMismatch(type, context):
        return "Expected \(type) at \(describePath(context.codingPath))."
    case let .valueNotFound(type, context):
        return "Expected \(type) at \(describePath(context.codingPath)), found null."
    case let .keyNotFound(key, context):
        return "The key \(key.stringValue) is missing at \(describePath(context.codingPath))."
    case let .dataCorrupted(context):
        if let refusal = context.underlyingError as? SchemaRefusal {
            return "\(refusal.message) Refused at \(describePath(context.codingPath))."
        }
        if context.codingPath.isEmpty {
            return "The output could not be read."
        }
        return "The value at \(describePath(context.codingPath)) could not be read."
    @unknown default:
        return undecodable
    }
}

/// Renders a coding path as its keys joined with `.`, each index as `[n]`, and
/// the empty path as the root.
private func describePath(_ codingPath: [any CodingKey]) -> String {
    guard !codingPath.isEmpty else { return "the root" }

    var path = ""
    for key in codingPath {
        if let index = key.intValue {
            path += "[\(index)]"
        } else {
            path += path.isEmpty ? key.stringValue : "." + key.stringValue
        }
    }

    return path
}
