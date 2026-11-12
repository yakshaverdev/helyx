import XCTest

@testable import Helyx

/// A connection that records its calls and gives one number for each send.
final class FakeConnection: ConnectionLike {
    var followed: [String] = []
    var prompted: [String] = []
    var steered: [String] = []
    var followedUp: [String] = []
    var aborted: [String] = []
    var answers: [(askId: String, answer: String)] = []
    var becameActiveCount = 0
    private var nextSend: UInt64 = 1

    func follow(session: String) throws {
        followed.append(session)
    }

    func liveSessions() throws {}

    func savedSessions(after: String?) throws {}

    func startSession(cwd: String) throws -> UInt64 {
        next()
    }

    func resumeSession(id: String) throws -> UInt64 {
        next()
    }

    func prompt(session: String, text: String) throws -> UInt64 {
        prompted.append(text)
        return next()
    }

    func steer(session: String, text: String) throws -> UInt64 {
        steered.append(text)
        return next()
    }

    func followUp(session: String, text: String) throws -> UInt64 {
        followedUp.append(text)
        return next()
    }

    func abort(session: String) throws -> UInt64 {
        aborted.append(session)
        return next()
    }

    func answer(session: String, askId: String, answer: String) throws -> UInt64 {
        answers.append((askId, answer))
        return next()
    }

    func becameActive() throws {
        becameActiveCount += 1
    }

    private func next() -> UInt64 {
        let send = nextSend
        nextSend += 1
        return send
    }
}

@MainActor
final class StoreTests: XCTestCase {
    private let settings = ServerSettings(
        address: "127.0.0.1",
        port: 4000,
        token: "tok"
    )

    /// A store with a factory that records each connection it makes, and a
    /// settings write that touches no Keychain.
    private func makeStore() -> (Store, () -> [FakeConnection]) {
        var fakes: [FakeConnection] = []
        let store = Store(
            settings: nil,
            make: { _, _ in
                let fake = FakeConnection()
                fakes.append(fake)
                return fake
            },
            save: { _ in true }
        )
        return (store, { fakes })
    }

    private func state(running: Bool = false) -> SessionState {
        SessionState(
            instanceId: "i1",
            seq: 1,
            model: "fake/echo",
            running: running,
            more: false,
            queue: Queue(steers: 0, followUps: 0, running: 0, held: 0, waiting: 0),
            notices: [],
            asks: [],
            answering: nil,
            rows: [],
            partial: nil,
            uiBlocks: []
        )
    }

    private func snapshot(
        line: String = "connected",
        outcomes: [Outcome] = [],
        session: SessionState? = nil
    ) -> Snapshot {
        Snapshot(
            line: line,
            followLine: nil,
            followed: session == nil ? nil : "s1",
            live: [],
            records: [],
            recordsMore: false,
            recordsFeed: false,
            saved: [],
            savedNext: nil,
            requests: [],
            outcomes: outcomes,
            session: session
        )
    }

    func testTheNewestSnapshotReplacesTheState() {
        let (store, _) = makeStore()
        store.receive(snapshot(line: "connecting"))
        store.receive(snapshot(line: "connected"))
        store.drain()
        XCTAssertEqual(store.snapshot?.line, "connected")
        // A second drain finds no snapshot and changes nothing.
        store.drain()
        XCTAssertEqual(store.snapshot?.line, "connected")
    }

    func testASendIsPendingUntilItsOutcome() {
        let (store, fakes) = makeStore()
        store.use(settings)
        store.receive(snapshot(session: state()))
        store.drain()
        store.composer = "hello"
        store.send()
        XCTAssertEqual(fakes().first?.prompted, ["hello"])
        XCTAssertEqual(store.composer, "")
        XCTAssertEqual(store.pending.count, 1)
        XCTAssertEqual(store.pending.first?.send, 1)
        XCTAssertEqual(store.pending.first?.text, "hello")
        // The outcome of that number removes the mark.
        store.receive(snapshot(outcomes: [Outcome(send: 1, outcome: .ok)]))
        store.drain()
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertNil(store.notice)
    }

    func testAFailedSendPutsTheTextBackWithTheReason() {
        let (store, _) = makeStore()
        store.use(settings)
        store.receive(snapshot(session: state()))
        store.drain()
        store.composer = "hello"
        store.send()
        store.receive(
            snapshot(
                outcomes: [
                    Outcome(
                        send: 1,
                        outcome: .failed(reason: "the connection has stopped")
                    )
                ]
            )
        )
        store.drain()
        XCTAssertEqual(store.composer, "hello")
        XCTAssertEqual(store.notice, "the connection has stopped")
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testAnOutcomeOutlivesASnapshotThatReplacesItsOwn() {
        let (store, _) = makeStore()
        store.use(settings)
        store.receive(snapshot(session: state()))
        store.drain()
        store.composer = "hello"
        store.send()
        // Two snapshots before one draw: the second has no outcome.
        store.receive(snapshot(outcomes: [Outcome(send: 1, outcome: .ok)]))
        store.receive(snapshot(session: state()))
        store.drain()
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testAFailedSendKeepsTheDraftTypedAfterIt() {
        let (store, _) = makeStore()
        store.use(settings)
        store.receive(snapshot(session: state()))
        store.drain()
        store.composer = "first"
        store.send()
        store.composer = "draft"
        store.receive(snapshot(outcomes: [Outcome(send: 1, outcome: .failed(reason: "stopped"))]))
        store.drain()
        XCTAssertEqual(store.composer, "first\ndraft")
    }

    func testAnActiveAppWakesTheConnectionOnce() {
        let (store, fakes) = makeStore()
        store.use(settings)
        store.scenePhase(.background)
        store.scenePhase(.inactive)
        store.scenePhase(.active)
        XCTAssertEqual(fakes().first?.becameActiveCount, 1)
        // An active scene with no background before it wakes nothing.
        store.scenePhase(.active)
        XCTAssertEqual(fakes().first?.becameActiveCount, 1)
    }

    func testASettingsChangeMakesANewConnection() {
        let (store, fakes) = makeStore()
        store.use(settings)
        store.use(
            ServerSettings(address: "127.0.0.1", port: 4001, token: "tok-2")
        )
        XCTAssertEqual(fakes().count, 2)
        XCTAssertTrue(store.connection === fakes().last)
        XCTAssertEqual(store.settings?.port, 4001)
    }
}
