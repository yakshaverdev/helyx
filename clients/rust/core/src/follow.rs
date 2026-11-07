//! The intent of the host to follow one session, and the state of it
//! (`docs/features/client-kit.md`, slice 3). The intent is what the host
//! stated, and only the host changes it; the live subscription and the
//! requests in flight are read from the connection, and the client
//! reconciles the two after each input.

use crate::fold::State;

#[derive(Debug, Default)]
pub(crate) struct Session {
    pub state: State,
    /// The host follows the session: from `subscribe` to `unsubscribe`.
    wanted: bool,
    /// A `history` page of the instance of the state got `instance_changed`:
    /// the session started again, so the `session_end` of that instance
    /// does not hold the following. The next subscribe reply ends it.
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

    /// `unsubscribe` of the host.
    pub fn unwant(&mut self) {
        self.wanted = false;
        self.renew = false;
    }

    /// A subscribe reply took effect.
    pub fn subscribed(&mut self) {
        self.renew = false;
    }

    /// The `session_end` of its subscription: gives whether the following is
    /// held until the host states it again, as it is unless renewed.
    pub fn ended(&mut self) -> bool {
        !std::mem::take(&mut self.renew)
    }

    /// `instance_changed` of a `history` page of `instance`: gives whether
    /// it renews, as it does for a wanted session whose state is of
    /// `instance`.
    pub fn instance_changed(&mut self, instance: Option<&str>) -> bool {
        let renews =
            self.wanted && instance.is_some() && self.state.instance_id.as_deref() == instance;
        self.renew |= renews;
        renews
    }
}
