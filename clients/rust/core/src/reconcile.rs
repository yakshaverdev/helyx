//! The reconciling of the intent of the host with the subscriptions of the
//! connection (`docs/features/client-kit.md`, slice 3): after each input,
//! the client sends the requests that bring each session that is not held
//! to what the host stated. A hold is derived from the answers of the
//! server (`Connection::hold`), so a new statement of the host ends it.

use crate::client::{Client, Output};
use crate::connection::{MAX_IN_FLIGHT, Refusal, Stop};
use crate::fold::State;
use crate::frame::Reply;
use crate::json::object;
use crate::parts::REQUEST_BYTES;

impl Client {
    /// The requests that reconcile each session that is not held and has no
    /// subscribe or `unsubscribe` in flight, in the byte order of the session
    /// ids, while there is room: a subscribe for a wanted session with no
    /// subscription, while the subscriptions of the connection and the
    /// subscribes in flight are under 16, and an `unsubscribe` for an
    /// unwanted one with a live subscription. So a session has at most one
    /// such request in flight, and is not subscribed while a subscription of
    /// it lives: two never feed one state.
    pub(crate) fn pump(&mut self) -> Vec<String> {
        // No welcome yet: nothing can go.
        let Some(c) = self.connection.as_ref().filter(|c| c.ready()) else {
            return vec![];
        };
        let mut due: Vec<(String, Option<String>, u64)> = vec![];
        for (id, s) in &self.sessions {
            let stated = s.stated();
            if c.hold(id, stated).is_some() || c.in_flight(id, &["subscribe", "unsubscribe"]) {
                continue;
            }
            match (s.wanted(), c.live_sub(id)) {
                (true, None) => due.push((id.clone(), None, stated)),
                (false, Some(sub)) => due.push((id.clone(), Some(sub), stated)),
                _ => {}
            }
        }
        due.sort();
        let mut outputs = vec![];
        for (session, sub, stated) in due {
            let sent = match sub {
                Some(sub) => {
                    let params = object([("sub", sub.as_str().into())]);
                    self.send(
                        "unsubscribe",
                        params,
                        Some(session.clone()),
                        Some(sub),
                        Some(stated),
                    )
                }
                // The server holds at most 16 subscriptions of a connection.
                None if self
                    .connection
                    .as_ref()
                    .is_some_and(|c| c.subscriptions() >= MAX_IN_FLIGHT) =>
                {
                    continue;
                }
                None => self.send_subscribe(&session, stated),
            };
            match sent {
                Ok((_, frames)) => outputs.extend(frames),
                // A sub id of the server over the request size, which no
                // request can carry: held with no report (`subscribe`
                // refuses a session id that is).
                Err(Refusal::TooLarge) => {
                    let c = self.connection.as_mut().expect("a connection");
                    c.stop(session, Stop::Refused, stated);
                }
                // No free place: a later input.
                Err(_) => break,
            }
        }
        outputs
    }

    /// The reply to an `unsubscribe` of `sub` of `session`, sent for the
    /// statement `stated` of the host. `ok` ends the sub; with `unknown_sub`
    /// the server holds it no more (`Connection::gone`); another error leaves
    /// it live, as far as the client knows (`Client::refused`).
    pub(crate) fn unsubscribed(
        &mut self,
        session: String,
        sub: String,
        stated: u64,
        result: Result<Reply, (String, String)>,
    ) -> Vec<Output> {
        match result {
            Err((code, text)) if code != "unknown_sub" => {
                self.refused(session, "unsubscribe", (code, text), stated)
            }
            ended => {
                // A server never gives a sub id again on a connection.
                let c = self.connection.as_mut().expect("a connection");
                if c.subs.remove(&sub).is_some() && ended.is_err() {
                    c.gone.insert(sub);
                }
                vec![]
            }
        }
    }

    /// An error answer to a subscribe or an `unsubscribe` that reconciles
    /// `session` for the statement `stated`. It holds the session and is
    /// told to the host only while it answers the last statement of the
    /// host: an answer to an older one, or of a session that the host
    /// forgot, says nothing of what the host wants now.
    pub(crate) fn refused(
        &mut self,
        session: String,
        op: &'static str,
        (code, text): (String, String),
        stated: u64,
    ) -> Vec<Output> {
        if self.sessions.get(&session).map(|s| s.stated()) != Some(stated) {
            return vec![];
        }
        let c = self.connection.as_mut().expect("a connection");
        c.stop(session.clone(), Stop::Refused, stated);
        vec![Output::Failed {
            session,
            op,
            code,
            text,
        }]
    }

    fn send_subscribe(
        &mut self,
        session: &str,
        stated: u64,
    ) -> Result<(String, Vec<String>), Refusal> {
        let params = self.sessions[session].state.subscribe_params(session);
        let stated = Some(stated);
        match self.send("subscribe", params, Some(session.to_owned()), None, stated) {
            // An `after` whose `instance_id` takes the frame over the request
            // size: a subscribe with no `after` gets a snapshot.
            Err(Refusal::TooLarge) => {
                let params = State::default().subscribe_params(session);
                self.send("subscribe", params, Some(session.to_owned()), None, stated)
            }
            sent => sent,
        }
    }
}

/// Whether a subscribe of `session` with no `after` fits a request, with the
/// longest request id of a connection.
pub(crate) fn subscribe_fits(session: &str) -> bool {
    let longest = object([
        ("type", "req".into()),
        ("id", u64::MAX.to_string().as_str().into()),
        ("op", "subscribe".into()),
        ("params", State::default().subscribe_params(session)),
    ]);
    longest.encode().len() <= REQUEST_BYTES
}
