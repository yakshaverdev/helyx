import SwiftUI

/// The screen that the app shows: the settings when no server is in use or
/// the user opened them, else the transcript of the followed session, else the
/// list of sessions.
struct RootView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        NavigationStack {
            if store.settings == nil || store.settingsShown {
                SettingsView()
            } else if store.listShown || store.snapshot?.session == nil {
                SessionsView()
            } else {
                SessionView()
            }
        }
    }
}
