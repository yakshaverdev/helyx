import SwiftUI

/// The open ask in the place of the composer: an approval with `Allow` and
/// `Deny`, or a form with one row for each question and one `Send`. The rules
/// are those of `app/src/ask.rs`: a single pick sends the marked label or the
/// Other text, a multiple pick sends its marks in option order and combines
/// them with the Other text, and `Send` waits until every question has an
/// answer (`docs/features/ios-app.md`, "The ask").
struct AskView: View {
    @EnvironmentObject private var store: Store
    let ask: Ask

    /// The truth of the ask, read once: the ask is a value of a snapshot.
    @State private var block: BlockView
    @State private var picks: [Int: String] = [:]
    @State private var marks: [Int: Set<String>] = [:]
    @State private var others: [Int: String] = [:]

    init(ask: Ask) {
        self.ask = ask
        let block = readBlock(json: ask.request)
        _block = State(initialValue: block)
        // A single pick starts on its first option, as the cursor of the
        // desktop ask does: one row of the list is checked.
        if case .form(_, let questions) = block {
            _picks = State(
                initialValue: questions.indices.reduce(into: [:]) { picks, index in
                    let question = questions[index]
                    if !question.multiSelect, let first = question.options.first {
                        picks[index] = first.label
                    }
                }
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch block {
            case .approval(_, let tool, let provider, let arguments):
                Text("Allow \(tool)?").font(.headline)
                if let provider {
                    Text("of \(provider)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                BoundedText(text: arguments)
                HStack {
                    Button("Allow") {
                        store.answer(ask.askId, approvalAnswer(allow: true))
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Deny") {
                        store.answer(ask.askId, approvalAnswer(allow: false))
                    }
                    .buttonStyle(.bordered)
                }
            case .form(_, let questions):
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(questions.enumerated()), id: \.offset) {
                            index, question in
                            questionView(index, question)
                        }
                    }
                }
                .frame(maxHeight: Bounds.askHeight)
                Button("Send") { send(questions) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!complete(questions))
            case .text(_, let text):
                // The host answers only a form and an approval, so this view
                // shows a text block only if the rule and the view disagree.
                Text(text)
            }
        }
        .padding()
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func questionView(_ index: Int, _ question: FormQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.question).font(.subheadline.bold())
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) {
                _, option in
                Button {
                    if question.multiSelect {
                        toggle(index, option.label)
                    } else {
                        pick(index, option.label)
                    }
                } label: {
                    optionRow(
                        option,
                        marked: marked(index, option),
                        multiple: question.multiSelect
                    )
                }
                .buttonStyle(.plain)
            }
            TextField("Other", text: other(index, question.multiSelect))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func optionRow(
        _ option: FormOption,
        marked: Bool,
        multiple: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol(marked: marked, multiple: multiple))
                .foregroundStyle(marked ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                if !option.description.isEmpty {
                    Text(option.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func symbol(marked: Bool, multiple: Bool) -> String {
        switch (multiple, marked) {
        case (true, true): return "checkmark.square"
        case (true, false): return "square"
        case (false, true): return "largecircle.fill.circle"
        case (false, false): return "circle"
        }
    }

    private func marked(_ index: Int, _ option: FormOption) -> Bool {
        if marks[index]?.contains(option.label) == true {
            return true
        }
        return picks[index] == option.label
    }

    /// A single pick is the marked option, and the Other text is the answer
    /// of the same question, so one replaces the other.
    private func pick(_ index: Int, _ label: String) {
        picks[index] = label
        others[index] = ""
    }

    private func toggle(_ index: Int, _ label: String) {
        var picked = marks[index] ?? []
        if picked.contains(label) {
            picked.remove(label)
        } else {
            picked.insert(label)
        }
        marks[index] = picked
    }

    private func other(_ index: Int, _ multiple: Bool) -> Binding<String> {
        Binding(
            get: { others[index] ?? "" },
            set: { text in
                others[index] = text
                if !multiple && !text.isEmpty {
                    picks[index] = nil
                }
            }
        )
    }

    /// The item of the question at `index`: the labels in option order for a
    /// multiple pick, and the Other text with them; for a single pick, either
    /// the label or the Other text.
    private func item(_ index: Int, _ question: FormQuestion) -> FormAnswerItem {
        let other = others[index] ?? ""
        if question.multiSelect {
            let selected = question.options
                .map(\.label)
                .filter { marks[index]?.contains($0) == true }
            return FormAnswerItem(
                selected: selected,
                other: other.isEmpty ? nil : other
            )
        }
        if !other.isEmpty {
            return FormAnswerItem(selected: [], other: other)
        }
        return FormAnswerItem(
            selected: picks[index].map { [$0] } ?? [],
            other: nil
        )
    }

    private func complete(_ questions: [FormQuestion]) -> Bool {
        questions.indices.allSatisfy { index in
            let item = item(index, questions[index])
            return !item.selected.isEmpty || item.other != nil
        }
    }

    private func send(_ questions: [FormQuestion]) {
        let items = questions.indices.map { item($0, questions[$0]) }
        store.answer(ask.askId, formAnswer(items: items))
    }
}
