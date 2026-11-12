import SwiftUI

/// The transcript of the session: the rows, the partial message, the UI blocks
/// of the turn, the sends that wait, and the notices. It scrolls to the
/// newest row when the reader is at the bottom, and stays where it is when
/// they scrolled up (`docs/features/ios-app.md`, "The session").
struct TranscriptView: View {
    @EnvironmentObject private var store: Store
    let state: SessionState
    @State private var expanded: Set<String> = []
    @State private var atBottom = true
    private let bottom = "bottom"

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(state.rows.enumerated()), id: \.offset) { _, row in
                                RowView(row: row, expanded: $expanded)
                            }
                            if let partial = state.partial {
                                MessageView(message: partial, expanded: $expanded)
                            }
                            ForEach(Array(state.uiBlocks.enumerated()), id: \.offset) { _, shown in
                                UiBlockView(json: shown.block)
                            }
                            ForEach(Array(store.pending.enumerated()), id: \.offset) { _, send in
                                if !send.text.isEmpty {
                                    Text("sending \(send.text)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            ForEach(Array(state.notices.enumerated()), id: \.offset) { _, notice in
                                Text(notice)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding()
                        // The marker sits outside the lazy stack, so its
                        // distance from the top is known while the reader is
                        // anywhere in the transcript.
                        Color.clear
                            .frame(height: 1)
                            .id(bottom)
                            .background(
                                GeometryReader { inner in
                                    Color.clear.preference(
                                        key: BottomKey.self,
                                        value: inner.frame(in: .named("transcript")).maxY
                                    )
                                }
                            )
                    }
                }
                .coordinateSpace(name: "transcript")
                .onPreferenceChange(BottomKey.self) { maxY in
                    atBottom = maxY <= outer.size.height + 1
                }
                .onChange(of: state) { _, _ in
                    if atBottom {
                        scroll(proxy)
                    }
                }
                .onAppear {
                    // The first layout is not done at `onAppear`; the scroll
                    // to the bottom marker runs after it.
                    DispatchQueue.main.async { scroll(proxy) }
                }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(bottom, anchor: .bottom)
        }
    }
}

/// The distance from the top of the scroll view to the bottom marker.
private struct BottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One row of the transcript.
private struct RowView: View {
    let row: Row
    @Binding var expanded: Set<String>

    var body: some View {
        switch row {
        case .message(let message):
            MessageView(message: message, expanded: $expanded)
        case .call(let call, let result):
            CallView(call: call, result: result, expanded: $expanded)
        case .orphan(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("a tool result with no call")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MessageView(message: message, expanded: $expanded)
            }
        }
    }
}

/// A tool call with its name, its arguments in a monospaced box, and its
/// result or `awaiting result`.
private struct CallView: View {
    let call: Block
    let result: Message?
    @Binding var expanded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .toolCall(_, let name, let arguments) = call {
                Text(name).font(.callout.bold())
                BoundedText(text: arguments)
            }
            if let result {
                MessageView(message: result, expanded: $expanded)
            } else {
                Text("awaiting result")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A message: its text and thinking blocks, its tool calls, and the UI blocks
/// of a result.
private struct MessageView: View {
    let message: Message
    @Binding var expanded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(message.content.enumerated()), id: \.offset) { index, block in
                blockView(block, at: index)
            }
            ForEach(Array(message.uiBlocks.enumerated()), id: \.offset) { _, json in
                UiBlockView(json: json)
            }
            if message.isError {
                Text("error").font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: Block, at index: Int) -> some View {
        switch block {
        case .text(let text):
            switch message.role {
            case .toolResult:
                BoundedText(text: text)
            case .user:
                Text(text)
                    .padding(10)
                    .background(.tint.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .assistant:
                Text(inline(text))
            }
        case .thinking(let text):
            ThinkingView(
                id: "\(message.id)/\(index)",
                text: text,
                expanded: $expanded
            )
        case .toolCall(_, let name, let arguments):
            Text(name).font(.callout.bold())
            BoundedText(text: arguments)
        case .unknown(let kind):
            Text("[\(kind)]")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The inline Markdown of an assistant text (bold, italic, code, links),
    /// with its line breaks kept. Block Markdown stays as written, and a
    /// text that does not parse shows as plain text.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}

/// A thinking block: one line, which a tap opens.
private struct ThinkingView: View {
    let id: String
    let text: String
    @Binding var expanded: Set<String>

    var body: some View {
        Button {
            if expanded.contains(id) {
                expanded.remove(id)
            } else {
                expanded.insert(id)
            }
        } label: {
            Text(expanded.contains(id) ? text : oneLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(expanded.contains(id) ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var oneLine: String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return "thinking: \(first)"
    }
}
