import Foundation
import SwiftUI

/// The calls of `Connection` that the store makes, so a unit test drives the
/// store with a fake and no server. `Connection` conforms with no code.
protocol ConnectionLike: AnyObject {
    func follow(session: String) throws
    func liveSessions() throws
    func savedSessions(after: String?) throws
    func startSession(cwd: String) throws -> UInt64
    func resumeSession(id: String) throws -> UInt64
    func prompt(session: String, text: String) throws -> UInt64
    func steer(session: String, text: String) throws -> UInt64
    func followUp(session: String, text: String) throws -> UInt64
    func abort(session: String) throws -> UInt64
    func answer(session: String, askId: String, answer: String) throws -> UInt64
    func becameActive() throws
}

extension Connection: ConnectionLike {}

/// A send that the store waits on: a message of the composer, which shows as
/// pending, or the answer of an ask, which keeps the ask closed.
struct PendingSend: Equatable {
    /// The number of the send, whose outcome settles it.
    let send: UInt64
    /// The text of a message, which a failed send puts back in the field.
    let text: String
    /// The ask that the send answers; none for a message.
    let askId: String?
}

/// The one snapshot that the store has not drawn yet. The network thread puts
/// each change, and the main actor takes the newest, so a draw that is slow
/// skips the states between.
final class SnapshotMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var newest: Snapshot?

    func put(_ snapshot: Snapshot) {
        lock.lock()
        newest = snapshot
        lock.unlock()
    }

    func take() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = newest
        newest = nil
        return snapshot
    }
}

/// The bridge from the network thread to the store: the callback of the
/// bindings puts each snapshot in the store's mailbox, and the main actor
/// draws it. The class is `@unchecked Sendable` because the only state that it
/// touches from the network thread is the mailbox, which is thread-safe.
final class Listener: NetListener, @unchecked Sendable {
    private weak var store: Store?

    init(store: Store) {
        self.store = store
    }

    func onSnapshot(snapshot: Snapshot) {
        store?.receive(snapshot)
    }
}

/// The state of the app: one connection, the newest snapshot, the message of
/// the composer, and the sends that wait (`docs/features/ios-app.md`, "The
/// store"). The views draw the snapshot and call these methods.
@MainActor
final class Store: ObservableObject {
    /// The newest state of the connection, or none before the first change.
    @Published private(set) var snapshot: Snapshot?
    /// The server in use; none until the user saves one.
    @Published private(set) var settings: ServerSettings?
    /// The text of the composer.
    @Published var composer = ""
    /// The sends of the composer and of the asks that wait for an outcome.
    @Published private(set) var pending: [PendingSend] = []
    /// Why the last call failed, for a line.
    @Published var notice: String?
    /// True when the settings screen shows while a server is in use.
    @Published private(set) var settingsShown = false
    /// True when the list of sessions shows instead of the followed session.
    @Published private(set) var listShown = true

    private(set) var connection: ConnectionLike?
    private let make: (ServerSettings, NetListener) throws -> ConnectionLike
    private let save: (ServerSettings) -> Bool
    private let mailbox = SnapshotMailbox()
    /// True after a background, until the next active: one `becameActive` for
    /// one return from the background.
    private var backgrounded = false

    /// `make` and `save` are seams of the tests: the app uses `Connection` and
    /// the storage of `SettingsStorage`.
    init(
        settings: ServerSettings? = SettingsStorage.load(),
        make: ((ServerSettings, NetListener) throws -> ConnectionLike)? = nil,
        save: ((ServerSettings) -> Bool)? = nil
    ) {
        self.settings = settings
        self.make = make ?? { settings, listener in
            try Connection(
                address: settings.address,
                port: settings.port,
                token: settings.token,
                listener: listener
            )
        }
        self.save = save ?? SettingsStorage.save
        if let settings {
            settingsShown = !open(settings)
        }
    }

    /// Uses `settings`: drops the connection in use and opens a new one, so a
    /// change of the server is one connection, not two. A settings screen
    /// stays when the address or the port is refused.
    func use(_ settings: ServerSettings) {
        connection = nil
        let saved = save(settings)
        self.settings = settings
        snapshot = nil
        pending = []
        notice = nil
        listShown = true
        settingsShown = !open(settings)
        if !saved, notice == nil {
            notice = "the token was not saved; the next launch asks for it again"
        }
    }

    func showSettings() {
        settingsShown = true
    }

    func cancelSettings() {
        settingsShown = false
    }

    /// Shows the list, and asks it again: the server sends no change of the
    /// lists, so the one of the last visit can be old.
    func showList() {
        listShown = true
        refresh()
    }

    /// Asks the live sessions and the first page of the saved ones, as a pull
    /// to refresh does.
    func refresh() {
        do {
            try connection?.liveSessions()
            try connection?.savedSessions(after: nil)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Asks the next page of the saved sessions.
    func more() {
        guard let next = snapshot?.savedNext else { return }
        do {
            try connection?.savedSessions(after: next)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Follows the live session `id`, and shows its transcript.
    func follow(_ id: String) {
        do {
            try connection?.follow(session: id)
            listShown = false
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Resumes the saved session `id`; the server follows it when it opens.
    func resume(_ id: String) {
        do {
            _ = try connection?.resumeSession(id: id)
            listShown = false
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Starts a session in `folder`; the server follows the one that it makes.
    func start(_ folder: String) {
        do {
            _ = try connection?.startSession(cwd: folder)
            listShown = false
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Sends the composer: a steer while a turn runs, else a prompt. The field
    /// empties at once, and the message shows as pending until its outcome.
    func send() {
        send(snapshot?.session?.running == true ? .steer : .prompt)
    }

    /// Sends the composer after the running turn.
    func followUp() {
        send(.followUp)
    }

    /// Aborts the running turn.
    func stop() {
        guard let session = snapshot?.followed, let connection else { return }
        do {
            _ = try connection.abort(session: session)
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Sends the answer of the ask `askId`; `answer` is the JSON text that
    /// `formAnswer` or `approvalAnswer` built.
    func answer(_ askId: String, _ answer: String) {
        guard let session = snapshot?.followed, let connection else { return }
        do {
            let send = try connection.answer(
                session: session,
                askId: askId,
                answer: answer
            )
            pending.append(PendingSend(send: send, text: "", askId: askId))
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    /// The ask that takes the place of the composer: the open one, when no
    /// answer to it is on the way.
    var openAsk: Ask? {
        let state = snapshot?.session
        guard
            let askId = state?.answering,
            !pending.contains(where: { $0.askId == askId })
        else { return nil }
        return state?.asks.first { $0.askId == askId }
    }

    /// Takes the snapshot of a change from the network thread, on any thread.
    nonisolated func receive(_ snapshot: Snapshot) {
        mailbox.put(snapshot)
        Task { @MainActor in self.drain() }
    }

    /// The main-actor step of `receive`: draws the newest snapshot and settles
    /// the sends whose outcomes came with it.
    func drain() {
        guard let snapshot = mailbox.take() else { return }
        self.snapshot = snapshot
        for outcome in snapshot.outcomes {
            settle(outcome)
        }
    }

    /// Tells the connection that the app is active again, once for one return
    /// from the background.
    func scenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgrounded = true
        case .active:
            guard backgrounded else { return }
            backgrounded = false
            do {
                try connection?.becameActive()
            } catch {
                notice = error.localizedDescription
            }
        default:
            break
        }
    }

    private func open(_ settings: ServerSettings) -> Bool {
        let listener = Listener(store: self)
        do {
            connection = try make(settings, listener)
            notice = nil
            return true
        } catch {
            connection = nil
            notice = error.localizedDescription
            return false
        }
    }

    private enum Mode {
        case prompt
        case steer
        case followUp
    }

    private func send(_ mode: Mode) {
        guard let session = snapshot?.followed, let connection else { return }
        let text = composer
        guard !text.isEmpty else { return }
        do {
            let send: UInt64
            switch mode {
            case .prompt:
                send = try connection.prompt(session: session, text: text)
            case .steer:
                send = try connection.steer(session: session, text: text)
            case .followUp:
                send = try connection.followUp(session: session, text: text)
            }
            composer = ""
            notice = nil
            pending.append(PendingSend(send: send, text: text, askId: nil))
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Settles the send of `outcome`: `ok` removes its mark, and a failure
    /// puts the text of a message back in the field, or opens its ask again,
    /// with the reason.
    private func settle(_ outcome: Outcome) {
        guard let at = pending.firstIndex(where: { $0.send == outcome.send }) else {
            return
        }
        switch outcome.outcome {
        case .pending:
            break
        case .ok:
            pending.remove(at: at)
        case .failed(let reason):
            let send = pending.remove(at: at)
            if send.askId == nil {
                composer = send.text
            }
            notice = reason
        }
    }
}
