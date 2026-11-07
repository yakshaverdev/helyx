//! The reconciling of the intent of the host with the subscriptions of the
//! connection (`docs/features/client-kit.md`, slice 3): after each input,
//! the client sends the requests that bring each session that is not held
//! to what the host stated.

use crate::client::{Client, Output};
use crate::connection::{Hold, MAX_IN_FLIGHT, Refusal};
use crate::fold::State;
use crate::frame::Reply;
use crate::json::object;
use crate::parts::REQUEST_BYTES;

impl Client {
    /// The host stated its intent for `session`: a hold of it ends.
    pub(crate) fn restate(&mut self, session: &str) -> Vec<String> {
        if let Some(c) = self.connection.as_mut() {
            c.held.remove(session);
        }
        self.pump()
    }

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
        let mut due: Vec<(String, Option<String>)> = vec![];
        for (id, s) in &self.sessions {
            if c.held.contains_key(id) || c.in_flight(id, &["subscribe", "unsubscribe"]) {
                continue;
            }
            match (s.wanted(), c.live_sub(id)) {
                (true, None) => due.push((id.clone(), None)),
                (false, Some(sub)) => due.push((id.clone(), Some(sub))),
                _ => {}
            }
        }
        due.sort();
        let mut outputs = vec![];
        for (session, sub) in due {
            let sent = match sub {
                Some(sub) => {
                    let params = object([("sub", sub.as_str().into())]);
                    self.send("unsubscribe", params, Some(session.clone()), Some(sub))
                }
                // The server holds at most 16 subscriptions of a connection.
                None if self
                    .connection
                    .as_ref()
                    .is_some_and(|c| c.subscriptions() >= MAX_IN_FLIGHT) =>
                {
                    continue;
                }
                None => self.send_subscribe(&session),
            };
            match sent {
                Ok((_, frames)) => outputs.extend(frames),
                // A sub id of the server over the request size, which no
                // request can carry: held with no report (`subscribe`
                // refuses a session id that is).
                Err(Refusal::TooLarge) => {
                    let c = self.connection.as_mut().expect("a connection");
                    c.held.insert(session, Hold::Refused);
                }
                // No free place: a later input.
                Err(_) => break,
            }
        }
        outputs
    }

    /// The reply to an `unsubscribe` of `sub` of `session`. It acts on the
    /// sub only while the sub is still that of the session. `ok` ends it;
    /// with `unknown_sub` the server holds it no more (`Connection::gone`);
    /// another error leaves it live, as far as the client knows: the host is
    /// told, and the session is held, a forgotten one excepted.
    pub(crate) fn unsubscribed(
        &mut self,
        session: String,
        sub: String,
        result: Result<Reply, (String, String)>,
    ) -> Vec<Output> {
        let c = self.connection.as_mut().expect("a connection");
        match result {
            Err((code, text)) if code != "unknown_sub" => {
                if self.sessions.contains_key(&session) {
                    c.held.insert(session.clone(), Hold::Refused);
                }
                vec![Output::Failed {
                    session,
                    op: "unsubscribe",
                    code,
                    text,
                }]
            }
            ended => {
                if c.subs.get(&sub) == Some(&session) {
                    c.subs.remove(&sub);
                    if ended.is_err() {
                        c.gone.insert(sub);
                    }
                }
                vec![]
            }
        }
    }

    fn send_subscribe(&mut self, session: &str) -> Result<(String, Vec<String>), Refusal> {
        let params = self.sessions[session].state.subscribe_params(session);
        match self.send("subscribe", params, Some(session.to_owned()), None) {
            // An `after` whose `instance_id` takes the frame over the request
            // size: a subscribe with no `after` gets a snapshot.
            Err(Refusal::TooLarge) => {
                let params = State::default().subscribe_params(session);
                self.send("subscribe", params, Some(session.to_owned()), None)
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
