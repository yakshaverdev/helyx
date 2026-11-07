//! The wire client of one server, with no I/O (`docs/features/client-kit.md`,
//! slice 3). The host opens a WebSocket, calls `connect`, gives each text
//! frame to `receive`, sends each frame that the client returns, and calls
//! `closed` when the socket ends. A session keeps its state and the intent of
//! the host (`follow`) across connections; its live subscription and its
//! subscribe in flight are read from the connection. After each input, the
//! client reconciles the two (`reconcile`).

use crate::check::{Broken, Checked};
use crate::connection::{Connection, Decoded, Hold, Request};
use crate::fold::{State, ack};
use crate::follow::Session;
use crate::frame::{self, Reply, ServerFrame, Subscribed};
use crate::handshake::{Step, Token};
use crate::json::{self, Json, Limits};
use crate::reconcile::subscribe_fits;
use std::collections::HashMap;

pub use crate::connection::{MAX_IN_FLIGHT, Refusal};

/// What the client tells the host.
#[derive(Debug, Clone, PartialEq)]
pub enum Output {
    /// Send this text frame.
    Send(String),
    /// The server took the handshake: requests may go.
    Welcome,
    /// The server speaks another protocol: the client must update.
    Refused(u64),
    /// The reply to a request that the host made with `request`.
    Reply {
        id: String,
        result: Result<Reply, (String, String)>,
    },
    /// The state of this session changed.
    Changed(String),
    /// The session ended; its state stays, and unless it renews, no subscribe
    /// for it goes on this connection until the host states its intent again.
    Ended { session: String, crashed: bool },
    /// The server answered a request that reconciles the intent of the
    /// host for `session` (`op` is `subscribe` or `unsubscribe`) with this
    /// error. The intent stays as the host stated it; `Client::subscribed`
    /// gives whether a subscription lives. The client sends no request for
    /// the session on this connection until the host states it again.
    Failed {
        session: String,
        op: &'static str,
        code: String,
        text: String,
    },
}

/// What the host does after a close.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Next {
    /// Open a new connection: it subscribes again with `after`.
    Reconnect,
    /// Stop: the connection never took the handshake, or ended by a break or
    /// a refusal. Reconnecting would meet the same end.
    Stop,
}

#[derive(Debug)]
pub struct Client {
    token: Option<Token>,
    limits: Limits,
    pub(crate) sessions: HashMap<String, Session>,
    pub(crate) connection: Option<Connection>,
}

impl Client {
    /// A client that proves `token` at each handshake, or sends no proof.
    pub fn new(token: Option<String>) -> Client {
        Client::with_limits(token, json::WIRE)
    }

    /// A client with other decode bounds, for tests.
    pub fn with_limits(token: Option<String>, limits: Limits) -> Client {
        Client {
            token: token.map(Token::new),
            limits,
            sessions: HashMap::new(),
            connection: None,
        }
    }

    /// The state of `session`, when the client has followed it.
    pub fn state(&self, session: &str) -> Option<&State> {
        self.sessions.get(session).map(|s| &s.state)
    }

    /// Drops the state of `session` when the client does not follow it and
    /// has no subscription or subscribe of it on the way. Gives whether it
    /// dropped one.
    pub fn forget(&mut self, session: &str) -> bool {
        let idle =
            self.sessions.get(session).is_some_and(|s| !s.wanted()) && !self.attached(session);
        if idle {
            self.sessions.remove(session);
            if let Some(c) = self.connection.as_mut() {
                c.held.remove(session);
            }
        }
        idle
    }

    /// Starts a new connection: the host has opened the socket.
    pub fn connect(&mut self) {
        self.connection = Some(Connection::new(self.token.clone()));
    }

    /// The socket ended, with its close code or none for a lost connection.
    /// Any code reconnects after a welcome, `4408` (the slow end) too.
    pub fn closed(&mut self, _code: Option<u16>) -> Next {
        match self.connection.take() {
            Some(c) if c.ready() => Next::Reconnect,
            _ => Next::Stop,
        }
    }

    /// The host follows `session`: the frames that reconcile it, a
    /// subscribe with `after` when the client holds a state of it. With no
    /// room now (before a welcome, while 16 requests wait, or while its old
    /// subscription ends), the subscribe goes at a later input. At most 16
    /// sessions are followed, the subscriptions of one connection.
    pub fn subscribe(&mut self, session: &str) -> Result<Vec<String>, Refusal> {
        let wanted = self.sessions.get(session).is_some_and(Session::wanted);
        if !wanted && self.sessions.values().filter(|s| s.wanted()).count() >= MAX_IN_FLIGHT {
            return Err(Refusal::TooManySubscriptions);
        }
        if !subscribe_fits(session) {
            return Err(Refusal::TooLarge);
        }
        self.sessions.entry(session.to_owned()).or_default().want();
        Ok(self.restate(session))
    }

    /// The host stops following `session`: the frames that reconcile it, an
    /// `unsubscribe` of its live subscription, at once or when its subscribe
    /// in flight has its reply.
    pub fn unsubscribe(&mut self, session: &str) -> Vec<String> {
        match self.sessions.get_mut(session) {
            Some(s) => {
                s.unwant();
                self.restate(session)
            }
            None => vec![],
        }
    }

    /// Whether a subscription of `session` lives on the connection.
    pub fn subscribed(&self, session: &str) -> bool {
        self.live_sub(session).is_some()
    }

    /// A request of `op` with `params`: its id and its frames. Use
    /// `subscribe` and `unsubscribe` for a subscription.
    pub fn request(
        &mut self,
        op: &'static str,
        params: Json,
    ) -> Result<(String, Vec<String>), Refusal> {
        if matches!(op, "subscribe" | "unsubscribe") {
            return Err(Refusal::Subscription);
        }
        let session = params
            .get("session")
            .and_then(Json::as_str)
            .map(str::to_owned);
        self.send(op, params, session, None)
    }

    pub(crate) fn send(
        &mut self,
        op: &'static str,
        params: Json,
        session: Option<String>,
        sub: Option<String>,
    ) -> Result<(String, Vec<String>), Refusal> {
        let instance = params
            .get("instance_id")
            .and_then(Json::as_str)
            .map(str::to_owned);
        let c = self.connection.as_mut().ok_or(Refusal::NotReady)?;
        c.request(
            op,
            params,
            Request {
                op,
                session,
                sub,
                instance,
            },
        )
    }

    fn live_sub(&self, session: &str) -> Option<String> {
        self.connection.as_ref()?.live_sub(session)
    }

    fn attached(&self, session: &str) -> bool {
        self.connection
            .as_ref()
            .is_some_and(|c| c.attached(session))
    }

    /// Takes one text frame of the server. A break marks the connection
    /// broken: the host closes it, and `closed` gives `Stop`.
    pub fn receive(&mut self, text: &str) -> Checked<Vec<Output>> {
        let result = self.take(text);
        match (result, self.connection.as_mut()) {
            (Err(broken), Some(c)) => {
                c.broken = true;
                Err(broken)
            }
            (Err(broken), None) => Err(broken),
            (Ok(mut outputs), _) => {
                outputs.extend(self.pump().into_iter().map(Output::Send));
                Ok(outputs)
            }
        }
    }

    fn take(&mut self, text: &str) -> Checked<Vec<Output>> {
        let limits = self.limits;
        let c = self
            .connection
            .as_mut()
            .filter(|c| !c.broken)
            .ok_or(Broken("no connection"))?;
        match c.decode(text, limits)? {
            Decoded::Handshake(value) => self.handshake(&value),
            Decoded::Frame(value) => self.frame(&value),
            Decoded::Pending => Ok(vec![]),
        }
    }

    fn handshake(&mut self, value: &Json) -> Checked<Vec<Output>> {
        let c = self.connection.as_mut().expect("a connection");
        match c.handshake.step(value)? {
            Step::Send(hello) => Ok(vec![Output::Send(hello.encode())]),
            Step::Refused(n) => {
                c.broken = true;
                Ok(vec![Output::Refused(n)])
            }
            Step::Welcome => {
                c.welcomed = true;
                Ok(vec![Output::Welcome])
            }
        }
    }

    fn frame(&mut self, value: &Json) -> Checked<Vec<Output>> {
        let c = self.connection.as_mut().expect("a connection");
        let requests = &c.requests;
        match frame::parse(value, |id| requests.get(id).map(|r| r.op))? {
            ServerFrame::Res { id, result } => {
                let request = c.requests.remove(&id).expect("parse found the request");
                self.reply(id, request, result)
            }
            ServerFrame::Event { sub, .. } | ServerFrame::SessionEnd { sub, .. }
                if c.gone.contains(&sub) =>
            {
                Ok(vec![])
            }
            ServerFrame::Event { sub, event } => {
                let session = c
                    .subs
                    .get(&sub)
                    .ok_or(Broken("event of no subscription"))?
                    .clone();
                // `forget` keeps the state of a session with a live sub.
                let state = &mut self
                    .sessions
                    .get_mut(&session)
                    .expect("a subscribed session")
                    .state;
                let from = state.seq;
                state.apply(event)?;
                let mut outputs = ack_output(&sub, from, state.seq);
                outputs.push(Output::Changed(session));
                Ok(outputs)
            }
            ServerFrame::SessionEnd { sub, crashed } => {
                let session = c
                    .subs
                    .remove(&sub)
                    .ok_or(Broken("end of no subscription"))?;
                let s = self
                    .sessions
                    .get_mut(&session)
                    .expect("a subscribed session");
                // The session stopped: a subscribe would find none, so the
                // following is held until the host states it again, unless
                // the session started again (a renewal). A `Refused` hold
                // stays as it is.
                if s.ended() {
                    c.held.entry(session.clone()).or_insert(Hold::Ended);
                }
                Ok(vec![Output::Ended { session, crashed }])
            }
        }
    }

    fn reply(
        &mut self,
        id: String,
        request: Request,
        result: Result<Reply, (String, String)>,
    ) -> Checked<Vec<Output>> {
        let c = self.connection.as_mut().expect("a connection");
        match (request.op, request.session, result) {
            ("subscribe", Some(session), Ok(Reply::Subscribe { sub, subscribed })) => {
                // A sub id is unique on the connection, a gone one too.
                if c.subs.contains_key(&sub) || c.gone.contains(&sub) {
                    return Err(Broken("subscribe sub"));
                }
                // `forget` keeps the state of a session with a subscribe on the way.
                let s = self
                    .sessions
                    .get_mut(&session)
                    .expect("a session with a subscribe");
                s.subscribed();
                let snapshot = matches!(subscribed, Subscribed::Snapshot(_));
                let from = s.state.seq;
                s.state.subscribed(subscribed)?;
                // A snapshot is the credit base of the server: no ack for it.
                let from = if snapshot { s.state.seq } else { from };
                let mut outputs = ack_output(&sub, from, s.state.seq);
                c.subs.insert(sub, session.clone());
                outputs.push(Output::Changed(session));
                Ok(outputs)
            }
            ("subscribe", Some(session), Err((code, text))) => {
                c.held.insert(session.clone(), Hold::Refused);
                Ok(vec![Output::Failed {
                    session,
                    op: "subscribe",
                    code,
                    text,
                }])
            }
            // `reconcile::Client::unsubscribed`.
            ("unsubscribe", session, result) => {
                let sub = request.sub.expect("an unsubscribe names its sub");
                let session = session.expect("an unsubscribe names its session");
                Ok(self.unsubscribed(session, sub, result))
            }
            // The session started again (`follow::Session::instance_changed`).
            ("history", Some(session), Err((code, text))) if code == "instance_changed" => {
                // A renewal ends the hold of an ended subscription.
                let renews = self
                    .sessions
                    .get_mut(&session)
                    .is_some_and(|s| s.instance_changed(request.instance.as_deref()));
                if renews && c.held.get(&session) == Some(&Hold::Ended) {
                    c.held.remove(&session);
                }
                Ok(vec![Output::Reply {
                    id,
                    result: Err((code, text)),
                }])
            }
            (_, _, result) => Ok(vec![Output::Reply { id, result }]),
        }
    }
}

fn ack_output(sub: &str, from: u64, to: u64) -> Vec<Output> {
    ack(sub, from, to)
        .map(|frame| Output::Send(frame.encode()))
        .into_iter()
        .collect()
}
