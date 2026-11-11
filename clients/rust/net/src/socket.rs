//! The guards of one socket of the network layer (`docs/features/
//! client-kit.md`, "The network layer"): the waits, the watchdog that holds
//! the deadlines of the socket, and the tap that reads the header of each
//! frame of the server.

use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// The waits of a connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Waits {
    /// The TCP connect.
    pub connect: Duration,
    /// The upgrade and the wait for `welcome`, in all: the auth wait of the
    /// server (`docs/features/wire-protocol.md`, "Bounds").
    pub welcome: Duration,
    /// A server that is gone: no inbound frame for this long after the
    /// welcome. The server pings every 15,000 ms and ends a silent client
    /// at 45,000 ms; the app does the same.
    pub silence: Duration,
    /// Each batch of frames that the app sends.
    pub send: Duration,
    /// The pause before a reconnect.
    pub pause: Duration,
    /// How often the thread takes the commands of the window, and the
    /// watchdog checks its deadlines.
    pub poll: Duration,
}

/// The waits of the app.
pub const WAITS: Waits = Waits {
    connect: Duration::from_millis(5_000),
    welcome: Duration::from_millis(5_000),
    silence: Duration::from_millis(45_000),
    send: Duration::from_millis(5_000),
    pause: Duration::from_millis(1_000),
    poll: Duration::from_millis(100),
};

/// No deadline.
const NONE: u64 = u64::MAX;

/// The watchdogs whose thread runs, for the test of their end.
static LIVE: AtomicUsize = AtomicUsize::new(0);

/// The watchdogs whose thread runs.
#[doc(hidden)]
pub fn live_watchdogs() -> usize {
    LIVE.load(Ordering::SeqCst)
}

/// The deadlines of one socket, as instants in milliseconds from its start:
/// the read deadline, which only a message read moves, and the deadline of a
/// batch of sends. A thread checks them every `poll` and shuts the socket
/// down when one has passed, whatever read or write is in progress; it ends
/// then, or within `poll` of the drop of the `Watchdog`. It sends no close
/// frame: a write of the app can be in progress on the socket, and a frame
/// in its middle would break the stream.
pub(crate) struct Watchdog {
    start: Instant,
    read_at: Arc<AtomicU64>,
    send_at: Arc<AtomicU64>,
    fired: Arc<AtomicBool>,
    done: Arc<AtomicBool>,
}

impl Watchdog {
    /// A watchdog of `stream` whose read deadline is `wait` from now.
    pub fn start(stream: &TcpStream, wait: Duration, poll: Duration) -> std::io::Result<Watchdog> {
        let watched = stream.try_clone()?;
        let start = Instant::now();
        let read_at = Arc::new(AtomicU64::new(wait.as_millis() as u64));
        let send_at = Arc::new(AtomicU64::new(NONE));
        let fired = Arc::new(AtomicBool::new(false));
        let done = Arc::new(AtomicBool::new(false));
        let (r, s, f, d) = (
            read_at.clone(),
            send_at.clone(),
            fired.clone(),
            done.clone(),
        );
        LIVE.fetch_add(1, Ordering::SeqCst);
        std::thread::spawn(move || {
            while !d.load(Ordering::SeqCst) {
                let now = start.elapsed().as_millis() as u64;
                if now > r.load(Ordering::SeqCst) || now > s.load(Ordering::SeqCst) {
                    f.store(true, Ordering::SeqCst);
                    let _ = watched.shutdown(Shutdown::Both);
                    break;
                }
                std::thread::sleep(poll);
            }
            LIVE.fetch_sub(1, Ordering::SeqCst);
        });
        Ok(Watchdog {
            start,
            read_at,
            send_at,
            fired,
            done,
        })
    }

    fn at(&self, wait: Duration) -> u64 {
        (self.start.elapsed() + wait).as_millis() as u64
    }

    /// A message was read: the read deadline is `wait` from now.
    pub fn heard(&self, wait: Duration) {
        self.read_at.store(self.at(wait), Ordering::SeqCst);
    }

    /// A batch of sends starts, to end within `wait`.
    pub fn sending(&self, wait: Duration) {
        self.send_at.store(self.at(wait), Ordering::SeqCst);
    }

    /// The batch of sends ended.
    pub fn sent(&self) {
        self.send_at.store(NONE, Ordering::SeqCst);
    }

    /// The watchdog shut the socket down.
    pub fn fired(&self) -> bool {
        self.fired.load(Ordering::SeqCst)
    }
}

impl Drop for Watchdog {
    fn drop(&mut self) {
        self.done.store(true, Ordering::SeqCst);
    }
}

/// The socket of a connection, with a tap on the bytes that the server
/// sends: it finds the end of the HTTP reply of the upgrade by the rules of
/// the parser of `tungstenite` (a line ends at `\n`, with or without `\r`,
/// and empty lines before the status line are skipped), then reads the
/// header of each frame. At the header of a binary frame it gives only the
/// bytes before it, and every later read fails: the schema has text frames
/// only, and the read returns before the WebSocket joins the fragments.
///
/// After the upgrade, a write that fails, a timeout too, is kept: the tap
/// gives `WouldBlock` in its place, which the read of `tungstenite` takes for
/// a pong that waits, so it still gives the frames that it read before, and
/// every later read of the tap fails at once. So the frames that
/// `tungstenite` read before a failed write reach the client, and the
/// connection then ends with no wait on a dead socket.
pub(crate) struct Tap<S = TcpStream> {
    stream: S,
    /// Until the end of the HTTP reply: whether its status line came, and
    /// whether the current line has a byte other than `\r`.
    http: Option<(bool, bool)>,
    header: Vec<u8>,
    /// The payload bytes of the frame that are still to come.
    skip: u64,
    binary: bool,
    write_failed: bool,
}

impl<S> Tap<S> {
    pub fn new(stream: S) -> Tap<S> {
        Tap {
            stream,
            http: Some((false, false)),
            header: Vec::with_capacity(14),
            skip: 0,
            binary: false,
            write_failed: false,
        }
    }

    /// A write failed: the connection ends at the next read of the socket.
    pub fn write_failed(&self) -> bool {
        self.write_failed
    }

    /// `write` to the stream, unless a write failed before: after the HTTP
    /// reply of the upgrade, keeps a failed write and gives `WouldBlock` in
    /// its place. During the upgrade the error goes on as it is: the
    /// handshake of `tungstenite` would take `WouldBlock` for a write to try
    /// again, with no end.
    fn kept<T>(&mut self, write: impl FnOnce(&mut S) -> std::io::Result<T>) -> std::io::Result<T> {
        if self.write_failed {
            return Err(std::io::ErrorKind::WouldBlock.into());
        }
        let upgraded = self.http.is_none();
        write(&mut self.stream).map_err(|error| match upgraded {
            true => {
                self.write_failed = true;
                std::io::ErrorKind::WouldBlock.into()
            }
            false => error,
        })
    }

    /// The server sent a binary frame.
    pub fn binary(&self) -> bool {
        self.binary
    }

    fn take(&mut self, byte: u8) {
        if let Some((status, line)) = self.http.as_mut() {
            match byte {
                b'\n' if !*line && *status => self.http = None,
                b'\n' => {
                    *status |= *line;
                    *line = false;
                }
                b'\r' => {}
                _ => *line = true,
            }
            return;
        }
        self.header.push(byte);
        // The opcode is in the first byte of a header.
        if self.header.len() == 1 && byte & 0x0f == 0x2 {
            self.binary = true;
            return;
        }
        let [_, second, ..] = self.header[..] else {
            return;
        };
        let extended = match second & 0x7f {
            126 => 2,
            127 => 8,
            _ => 0,
        };
        let masked = if second & 0x80 != 0 { 4 } else { 0 };
        if self.header.len() < 2 + extended + masked {
            return;
        }
        self.skip = match extended {
            0 => u64::from(second & 0x7f),
            _ => self.header[2..2 + extended]
                .iter()
                .fold(0, |n, b| n << 8 | u64::from(*b)),
        };
        self.header.clear();
    }
}

impl<S: Read> Read for Tap<S> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let binary = || std::io::Error::other("a binary frame");
        if self.binary {
            return Err(binary());
        }
        if self.write_failed {
            return Err(std::io::Error::other("a write failed"));
        }
        let n = self.stream.read(buf)?;
        let (mut at, mut start) = (0, 0);
        while at < n {
            if self.skip > 0 {
                // The payload of a frame, passed over in one step.
                let skipped = self.skip.min((n - at) as u64);
                self.skip -= skipped;
                at += skipped as usize;
                continue;
            }
            if self.http.is_none() && self.header.is_empty() {
                start = at;
            }
            self.take(buf[at]);
            at += 1;
            if self.binary {
                // Only the bytes before the binary frame go on.
                return if start > 0 { Ok(start) } else { Err(binary()) };
            }
        }
        Ok(n)
    }
}

impl<S: Write> Write for Tap<S> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.kept(|stream| stream.write(buf))
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.kept(S::flush)
    }
}

#[cfg(test)]
mod tests {
    use super::Tap;
    use std::io::{Cursor, Read, Write};
    use tungstenite::protocol::Role;
    use tungstenite::{Message, WebSocket};

    /// A socket that gives one chunk for each read and fails each write.
    struct NoWrite(Vec<Vec<u8>>);

    impl Read for NoWrite {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            match self.0.first_mut() {
                None => Ok(0),
                Some(chunk) => {
                    let n = chunk.len().min(buf.len());
                    buf[..n].copy_from_slice(&chunk[..n]);
                    chunk.drain(..n);
                    if chunk.is_empty() {
                        self.0.remove(0);
                    }
                    Ok(n)
                }
            }
        }
    }

    impl Write for NoWrite {
        fn write(&mut self, _buf: &[u8]) -> std::io::Result<usize> {
            Err(std::io::ErrorKind::BrokenPipe.into())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// `tungstenite` sends the pong of a ping at the start of the next read:
    /// a pong that fails keeps the text frame that came with the ping, and
    /// the next read of the tap fails, though the socket has more.
    #[test]
    fn a_failed_pong_keeps_the_frames_read_before_it() {
        let first = vec![0x89, 0x00, 0x81, 0x02, b'h', b'i'];
        let later = vec![0x81, 0x02, b'z', b'z'];
        let tap = Tap {
            http: None,
            ..Tap::new(NoWrite(vec![first, later]))
        };
        let mut ws = WebSocket::from_raw_socket(tap, Role::Client, None);
        assert_eq!(ws.read().unwrap(), Message::Ping(vec![].into()));
        // The pong goes at the start of this read, and fails.
        assert_eq!(ws.read().unwrap(), Message::text("hi"));
        assert!(ws.get_ref().write_failed());
        let Err(tungstenite::Error::Io(error)) = ws.read() else {
            panic!("a read after a failed write")
        };
        assert_eq!(error.to_string(), "a write failed");
        assert_eq!(ws.get_ref().stream.0.len(), 1);
    }

    /// During the upgrade a failed write goes on as it is, so the handshake
    /// fails, and does not try again with no end.
    #[test]
    fn a_failed_write_of_the_upgrade_ends_it() {
        let tap = Tap::new(NoWrite(vec![]));
        let handshake = tungstenite::client::client("ws://127.0.0.1:1/", tap);
        assert!(matches!(
            handshake,
            Err(tungstenite::HandshakeError::Failure(
                tungstenite::Error::Io(_)
            ))
        ));
    }

    /// The bytes that `tap` gives for `input`, read `chunk` bytes at a time,
    /// and whether it marked a binary frame.
    fn through(input: &[u8], chunk: usize) -> (Vec<u8>, bool) {
        let mut tap = Tap::new(Cursor::new(input.to_vec()));
        let (mut out, mut buf) = (vec![], vec![0; chunk]);
        loop {
            match tap.read(&mut buf) {
                Ok(0) | Err(_) => return (out, tap.binary()),
                Ok(n) => out.extend_from_slice(&buf[..n]),
            }
        }
    }

    fn text(len: usize) -> Vec<u8> {
        let mut frame = vec![0x81];
        match len {
            0..=125 => frame.push(len as u8),
            126..=65_535 => frame.extend([126, (len >> 8) as u8, len as u8]),
            _ => {
                frame.push(127);
                frame.extend((len as u64).to_be_bytes());
            }
        }
        // A payload of bytes that read as a binary header if misread.
        frame.extend(std::iter::repeat_n(0x82, len));
        frame
    }

    #[test]
    fn a_binary_frame_is_marked_and_the_bytes_before_it_go_on() {
        let replies: [&[u8]; 3] = [
            b"HTTP/1.1 101 OK\r\nUpgrade: websocket\r\n\r\n",
            b"HTTP/1.1 101 OK\nUpgrade: websocket\n\n",
            b"\r\n\r\nHTTP/1.1 101 OK\r\nX-P: ~zz\r\n\r\n",
        ];
        // A binary frame that is not final, and one that is.
        for (reply, first) in replies.into_iter().zip([0x02, 0x82, 0x02]) {
            for len in [0, 5, 125, 126, 300, 65_535, 65_536, 70_000] {
                let mut input = reply.to_vec();
                let before = input.len() + text(len).len();
                input.extend(text(len));
                input.extend([first, 0x01, b'x']);
                input.extend(text(3));
                for chunk in [1, 2, 3, 7, 4_096, 200_000] {
                    let (out, binary) = through(&input, chunk);
                    assert!(binary, "{len} {chunk}");
                    assert_eq!(out, input[..before], "{len} {chunk}");
                }
            }
        }
    }

    #[test]
    fn text_frames_are_not_marked() {
        let mut input = b"HTTP/1.1 101 OK\r\n\r\n".to_vec();
        for len in [0, 125, 126, 65_536] {
            input.extend(text(len));
        }
        // A ping with a payload, a continuation of a text, and a masked
        // text whose mask and payload read as binary headers if misread.
        input.extend([0x89, 0x02, 0x82, 0x82, 0x01, 0x01, b'a', 0x80, 0x01, b'b']);
        input.extend([0x81, 0x81, 0x82, 0x82, 0x82, 0x82, 0x82]);
        for chunk in [1, 5, 4_096] {
            assert_eq!(through(&input, chunk), (input.clone(), false), "{chunk}");
        }
    }
}
