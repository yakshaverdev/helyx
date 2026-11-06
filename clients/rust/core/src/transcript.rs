//! The rows that a client draws from a transcript, derived on read: the
//! session pairs each tool result with its call, so the client does not
//! enforce the pairing; it shows a result with no call as an orphan
//! (`docs/features/client-kit.md`, "Pairing").

use crate::message::{Block, Message, Role};
use std::collections::{HashMap, VecDeque};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Row<'a> {
    /// A user or an assistant message.
    Message(&'a Message),
    /// A tool call of the assistant message before it, with its result when
    /// the result came.
    Call {
        call: &'a Block,
        result: Option<&'a Message>,
    },
    /// A tool result with no open call of its id, or with no call id.
    Orphan(&'a Message),
}

/// The rows of `messages`, oldest first. A result closes the oldest open
/// call of its id, as in the TUI.
pub fn rows(messages: &[Message]) -> Vec<Row<'_>> {
    let mut rows = Vec::with_capacity(messages.len());
    let mut open: HashMap<&str, VecDeque<usize>> = HashMap::new();
    for message in messages {
        match message.role {
            // Only an assistant message opens calls, as in the TUI.
            Role::User => rows.push(Row::Message(message)),
            Role::Assistant => {
                rows.push(Row::Message(message));
                for block in &message.content {
                    if let Block::ToolCall { id, .. } = block {
                        open.entry(id).or_default().push_back(rows.len());
                        rows.push(Row::Call {
                            call: block,
                            result: None,
                        });
                    }
                }
            }
            Role::ToolResult => {
                let position = message
                    .tool_call_id
                    .as_deref()
                    .and_then(|id| open.get_mut(id))
                    .and_then(VecDeque::pop_front);
                match position.map(|at| &mut rows[at]) {
                    Some(Row::Call { result, .. }) => *result = Some(message),
                    None => rows.push(Row::Orphan(message)),
                    Some(_) => unreachable!("an open call is at a call row"),
                }
            }
        }
    }
    rows
}
