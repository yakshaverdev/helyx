//! The intent of the host to follow one session, and the state of it
//! (`docs/features/client-kit.md`, slice 3). The intent is the one stored
//! fact of a subscription; its live sub and its subscribe in flight are read
//! from the connection.

use crate::fold::State;

#[derive(Debug, Default)]
pub(crate) struct Session {
    pub state: State,
    /// The host follows the session: from `subscribe` to `unsubscribe`, a
    /// refused subscribe, or a `session_end` with no renewal.
    wanted: bool,
    /// A `history` page of the instance of the state got `instance_changed`:
    /// the session started again, so the `session_end` of that instance
    /// keeps it wanted. The next subscribe reply ends it.
    renew: bool,
}

impl Session {
    pub fn wanted(&self) -> bool {
        self.wanted
    }

    /// `subscribe` of the host.
    pub fn want(&mut self) {
        self.wanted = true;
    }

    /// `unsubscribe` of the host, or a refused subscribe.
    pub fn drop_intent(&mut self) {
        self.wanted = false;
        self.renew = false;
    }

    /// A subscribe reply took effect.
    pub fn subscribed(&mut self) {
        self.renew = false;
    }

    /// The `session_end` of the last subscription of the session, which the
    /// host did not unsubscribe: it stays wanted only by a renewal.
    pub fn ended(&mut self) {
        self.wanted = std::mem::take(&mut self.renew);
    }

    /// `instance_changed` of a `history` page of `instance`: a renewal when
    /// the session is wanted and `instance` is that of its state.
    pub fn instance_changed(&mut self, instance: Option<&str>) {
        if self.wanted && instance.is_some() && self.state.instance_id.as_deref() == instance {
            self.renew = true;
        }
    }
}
