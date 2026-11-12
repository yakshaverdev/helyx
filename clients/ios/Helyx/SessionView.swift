import SwiftUI

/// The transcript of the followed session, with the ask or the composer under
/// it (`docs/features/ios-app.md`, "The session").
struct SessionView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(spacing: 0) {
            if let state = store.snapshot?.session {
                TranscriptView(state: state)
                    .frame(maxHeight: .infinity)
                Divider()
                QueueLine(queue: state.queue)
                if let notice = store.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                if let ask = store.openAsk {
                    AskView(ask: ask).id(ask.askId)
                } else {
                    ComposerView(running: state.running)
                }
            } else {
                ProgressView()
                    .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(store.snapshot?.session?.model ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Sessions") { store.showList() }
        }
    }
}
