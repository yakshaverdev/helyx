//! The records feed of a user (`docs/features/live-records.md`): the reply of
//! `records.subscribe`, the `record` and `records` frames, and the ordered
//! rows that a view shows. The list holds the sessions that wait for the user
//! first, then the newest activity, then the session id; a change replaces a
//! row in place, and a full list replaces the whole state.

use crate::check::{
    Broken, Checked, boolean, field, id, int_key, list_of, object, one_of, string, string_or_null,
    strings,
};
use crate::json::Json;

/// The rows that the feed keeps. A change past the bound drops the oldest
/// stopped row, then the oldest row that does not wait
/// (`test/fixtures/wire/bounds.json`, `record_rows`).
pub const MAX_ROWS: usize = 1_024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct User {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Visibility {
    Private,
    Hub,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParentKind {
    Child,
    Thread,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parent {
    pub session: String,
    pub kind: ParentKind,
}

/// The derived status of a record: `"waiting"` while the session has an open
/// ask, else the status of its live session, or `"stopped"`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Idle,
    Running,
    Waiting,
    Stopped,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub session: String,
    pub owner: User,
    pub project: Option<String>,
    pub title: String,
    pub labels: Vec<String>,
    pub visibility: Visibility,
    pub archived: bool,
    pub created_at: u64,
    pub updated_at: u64,
    pub cwd: String,
    pub model: String,
    pub prompt: String,
    pub active_at: u64,
    pub parent: Option<Parent>,
    pub status: Status,
}

/// One change of a record: its new value, or its removal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    Changed(Box<Record>),
    Removed(String),
}

/// A frame after the `records.subscribe` reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecordFrame {
    Change(Change),
    /// The full list that a slow subscriber gets in place of its changes.
    Full {
        records: Vec<Record>,
        more: bool,
    },
}

/// The ordered rows of the feed, whether the server holds more, and whether
/// the subscription ended on the server.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Feed {
    rows: Vec<Record>,
    more: bool,
    ended: bool,
}

impl Feed {
    /// The reply of `records.subscribe` replaces the list.
    pub fn subscribed(records: Vec<Record>, more: bool) -> Feed {
        let mut feed = Feed {
            rows: records,
            more,
            ended: false,
        };
        feed.order();
        feed.trim();
        feed
    }

    /// A change: a new or changed record replaces its row, and a removal drops
    /// it. The order holds again after it.
    pub fn applied(&mut self, change: Change) {
        match change {
            Change::Changed(record) => match self.row(&record.session) {
                Some(index) => self.rows[index] = *record,
                None => self.rows.push(*record),
            },
            Change::Removed(session) => self.rows.retain(|row| row.session != session),
        }
        self.order();
        self.trim();
    }

    /// The full list that a slow subscriber gets: it replaces the state.
    pub fn full(&mut self, records: Vec<Record>, more: bool) {
        *self = Feed::subscribed(records, more);
    }

    /// The ordered rows: waiting first, then `active_at` newest first, then
    /// the session id.
    pub fn rows(&self) -> &[Record] {
        &self.rows
    }

    /// Whether the server holds more records than the page that it sent.
    pub fn more(&self) -> bool {
        self.more
    }

    /// Whether the subscription ended on the server: the rows are stale, and
    /// the host subscribes again.
    pub fn ended(&self) -> bool {
        self.ended
    }

    /// The server ended the subscription without the client's unsubscribe.
    pub fn end(&mut self) {
        self.ended = true;
    }

    fn row(&self, session: &str) -> Option<usize> {
        self.rows.iter().position(|row| row.session == session)
    }

    fn order(&mut self) {
        let rank = |row: &Record| u8::from(row.status != Status::Waiting);
        self.rows.sort_by(|a, b| {
            rank(a)
                .cmp(&rank(b))
                .then(b.active_at.cmp(&a.active_at))
                .then(a.session.cmp(&b.session))
        });
    }

    fn trim(&mut self) {
        while self.rows.len() > MAX_ROWS {
            let victim = self
                .rows
                .iter()
                .rposition(|row| row.status == Status::Stopped)
                .or_else(|| {
                    self.rows
                        .iter()
                        .rposition(|row| row.status != Status::Waiting)
                })
                .unwrap_or(self.rows.len() - 1);
            self.rows.remove(victim);
        }
    }
}

/// A `record`: its shape in `docs/features/wire-protocol.md`.
pub fn parse_record(value: &Json) -> Checked<Record> {
    let map = object(value, "record")?;

    Ok(Record {
        session: id(map, "session", "record")?.to_owned(),
        owner: parse_user(field(map, "owner", "record")?)?,
        project: string_or_null(map, "project", "record")?.map(str::to_owned),
        title: string(map, "title", "record")?.to_owned(),
        labels: strings(map, "labels", "record")?,
        visibility: match one_of(map, "visibility", &["private", "hub"], "record")? {
            "private" => Visibility::Private,
            _ => Visibility::Hub,
        },
        archived: boolean(map, "archived", "record")?,
        created_at: int_key(map, "created_at", "record")?,
        updated_at: int_key(map, "updated_at", "record")?,
        cwd: string(map, "cwd", "record")?.to_owned(),
        model: string(map, "model", "record")?.to_owned(),
        prompt: string(map, "prompt", "record")?.to_owned(),
        active_at: int_key(map, "active_at", "record")?,
        parent: parse_parent(field(map, "parent", "record")?)?,
        status: match one_of(
            map,
            "status",
            &["idle", "running", "waiting", "stopped"],
            "record",
        )? {
            "idle" => Status::Idle,
            "running" => Status::Running,
            "waiting" => Status::Waiting,
            _ => Status::Stopped,
        },
    })
}

fn parse_user(value: &Json) -> Checked<User> {
    let map = object(value, "record owner")?;

    Ok(User {
        id: id(map, "id", "record owner")?.to_owned(),
        name: string(map, "name", "record owner")?.to_owned(),
    })
}

fn parse_parent(value: &Json) -> Checked<Option<Parent>> {
    if value.is_null() {
        return Ok(None);
    }
    let map = object(value, "record parent")?;

    Ok(Some(Parent {
        session: id(map, "session", "record parent")?.to_owned(),
        kind: match one_of(map, "kind", &["child", "thread"], "record parent")? {
            "child" => ParentKind::Child,
            _ => ParentKind::Thread,
        },
    }))
}

/// A `record` or a `records` frame. A known type with a broken shape is a
/// break, and so is a type that is neither.
pub fn parse_frame(value: &Json) -> Checked<RecordFrame> {
    let map = object(value, "record frame")?;

    match string(map, "type", "record frame")? {
        "record" => {
            let change = object(field(map, "change", "record change")?, "record change")?;

            match one_of(
                change,
                "kind",
                &["new", "changed", "removed"],
                "record change",
            )? {
                "removed" => Ok(RecordFrame::Change(Change::Removed(
                    id(change, "session", "record change")?.to_owned(),
                ))),
                _ => Ok(RecordFrame::Change(Change::Changed(Box::new(
                    parse_record(field(change, "record", "record change")?)?,
                )))),
            }
        }
        "records" => Ok(RecordFrame::Full {
            records: list_of(map, "records", "records frame", parse_record)?,
            more: boolean(map, "more", "records frame")?,
        }),
        _ => Err(Broken("record frame")),
    }
}
