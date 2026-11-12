import SwiftUI

/// A text of at most `Bounds.shownText` characters, with a `more` control that
/// shows the rest. A result text and the arguments of a tool call use it.
struct BoundedText: View {
    let text: String
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(shown ? text : String(text.prefix(Bounds.shownText)))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            if !shown && text.count > Bounds.shownText {
                Button("more") { shown = true }
                    .font(.caption)
            }
        }
    }
}

/// A UI block that the session shows, read by the core: a `Text` view shows
/// the text, and a form or an approval that is not the open ask shows its
/// text. The open ask takes the place of the composer instead
/// (`docs/features/ios-app.md`, "The session").
struct UiBlockView: View {
    let json: String

    var body: some View {
        switch readBlock(json: json) {
        case .text(_, let text):
            BoundedText(text: text)
        case .form(let text, _):
            BoundedText(text: text)
        case .approval(let text, _, _, _):
            BoundedText(text: text)
        }
    }
}
