import Foundation

/// One element of a watch: exactly one for every line the CLI prints.
///
/// Three cases are about the watch itself, three are about a posting in a box,
/// and the last one is whatever a future CLI prints that this version of the
/// package does not know. Nothing here ends the stream, so a line the package
/// cannot read costs an app that line and never the watch.
public enum WatchLine: Sendable, Hashable {
    /// The watch is following its boxes. Every line before the first one describes
    /// a change that happened before the watch began, and is a replayed line.
    case ready(at: Date)
    /// The watch lost its connection to HEY. It reconnects on its own, and says so
    /// with the next ``ready(at:)``.
    case disconnected(at: Date)
    /// The box changed faster than the watch could follow, so the caller has to
    /// read that box again rather than patch what it is showing.
    case resync(at: Date, box: BoxKind)
    /// A posting appeared in the box, with the posting in the shape a box read
    /// gives it.
    case added(Change)
    /// A posting already in the box changed, with the posting in the shape a box
    /// read gives it.
    case updated(Change)
    /// A posting left the box. The CLI prints no posting on this line, so there is
    /// nothing to carry beside what it was.
    case deleted(Deletion)
    /// A line this version of the package does not know: a `change` value it has
    /// not seen, a line that is not a JSON object with a `change` in it, or a line
    /// whose body it could not read. It carries the CLI's own text, so an app can
    /// log exactly what arrived and a future CLI never ends the watch.
    case unrecognized(rawText: String)

    /// A posting that appeared in a box or changed inside one.
    public struct Change: Sendable, Hashable {
        /// When the watch saw the change.
        public let at: Date
        /// The box the change happened in. The CLI prints an id and a display name
        /// beside the kind, and neither is carried: a box is its kind.
        public let box: BoxKind
        /// The posting that changed.
        public let postingID: Posting.ID
        /// The topic the line is about. The CLI calls it `thread_id`, and it prints
        /// none beside a bundle it only touched, so this is nil there.
        public let topicID: TopicID?
        /// Whether the topic is unseen, not muted and active since the watch last
        /// looked. The CLI calls it `new` and omits it for false. It is not the
        /// same as unseen, and a replayed line is never new mail.
        public let isNewMail: Bool
        /// Whether the line arrived before the watch's first ``ready(at:)``, and so
        /// describes a change from before the watch began.
        public let isReplayed: Bool
        /// The posting as it now stands, in the shape a box read gives it.
        public let posting: Posting
    }

    /// A posting that left a box.
    public struct Deletion: Sendable, Hashable {
        /// When the watch saw the posting leave.
        public let at: Date
        /// The box the posting left. The CLI prints an id and a display name beside
        /// the kind, and neither is carried: a box is its kind.
        public let box: BoxKind
        /// The posting that left.
        public let postingID: Posting.ID
        /// The topic the line is about. The CLI calls it `thread_id`.
        public let topicID: TopicID?
        /// Whether the topic was new mail. The CLI calls it `new` and omits it for
        /// false.
        public let isNewMail: Bool
        /// Whether the line arrived before the watch's first ``ready(at:)``.
        public let isReplayed: Bool
    }
}
