//! The object that the bindings expose: the network thread of one server, the
//! operations that the desktop app sends, and the callback that the host
//! implements (`docs/features/client-kit.md`, "Bindings for Swift").

use crate::convert;
use crate::types::{NetError, Snapshot};
use helyx_client_core::json;
use helyx_client_core::operation::{Invalid, Operation};
use helyx_client_net::{self, Command, Server, Shared};
use std::net::IpAddr;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;

/// What the host receives on each change of the network layer: the same state
/// that the desktop window reads, as one owned snapshot.
#[uniffi::export(rust, foreign)]
pub trait NetListener: Send + Sync {
    /// A change of the connection, of a request, or of the followed session.
    /// A listener that fails does not stop the network layer: the next change
    /// calls it again.
    fn on_snapshot(&self, snapshot: Snapshot) -> Result<(), NetError>;
}

/// The network layer of one server: it starts the thread at `new` and stops it
/// at drop, which waits for the thread and thus for a connect or an upgrade
/// that it waits on (at most their waits). Each method states one intent of
/// the host; the callback reports what became of it. A method that refuses
/// its input throws `NetError`, because nothing went on the wire.
#[derive(uniffi::Object)]
pub struct Connection {
    /// The channel of the network thread; none after the drop takes it.
    commands: Mutex<Option<Sender<Command>>>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

#[uniffi::export]
impl Connection {
    /// Starts the network thread of the server at `address`:`port`, with the
    /// token of its handshake. The thread connects at once, and the callback
    /// reports the first state.
    #[uniffi::constructor]
    pub fn new(
        address: String,
        port: u16,
        token: String,
        listener: Arc<dyn NetListener>,
    ) -> Result<Arc<Connection>, NetError> {
        let address: IpAddr = address.parse().map_err(|_| NetError::Invalid {
            reason: "the address is not an IP address".to_owned(),
        })?;
        let server = Server {
            address,
            port,
            token,
        };
        let shared = Arc::new(Mutex::new(Shared::new(server.token.clone())));
        let (commands, receive) = channel();
        let thread_shared = shared.clone();
        // The callback runs on the network thread, so the host hears about a
        // change without a poll of its own.
        let notify = move || {
            let snapshot = {
                let mut shared = thread_shared.lock().unwrap_or_else(PoisonError::into_inner);
                convert::snapshot(&mut shared)
            };
            let _ = listener.on_snapshot(snapshot);
        };
        let thread = std::thread::spawn(move || {
            helyx_client_net::run(&server, &shared, &receive, &notify);
        });
        Ok(Arc::new(Connection {
            commands: Mutex::new(Some(commands)),
            thread: Mutex::new(Some(thread)),
        }))
    }

    /// Follows `session`, and stops following the one before.
    pub fn follow(&self, session: String) -> Result<(), NetError> {
        self.send(Command::Follow(session))
    }

    /// Asks the live sessions of the server now.
    pub fn live_sessions(&self) -> Result<(), NetError> {
        self.send(Command::Live)
    }

    /// Asks a page of the saved sessions; `after` is the `next` of the page
    /// before, or none for the first page.
    pub fn saved_sessions(&self, after: Option<String>) -> Result<(), NetError> {
        self.send(Command::Saved { after })
    }

    /// Starts a session in `cwd`, and follows the one that the server makes.
    pub fn start_session(&self, cwd: String) -> Result<(), NetError> {
        self.perform(Operation::start(&cwd, None))
    }

    /// Resumes the session `id`, and follows it.
    pub fn resume_session(&self, id: String) -> Result<(), NetError> {
        self.perform(Ok(Operation::resume(&id)))
    }

    /// Sends `text` as the prompt of a turn of `session`.
    pub fn prompt(&self, session: String, text: String) -> Result<(), NetError> {
        self.perform(Operation::prompt(&session, &text))
    }

    /// Sends `text` to the running turn of `session`.
    pub fn steer(&self, session: String, text: String) -> Result<(), NetError> {
        self.perform(Operation::steer(&session, &text))
    }

    /// Sends `text` to the session after its running turn.
    pub fn follow_up(&self, session: String, text: String) -> Result<(), NetError> {
        self.perform(Operation::follow_up(&session, &text))
    }

    /// Aborts the running turn of `session`.
    pub fn abort(&self, session: String) -> Result<(), NetError> {
        self.perform(Ok(Operation::abort(&session)))
    }

    /// Stops `session`: a running turn aborts first, and the session ends.
    pub fn stop(&self, session: String) -> Result<(), NetError> {
        self.perform(Ok(Operation::stop(&session)))
    }

    /// Switches `session` to `model` for its next turn. The core checks the
    /// ref before it goes.
    pub fn set_model(&self, session: String, model: String) -> Result<(), NetError> {
        self.perform(Operation::set_model(&session, &model))
    }

    /// Compacts `session` with `text` as the instructions, or with none when
    /// the text is empty.
    pub fn compact(&self, session: String, text: String) -> Result<(), NetError> {
        self.perform(Operation::compact(&session, &text))
    }

    /// Answers the ask `ask_id` of `session`. `answer` is the answer as a JSON
    /// text, which the core checks before it goes.
    pub fn answer(&self, session: String, ask_id: String, answer: String) -> Result<(), NetError> {
        let answer = json::decode(&answer).map_err(|_| NetError::Invalid {
            reason: "the answer is not JSON".to_owned(),
        })?;
        self.perform(Operation::answer(&session, &ask_id, answer))
    }

    /// Tells the network layer that the app is active again: a socket that a
    /// suspend left dead is dropped, and the connection starts again on the
    /// path of a lost connection.
    pub fn became_active(&self) -> Result<(), NetError> {
        self.send(Command::BecameActive)
    }
}

impl Connection {
    fn send(&self, command: Command) -> Result<(), NetError> {
        let commands = self.commands.lock().unwrap_or_else(PoisonError::into_inner);
        match commands.as_ref() {
            Some(sender) => sender.send(command).map_err(|_| NetError::Stopped),
            None => Err(NetError::Stopped),
        }
    }

    fn perform(&self, operation: Result<Operation, Invalid>) -> Result<(), NetError> {
        let operation = operation.map_err(|invalid| NetError::Invalid {
            reason: invalid.text().to_owned(),
        })?;
        self.send(Command::Operation {
            send: None,
            operation,
        })
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        // The wake-up ends the connection as a lost connection does, and the
        // channel that the drop closes keeps the thread from opening another:
        // the socket of the host closes within the poll of a read.
        let sender = self
            .commands
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(sender) = sender {
            helyx_client_net::became_active(&sender);
        }
        let thread = self
            .thread
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(thread) = thread {
            let _ = thread.join();
        }
    }
}
