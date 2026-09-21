import Foundation

/// Turns the CLI's watch lines into ``WatchLine`` values, one at a time, and ends
/// the watch the way its child ended.
///
/// It keeps the two pieces of state a line cannot carry on its own. Whether a
/// `ready` has arrived yet: everything before the first one is a replayed line,
/// and the flag stays flipped for the rest of the watch, so a reconnect's second
/// `ready` does not start the replay over. And the run of lines at the very end
/// that the package could not read, which is what ``finish(_:exitStatus:standardError:)``
/// hands the envelope mapping as a failed child's parting words.
///
/// It is `package` rather than internal so the fixture client in the test support
/// product replays scripted bytes through this exact decoder, and an app's tests
/// see the values a live watch would have given them. Both the live pump and that
/// client decode every line here and hand the ending here too, so what a watch
/// says cannot come to mean one thing live and another from a fixture.
package struct WatchLineDecoder {
    /// One decoder for the whole watch rather than one per line, since a watch is
    /// thousands of lines long.
    private let decoder = makeEnvelopeDecoder()
    private var hasSeenReady = false
    private var trailingUnrecognized: [String] = []

    package init() {}

    /// Reads one line of the CLI's output.
    ///
    /// It never throws. A line the package cannot read is an unrecognised line
    /// carrying the CLI's own text, because a watch that died on one line would
    /// die again on the same line when it was restarted with `--since`.
    package mutating func decode(_ line: String) -> WatchLine {
        let decoded = decodedLine(line)

        // A CLI that gave up prints its error envelope after its last watch line,
        // so the run of unrecognised lines grows while they arrive and is dropped
        // the moment a line the package does read follows them.
        if case .unrecognized = decoded {
            trailingUnrecognized.append(line)
        } else {
            trailingUnrecognized.removeAll(keepingCapacity: true)
        }

        return decoded
    }

    /// Ends the watch's stream the way the child ended.
    ///
    /// A clean exit is the end of a stream and not a failure: nothing was wrong
    /// with it, so the caller is left to decide whether to start another watch.
    /// Any other ending goes through the same envelope mapping every other
    /// operation goes through, so a watch that started signed out ends with
    /// ``HEYCliKitError/signedOut(_:)`` carrying the CLI's own hint.
    ///
    /// What that mapping reads as the child's stdout is the trailing run of lines
    /// the package could not recognise, which is where a CLI that gave up printed
    /// its error envelope, whether it printed it on one line or over several. When
    /// those lines are not an envelope, the mapping reads the child's stderr for
    /// one next, as it does for any other failed command.
    package func finish(
        _ continuation: AsyncThrowingStream<WatchLine, any Error>.Continuation,
        exitStatus: ProcessExitStatus,
        standardError: Data
    ) {
        if case .exited(0) = exitStatus {
            continuation.finish()

            return
        }

        do {
            try throwIfFailed(
                exitStatus: exitStatus,
                standardOutput: Data(trailingUnrecognized.joined(separator: "\n").utf8),
                standardError: standardError
            )
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// What one line stands for, before the trailing run is updated for it.
    private mutating func decodedLine(_ line: String) -> WatchLine {
        guard let body = try? decoder.decode(WatchLineBody.self, from: Data(line.utf8)) else {
            return .unrecognized(rawText: line)
        }

        let isReplayed = !hasSeenReady

        switch body {
        case let .ready(at):
            hasSeenReady = true

            return .ready(at: at)
        case let .disconnected(at):
            return .disconnected(at: at)
        case let .resync(at, box):
            return .resync(at: at, box: box)
        case let .added(fields, posting):
            return .added(fields.change(posting: posting, isReplayed: isReplayed))
        case let .updated(fields, posting):
            return .updated(fields.change(posting: posting, isReplayed: isReplayed))
        case let .deleted(fields):
            return .deleted(fields.deletion(isReplayed: isReplayed))
        }
    }
}

/// What one watch line said, before the watch decides whether it was replayed.
private enum WatchLineBody: Decodable {
    case ready(at: Date)
    case disconnected(at: Date)
    case resync(at: Date, box: BoxKind)
    case added(ChangeFields, Posting)
    case updated(ChangeFields, Posting)
    case deleted(ChangeFields)

    /// What every change line carries beside its posting.
    struct ChangeFields {
        let at: Date
        let box: BoxKind
        let postingID: Posting.ID
        let topicID: TopicID?
        let isNewMail: Bool

        func change(posting: Posting, isReplayed: Bool) -> WatchLine.Change {
            WatchLine.Change(
                at: at,
                box: box,
                postingID: postingID,
                topicID: topicID,
                isNewMail: isNewMail,
                isReplayed: isReplayed,
                posting: posting
            )
        }

        func deletion(isReplayed: Bool) -> WatchLine.Deletion {
            WatchLine.Deletion(
                at: at,
                box: box,
                postingID: postingID,
                topicID: topicID,
                isNewMail: isNewMail,
                isReplayed: isReplayed
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case change
        case at
        case box
        case postingID = "posting_id"
        case topicID = "thread_id"
        case isNewMail = "new"
        case posting
    }

    /// The box object the CLI prints. Only the kind is read: a box is its kind,
    /// never its numeric id or the display name beside it.
    private enum BoxCodingKeys: String, CodingKey {
        case kind
    }

    /// What the CLI spells in `change`.
    private enum ChangeValue: String, Decodable {
        case ready
        case disconnected
        case resync
        case added
        case updated
        case deleted
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The change is read before anything else, so a value this version of the
        // package does not know never becomes half a line of a shape it was never
        // going to fit. The caller turns the failure into an unrecognised line.
        let change = try container.decode(ChangeValue.self, forKey: .change)
        let at = try container.decode(Date.self, forKey: .at)

        func box() throws -> BoxKind {
            try container
                .nestedContainer(keyedBy: BoxCodingKeys.self, forKey: .box)
                .decode(BoxKind.self, forKey: .kind)
        }

        func fields() throws -> ChangeFields {
            ChangeFields(
                at: at,
                box: try box(),
                postingID: Posting.ID(try container.decode(Int.self, forKey: .postingID)),
                topicID: try container.decodeIfPresent(Int.self, forKey: .topicID).map(TopicID.init),
                // The CLI omits `new` when a change is not new mail, so a missing
                // key is false rather than a line the package cannot read.
                isNewMail: try container.decodeIfPresent(Bool.self, forKey: .isNewMail) ?? false
            )
        }

        /// The posting the line carries, read with the line's own topic beside it.
        ///
        /// The CLI prints no `topic_id` on a posting inside a watch line: the
        /// line's `thread_id` is what names the topic, so it is handed to the
        /// posting as the topic id to fall back on.
        func posting(_ fields: ChangeFields) throws -> Posting {
            try Posting.decode(
                from: try container.nestedContainer(
                    keyedBy: PostingCodingKeys.self,
                    forKey: .posting
                ),
                fallbackTopicID: fields.topicID
            )
        }

        switch change {
        case .ready:
            self = .ready(at: at)
        case .disconnected:
            self = .disconnected(at: at)
        case .resync:
            self = .resync(at: at, box: try box())
        case .added:
            let fields = try fields()
            self = .added(fields, try posting(fields))
        case .updated:
            let fields = try fields()
            self = .updated(fields, try posting(fields))
        case .deleted:
            self = .deleted(try fields())
        }
    }
}
