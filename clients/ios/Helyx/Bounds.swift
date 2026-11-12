import CoreGraphics

/// The bounds that the views hold beyond the bounds of the core
/// (`docs/features/ios-app.md`, "Bounds").
enum Bounds {
    /// The characters of the arguments of a tool call, and of a result text,
    /// that a row shows before its `more` control: a phone shows this many
    /// while a longer text only costs scroll.
    static let shownText = 4_000
    /// The points of an ask that scroll before the Send button keeps its
    /// place: a form has at most four questions, and a taller panel would
    /// leave the transcript no room.
    static let askHeight: CGFloat = 320
}
