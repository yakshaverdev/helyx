//! The types that cross the bindings to Swift (`docs/features/client-kit.md`,
//! "Bindings for Swift"). UniFFI cannot pass a reference or a lifetime, so
//! each type here is owned: it is a copy of a type of the core or of the
//! network layer, made at the edge (`convert`).

/// Why a call of the bindings did nothing.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum NetError {
    /// The host gave an input that the server does not take, so nothing goes
    /// on the wire.
    Invalid { reason: String },
    /// The network thread has stopped: its command channel is gone.
    Stopped,
    /// The listener of the host failed on a change.
    Listener { reason: String },
}

impl std::fmt::Display for NetError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NetError::Invalid { reason } => write!(f, "{reason}"),
            NetError::Stopped => write!(f, "the connection has stopped"),
            NetError::Listener { reason } => write!(f, "the listener failed: {reason}"),
        }
    }
}

impl std::error::Error for NetError {}

impl From<uniffi::UnexpectedUniFFICallbackError> for NetError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> NetError {
        NetError::Listener {
            reason: error.reason,
        }
    }
}

/// What the host receives on each change of the network layer: the state that
/// the desktop window draws from (`Shared`), as owned values.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Snapshot {
    /// The state of the connection, for a person.
    pub line: String,
    /// The line of the followed session when it waits for a place or ended.
    pub follow_line: Option<String>,
    /// The session that the host follows.
    pub followed: Option<String>,
    /// The live sessions of the server, from `sessions.live` on a server with
    /// no Hub.
    pub live: Vec<LiveSession>,
    /// The records of the user's feed, in the order of the server: waiting
    /// first, then the newest activity, then the session id. The list of a
    /// server with a Hub.
    pub records: Vec<Record>,
    /// Whether the user owns more records than `records` holds.
    pub records_more: bool,
    /// Whether the connection has a records feed: false on a server with no
    /// Hub, whose list is `live`.
    pub records_feed: bool,
    /// The saved sessions, newest first.
    pub saved: Vec<SavedSession>,
    /// The `next` of the last page of saved sessions, when more exist.
    pub saved_next: Option<String>,
    /// The requests of the host, oldest first.
    pub requests: Vec<RequestLine>,
    /// The outcome of each numbered send since the snapshot before.
    pub outcomes: Vec<Outcome>,
    /// The folded state of the followed session, when the client holds it.
    pub session: Option<SessionState>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LiveSession {
    pub id: String,
    pub instance_id: String,
    pub cwd: String,
    pub model: String,
    pub running: bool,
}

/// One record of the user's feed, as the sidebar shows it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Record {
    pub session: String,
    pub title: String,
    /// The first prompt of the session, uncut: a host cuts it for its row.
    pub prompt: String,
    pub cwd: String,
    pub model: String,
    pub status: Status,
    /// The session of the parent, when the record has one.
    pub parent: Option<String>,
    /// The last activity, as the server counts it.
    pub active_at: u64,
}

/// The derived status of a record: `waiting` while the session has an open
/// ask, else the status of its live session, or `stopped`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Status {
    Idle,
    Running,
    Waiting,
    Stopped,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SavedSession {
    pub id: String,
    pub cwd: String,
    pub model: String,
    pub mtime: u64,
    pub prompt: String,
}

/// One request of the host, as its status line shows it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RequestLine {
    pub id: String,
    /// The op of the request, such as `prompt`.
    pub op: String,
    /// The op and a short text, for a person.
    pub label: String,
    pub state: RequestState,
    /// The number of the send that this request is, when the host waits for
    /// its outcome.
    pub send: Option<u64>,
}

/// The state of one request of the host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RequestState {
    /// Sent, and the server has not answered.
    Pending,
    /// The server answered `ok`.
    Ok,
    /// The server answered with this error, or the client refused the request
    /// before it went, which `not sent` says as its code.
    Error { code: String, text: String },
    /// The connection ended before the reply: the result is unknown, and the
    /// user decides whether to send it again.
    Unknown,
}

/// The outcome of a send that the host numbered.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SendOutcome {
    /// The client took it: the request waits for its reply.
    Pending,
    /// The server answered `ok`.
    Ok,
    /// The client refused it, the server answered an error, or the reply was
    /// lost. The reason is for the host's line.
    Failed { reason: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Outcome {
    pub send: u64,
    pub outcome: SendOutcome,
}

/// The folded state of the followed session, as the desktop window draws it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SessionState {
    /// The instance of the last snapshot.
    pub instance_id: Option<String>,
    /// The `seq` of the last event applied, when it fits 64 bits.
    pub seq: Option<u64>,
    pub model: String,
    /// True from a snapshot with a turn or a `turn_start`, until a `turn_end`.
    pub running: bool,
    /// True when the server holds older messages than the tail.
    pub more: bool,
    pub queue: Queue,
    /// The notices and turn errors, for a person, oldest first.
    pub notices: Vec<String>,
    /// The open asks, oldest first.
    pub asks: Vec<Ask>,
    /// The transcript rows, oldest first, with each tool result paired to its
    /// call.
    pub rows: Vec<Row>,
    /// The assistant message that streams now.
    pub partial: Option<Message>,
    /// The UI blocks that the session shows, in their order.
    pub ui_blocks: Vec<Shown>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
pub struct Queue {
    pub steers: u64,
    pub follow_ups: u64,
    pub running: u64,
    pub held: u64,
    pub waiting: u64,
}

/// An ask of the session: a question of a tool, with its request.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Ask {
    pub ask_id: String,
    pub call_id: String,
    pub tool: String,
    /// The request of the ask, as a JSON text.
    pub request: String,
}

/// A UI block that the session shows: of a tool call, or of the turn when
/// `call_id` is none.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Shown {
    pub call_id: Option<String>,
    pub key: String,
    /// The block, as a JSON text: a kind of the client shows its `text`.
    pub block: String,
}

/// One row of the transcript.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum Row {
    /// A user or an assistant message.
    Message { message: Message },
    /// A tool call of the assistant message before it, with its result when
    /// the result came.
    Call {
        call: Block,
        result: Option<Message>,
    },
    /// A tool result with no open call of its id, or with no call id.
    Orphan { message: Message },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Message {
    pub id: String,
    pub role: Role,
    pub content: Vec<Block>,
    pub model: Option<String>,
    pub stop_reason: Option<String>,
    pub tool_call_id: Option<String>,
    pub tool_name: Option<String>,
    pub is_error: bool,
    /// The UI blocks of a tool result, each as a JSON text.
    pub ui_blocks: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Role {
    User,
    Assistant,
    ToolResult,
}

/// A block of a message.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum Block {
    Text {
        text: String,
    },
    Thinking {
        text: String,
    },
    ToolCall {
        id: String,
        name: String,
        /// The arguments of the call, as a JSON text.
        arguments: String,
    },
    /// A block kind that this client does not know, which a renderer shows as
    /// a placeholder with its kind.
    Unknown {
        kind: String,
    },
}
