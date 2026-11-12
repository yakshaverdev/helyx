//! The number of a send that a host waits for the outcome of, and what became
//! of it. A send of a composer, or the answer of an ask, takes one number; the
//! network layer reports one outcome for it, and the host settles the send.

/// The number of a send whose outcome the host waits for: a send of the
/// composer, or the answer of an ask.
pub type SendId = u64;

/// What became of a send that the host numbered, from the line of its request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendOutcome {
    /// The client took it: the request waits for its reply.
    Pending,
    /// The server answered `ok`.
    Ok,
    /// The client refused it before it went, the server answered an error, or
    /// the reply was lost. A composer send keeps its text, and an ask shows
    /// again; the request line names the reason. The text is the reason, for
    /// the host's line.
    Failed(String),
}
