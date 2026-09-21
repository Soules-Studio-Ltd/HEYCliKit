/// The stable identifier of a box.
///
/// A box is identified by its kind and never by its display name or its numeric
/// id, so the raw value here is exactly what the CLI takes as a command argument.
/// Display names are Imbox, The Feed, Set Aside, Reply Later, Paper Trail and
/// Bubble Up, and they are the app's business, not the package's.
///
/// It is `Decodable` so a box the CLI prints in a list is read through this type
/// rather than as a bare string an app would have to match by hand.
public enum BoxKind: String, Sendable, Hashable, CaseIterable, Decodable {
    case imbox
    case feedbox
    case asidebox
    case laterbox
    case trailbox
    case bubblebox
}
