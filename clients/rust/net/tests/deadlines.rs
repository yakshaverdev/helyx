//! The deadlines of a connection with short waits, against a stub server on
//! the loopback: the silence after the welcome while sends stall, the
//! deadline of a batch of sends, a send that fails after a binary frame and
//! after a frame that the socket read, and the TCP connect.

use net::stub;

use helyx_client_net as net;
use net::socket::{WAITS, Waits};
use net::{Command, Shared};
use std::net::{TcpListener, TcpStream};
use std::sync::Mutex;
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};
use stub::{LIVE, challenge, next_text, welcome};
use tungstenite::WebSocket;

/// A margin for load in a bound of elapsed time: other worktrees run tests
/// on this machine.
const LOAD_MARGIN: Duration = Duration::from_secs(3);

/// The send buffer of the socket of the host: the OS can buffer a batch of
/// several MiB whole, and then no write waits on its peer, so a test whose
/// batch must outlast its deadline caps the buffer here. The batch is 3 MB,
/// far over it.
const SEND_BUFFER: usize = 16_384;

/// Runs the network thread with `waits` against a stub that welcomes it and
/// takes `sessions.live`, then runs `serve`, whose receiver gets a message
/// once the thread has ended. Sends `commands` at the welcome, checks that
/// the thread ends at the refused reconnect, and gives its time from its
/// start and from the commands.
fn after_welcome(
    waits: Waits,
    commands: Vec<Command>,
    serve: impl FnOnce(&mut WebSocket<TcpStream>, Receiver<()>) + Send + 'static,
) -> (Duration, Duration) {
    let (stop, stopped) = channel();
    let (welcomed, at_welcome) = channel();
    let (server, stub) = stub::one(move |mut ws| {
        welcome(&mut ws, "tok-q4");
        let _live = next_text(&mut ws);
        welcomed.send(()).unwrap();
        serve(&mut ws, stopped);
    });
    let (send, receive) = channel();
    let thread = std::thread::spawn(move || {
        let started = Instant::now();
        let shared = Mutex::new(Shared::new("tok-q4".into()));
        let line = net::run_with(&server, &shared, &receive, &|| {}, waits);
        (line, started.elapsed())
    });
    at_welcome.recv().unwrap();
    let sent = Instant::now();
    for command in commands {
        send.send(command).unwrap();
    }
    // The window is gone: the thread ends at the end of the connection.
    drop(send);
    let (line, elapsed) = thread.join().unwrap();
    let from_commands = sent.elapsed();
    stop.send(()).unwrap();
    stub.join().unwrap();
    assert_eq!(line, "reconnecting");
    (elapsed, from_commands)
}

/// The silence counts from the last frame read, whatever the sends: a batch
/// that stalls on a server that reads nothing ends at the silence, not at
/// the longer send wait.
#[test]
fn the_silence_holds_while_sends_stall() {
    let waits = Waits {
        silence: Duration::from_millis(1_000),
        send: Duration::from_secs(20),
        pause: Duration::ZERO,
        poll: Duration::from_millis(50),
        send_buffer: Some(SEND_BUFFER),
        ..WAITS
    };
    // Frames of several MiB, which the socket cannot take.
    let commands = (0..8)
        .map(|n| Command::Follow(format!("{n}{}", "x".repeat(3_000_000))))
        .collect();
    // Reads nothing more, sends nothing more.
    let (elapsed, _) = after_welcome(waits, commands, |_, stopped| {
        let _ = stopped.recv();
    });
    // Ends at the silence after the welcome, not at the send wait. A loaded
    // machine passes any margin near the silence, so the bound is the send
    // wait, which the wrong rule would reach.
    assert!(elapsed >= waits.silence, "{elapsed:?}");
    assert!(elapsed < waits.send, "{elapsed:?}");
}

/// The deadline of a batch of sends: a batch that a slow reader takes
/// longer than it ends at it, though each write goes on; a batch that ends
/// clears it, and the connection lives on to the silence.
#[test]
fn a_batch_of_sends_has_a_deadline_of_its_own() {
    for slow in [true, false] {
        let waits = Waits {
            silence: Duration::from_millis(if slow { 8_000 } else { 2_000 }),
            send: Duration::from_millis(500),
            pause: Duration::ZERO,
            poll: Duration::from_millis(50),
            // The slow reader takes 3 MB in seconds, and the buffer keeps
            // the whole batch from the socket, so no write returns at once.
            send_buffer: Some(SEND_BUFFER),
            ..WAITS
        };
        let session = if slow {
            "x".repeat(3_000_000)
        } else {
            "s1".into()
        };
        let commands = vec![Command::Follow(session)];
        let (_, elapsed) = after_welcome(waits, commands, move |ws, stopped| {
            if !slow {
                let _subscribe = next_text(ws);
                let _ = stopped.recv();
                return;
            }
            // 16 KiB each 20 ms: each write of the app goes on, the batch
            // of 3 MB takes seconds.
            use std::io::Read;
            let stream = ws.get_mut();
            let mut buf = vec![0; 16_384];
            while stopped.try_recv().is_err() {
                if matches!(stream.read(&mut buf), Ok(0) | Err(_)) {
                    let _ = stopped.recv();
                    return;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });
        if slow {
            assert!(elapsed >= waits.send, "{elapsed:?}");
            // Far below the silence of 8 s, which ends it with no send
            // deadline.
            assert!(elapsed < waits.send + LOAD_MARGIN, "{elapsed:?}");
        } else {
            // Not at the send wait: at the silence after the welcome.
            assert!(
                elapsed >= waits.silence - Duration::from_millis(200),
                "{elapsed:?}"
            );
        }
    }
}

/// The TCP connect ends at its wait: a listener whose backlog is full takes
/// no connection.
#[test]
fn the_tcp_connect_ends_at_its_wait() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let mut held = vec![];
    let full = (0..1_000).any(|_| {
        match TcpStream::connect_timeout(&address, Duration::from_millis(300)) {
            Ok(stream) => {
                held.push(stream);
                false
            }
            Err(_) => true,
        }
    });
    assert!(full, "the backlog never filled");
    let waits = Waits {
        connect: Duration::from_millis(500),
        ..WAITS
    };
    let shared = Mutex::new(Shared::new("tok-q4".into()));
    let (_commands, receive) = channel();
    let started = Instant::now();
    let line = net::run_with(
        &stub::local(address.port()),
        &shared,
        &receive,
        &|| {},
        waits,
    );
    assert!(line.starts_with("could not connect"), "{line}");
    assert!(started.elapsed() >= waits.connect);
    assert!(started.elapsed() < waits.connect + LOAD_MARGIN);
    drop(listener);
}

/// A binary frame in the same read as the welcome marks the socket, and the
/// welcome is taken; a send that then fails at its deadline ends as the
/// break that the mark is, not as a lost connection that reconnects.
#[test]
fn a_failed_send_after_a_binary_frame_is_a_break() {
    let waits = Waits {
        silence: Duration::from_secs(20),
        send: Duration::from_millis(300),
        pause: Duration::ZERO,
        poll: Duration::from_millis(50),
        send_buffer: Some(SEND_BUFFER),
        ..WAITS
    };
    let (stop, stopped) = channel::<()>();
    let (server, stub) = stub::one(move |mut ws| {
        challenge(&mut ws);
        let _hello = next_text(&mut ws);
        let welcome = br#"{"type":"welcome","protocol":10}"#;
        let mut bytes = vec![0x81, welcome.len() as u8];
        bytes.extend(welcome);
        bytes.extend([0x02, 0x01, b'x']);
        use std::io::Write;
        ws.get_mut().write_all(&bytes).unwrap();
        // Reads nothing more.
        let _ = stopped.recv();
    });
    // A subscribe of 3 MB goes at the welcome, more than the socket takes.
    let (send, receive) = channel();
    send.send(Command::Follow("x".repeat(3_000_000))).unwrap();
    let shared = Mutex::new(Shared::new("tok-q4".into()));
    let started = Instant::now();
    let line = net::run_with(&server, &shared, &receive, &|| {}, waits);
    // The send failed at its deadline, not at the read of the mark.
    assert!(started.elapsed() >= waits.send, "{:?}", started.elapsed());
    stop.send(()).unwrap();
    stub.join().unwrap();
    assert_eq!(line, "the server broke the wire contract");
}

/// A send that fails keeps the frame that the socket read before it: the
/// reply to `sessions.live` came in the same read as the welcome, and the
/// window gets it before the connection ends.
#[test]
fn a_failed_send_keeps_the_frames_read_before_it() {
    let waits = Waits {
        silence: Duration::from_secs(20),
        send: Duration::from_millis(300),
        pause: Duration::ZERO,
        poll: Duration::from_millis(50),
        send_buffer: Some(SEND_BUFFER),
        ..WAITS
    };
    let (stop, stopped) = channel::<()>();
    let (server, stub) = stub::one(move |mut ws| {
        challenge(&mut ws);
        let _hello = next_text(&mut ws);
        let welcome = br#"{"type":"welcome","protocol":10}"#;
        let mut bytes = vec![0x81, welcome.len() as u8];
        bytes.extend(welcome);
        // The subscribe of the follow takes id 0 at the welcome, and
        // `sessions.live` id 1.
        let live = LIVE.replace(r#""id":"0""#, r#""id":"1""#);
        bytes.extend([0x81, 126, (live.len() >> 8) as u8, live.len() as u8]);
        bytes.extend(live.as_bytes());
        use std::io::Write;
        ws.get_mut().write_all(&bytes).unwrap();
        // Reads nothing more.
        let _ = stopped.recv();
    });
    let (send, receive) = channel();
    send.send(Command::Follow("x".repeat(3_000_000))).unwrap();
    // The window is gone: the thread ends at the end of the connection.
    drop(send);
    let shared = Mutex::new(Shared::new("tok-q4".into()));
    let line = net::run_with(&server, &shared, &receive, &|| {}, waits);
    stop.send(()).unwrap();
    stub.join().unwrap();
    assert_eq!(line, "reconnecting");
    assert_eq!(shared.lock().unwrap().live.len(), 1);
}
