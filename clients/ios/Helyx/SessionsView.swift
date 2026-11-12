import SwiftUI

/// The live sessions, then the saved ones newest first, the folder of a new
/// session, and the line of the connection. A pull to refresh asks the live
/// sessions and the first page of the saved ones (`docs/features/ios-app.md`,
/// "The sessions").
struct SessionsView: View {
    @EnvironmentObject private var store: Store
    @State private var folder = ""

    var body: some View {
        List {
            Section {
                Text(store.snapshot?.line ?? "connecting")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let line = store.snapshot?.followLine {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let notice = store.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("New session") {
                HStack {
                    TextField("Folder", text: $folder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Start") { store.start(folder) }
                        .disabled(folder.isEmpty)
                }
            }

            Section("Live") {
                let live = store.snapshot?.live ?? []
                if live.isEmpty {
                    Text("No live sessions").foregroundStyle(.secondary)
                }
                ForEach(live, id: \.id) { session in
                    Button {
                        store.follow(session.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.cwd).lineLimit(1)
                            Text(session.model)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Saved") {
                let saved = store.snapshot?.saved ?? []
                if saved.isEmpty {
                    Text("No saved sessions").foregroundStyle(.secondary)
                }
                ForEach(saved, id: \.id) { session in
                    Button {
                        store.resume(session.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.prompt)
                                .lineLimit(2)
                                .foregroundStyle(
                                    session.prompt.isEmpty ? .secondary : .primary
                                )
                            Text(session.cwd)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if store.snapshot?.savedNext != nil {
                    Button("More") { store.more() }
                }
            }
        }
        .refreshable { store.refresh() }
        .navigationTitle("Sessions")
        .toolbar {
            Button("Server") { store.showSettings() }
        }
    }
}
