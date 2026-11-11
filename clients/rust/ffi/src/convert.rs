//! The conversions of the edge: each type of the core or of the network layer
//! becomes its owned record of `types`. A reference or a lifetime stays on
//! this side of the boundary.

use crate::types as ffi;
use helyx_client_core::fold::State;
use helyx_client_core::frame::{LiveSession, SavedSession};
use helyx_client_core::message::{Ask, Block, Message, Role};
use helyx_client_core::transcript::{Row, rows};
use helyx_client_core::ui_block::Shown;
use helyx_client_net::{RequestLine, Shared};

/// The snapshot that the host receives: the state of `Shared`, with the
/// outcomes that it has not read, which the snapshot takes.
pub fn snapshot(shared: &mut Shared) -> ffi::Snapshot {
    let followed = shared.followed.clone();
    let follow_line = followed.as_deref().and_then(|session| {
        let follow = shared.client.follow(session)?;
        helyx_client_net::follow_line(session, &follow)
    });
    let session = followed
        .as_deref()
        .and_then(|session| shared.client.state(session))
        .map(state);
    ffi::Snapshot {
        line: shared.line.clone(),
        follow_line,
        followed,
        live: shared.live.iter().map(live).collect(),
        saved: shared.saved.iter().map(saved).collect(),
        saved_next: shared.saved_next.clone(),
        requests: shared.requests.iter().map(request_line).collect(),
        outcomes: std::mem::take(&mut shared.outcomes)
            .into_iter()
            .map(|(send, outcome)| ffi::Outcome {
                send,
                outcome: send_outcome(outcome),
            })
            .collect(),
        session,
    }
}

fn state(state: &State) -> ffi::SessionState {
    let asks: Vec<ffi::Ask> = state.asks.iter().map(ask).collect();
    let answering = crate::blocks::answering(&asks);
    ffi::SessionState {
        instance_id: state.instance_id.clone(),
        seq: state.seq.to_u64(),
        model: state.model.clone(),
        running: state.running,
        more: state.more,
        queue: ffi::Queue {
            steers: state.queue.steers,
            follow_ups: state.queue.follow_ups,
            running: state.queue.running,
            held: state.queue.held,
            waiting: state.queue.waiting,
        },
        notices: state.notices.clone(),
        asks,
        answering,
        rows: rows(&state.messages).into_iter().map(row).collect(),
        partial: state.partial.as_ref().map(message),
        ui_blocks: state.ui_blocks.iter().map(shown).collect(),
    }
}

pub fn live(live: &LiveSession) -> ffi::LiveSession {
    ffi::LiveSession {
        id: live.id.clone(),
        instance_id: live.instance_id.clone(),
        cwd: live.cwd.clone(),
        model: live.model.clone(),
        running: live.running,
    }
}

pub fn saved(saved: &SavedSession) -> ffi::SavedSession {
    ffi::SavedSession {
        id: saved.id.clone(),
        cwd: saved.cwd.clone(),
        model: saved.model.clone(),
        mtime: saved.mtime,
        prompt: saved.prompt.clone(),
    }
}

pub fn request_line(line: &RequestLine) -> ffi::RequestLine {
    ffi::RequestLine {
        id: line.id.clone(),
        op: line.op.to_owned(),
        label: line.label.clone(),
        state: match &line.state {
            helyx_client_net::RequestState::Pending => ffi::RequestState::Pending,
            helyx_client_net::RequestState::Ok => ffi::RequestState::Ok,
            helyx_client_net::RequestState::Error { code, text } => ffi::RequestState::Error {
                code: code.clone(),
                text: text.clone(),
            },
            helyx_client_net::RequestState::Unknown => ffi::RequestState::Unknown,
        },
        send: line.send,
    }
}

fn send_outcome(outcome: helyx_client_net::send::SendOutcome) -> ffi::SendOutcome {
    match outcome {
        helyx_client_net::send::SendOutcome::Pending => ffi::SendOutcome::Pending,
        helyx_client_net::send::SendOutcome::Ok => ffi::SendOutcome::Ok,
        helyx_client_net::send::SendOutcome::Failed(reason) => ffi::SendOutcome::Failed { reason },
    }
}

fn ask(ask: &Ask) -> ffi::Ask {
    ffi::Ask {
        ask_id: ask.ask_id.clone(),
        call_id: ask.call_id.clone(),
        tool: ask.tool.clone(),
        request: ask.request.encode(),
    }
}

fn shown(shown: &Shown) -> ffi::Shown {
    ffi::Shown {
        call_id: shown.call_id.clone(),
        key: shown.key.clone(),
        block: shown.block.encode(),
    }
}

fn row(row: Row<'_>) -> ffi::Row {
    match row {
        Row::Message(message) => ffi::Row::Message {
            message: self::message(message),
        },
        Row::Call { call, result } => ffi::Row::Call {
            call: block(call),
            result: result.map(self::message),
        },
        Row::Orphan(message) => ffi::Row::Orphan {
            message: self::message(message),
        },
    }
}

fn message(message: &Message) -> ffi::Message {
    ffi::Message {
        id: message.id.clone(),
        role: match message.role {
            Role::User => ffi::Role::User,
            Role::Assistant => ffi::Role::Assistant,
            Role::ToolResult => ffi::Role::ToolResult,
        },
        content: message.content.iter().map(block).collect(),
        model: message.model.clone(),
        stop_reason: message.stop_reason.clone(),
        tool_call_id: message.tool_call_id.clone(),
        tool_name: message.tool_name.clone(),
        is_error: message.is_error,
        ui_blocks: message.ui_blocks.iter().map(|b| b.encode()).collect(),
    }
}

fn block(block: &Block) -> ffi::Block {
    match block {
        Block::Text(text) => ffi::Block::Text { text: text.clone() },
        Block::Thinking(text) => ffi::Block::Thinking { text: text.clone() },
        Block::ToolCall {
            id,
            name,
            arguments,
        } => ffi::Block::ToolCall {
            id: id.clone(),
            name: name.clone(),
            arguments: arguments.encode(),
        },
        Block::Unknown(kind) => ffi::Block::Unknown { kind: kind.clone() },
    }
}
