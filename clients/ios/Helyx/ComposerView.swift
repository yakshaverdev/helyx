import SwiftUI

/// The composer: a field of several lines, and the buttons of the turn. With
/// no turn running, `Send` sends a prompt; while one runs, `Send` steers and a
/// second button follows up, and `Stop` aborts. A send empties the field at
/// once and shows the message as pending (`docs/features/ios-app.md`, "The
/// composer").
struct ComposerView: View {
    @EnvironmentObject private var store: Store
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Message", text: $store.composer, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(running ? "Steer" : "Send") { store.send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.composer.isEmpty)
                if running {
                    Button("Follow up") { store.followUp() }
                        .disabled(store.composer.isEmpty)
                    Spacer()
                    Button("Stop") { store.stop() }
                        .tint(.red)
                }
            }
        }
        .padding()
    }
}

/// The counts of the queue of the session, in one small line.
struct QueueLine: View {
    let queue: Queue

    var body: some View {
        let parts = self.parts
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 4)
        }
    }

    private var parts: [String] {
        var parts: [String] = []
        if queue.running > 0 {
            parts.append("\(queue.running) running")
        }
        if queue.steers > 0 {
            parts.append("\(queue.steers) steers")
        }
        if queue.followUps > 0 {
            parts.append("\(queue.followUps) follow-ups")
        }
        if queue.held > 0 {
            parts.append("\(queue.held) held")
        }
        if queue.waiting > 0 {
            parts.append("\(queue.waiting) waiting")
        }
        return parts
    }
}
