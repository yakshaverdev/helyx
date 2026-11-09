//! The watchdog thread of a connection ends within its poll of the end of
//! the connection. Its own test binary: the count of live watchdogs is
//! global.

mod stub;

use helyx_desktop::net::{self, Shared};
use helyx_desktop::socket::{WAITS, Waits, live_watchdogs};
use std::sync::Mutex;
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

/// A margin for load: other worktrees run tests on this machine.
const LOAD_MARGIN: Duration = Duration::from_secs(2);

#[test]
fn the_watchdog_ends_with_its_connection() {
    let (server, stub) = stub::one(|mut ws| {
        stub::welcome(&mut ws, "tok-q4");
        let _live = ws.read();
        // A close: the connection ends, and the reconnect is refused.
        let _ = ws.close(None);
        let _ = ws.flush();
    });
    let waits = Waits {
        pause: Duration::ZERO,
        poll: Duration::from_millis(100),
        ..WAITS
    };
    let shared = Mutex::new(Shared::new("tok-q4".into()));
    // The window is gone: the thread ends at the end of the connection.
    let receive = channel::<helyx_desktop::net::Command>().1;
    net::run_with(&server, &shared, &receive, &|| {}, waits);
    let ended = Instant::now();
    stub.join().unwrap();
    while live_watchdogs() > 0 {
        assert!(
            ended.elapsed() < waits.poll + LOAD_MARGIN,
            "a watchdog outlived its connection"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}
