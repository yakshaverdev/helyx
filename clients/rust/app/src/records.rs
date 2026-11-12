//! The texts of the rows of the records feed (`docs/features/client-kit.md`,
//! slice 4): a row of the left column from a `Record` and the rows that the
//! feed holds. The module holds no GPUI, so the iOS app can use the same
//! texts, and a test needs no window.

use helyx_client_core::frame::SavedSession;
use helyx_client_core::records::{Record, Status};
use helyx_client_core::vocabulary::head;
use helyx_client_net::MAX_PROMPT_BYTES;

/// The texts of one row of the feed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowText {
    /// The title, the first line of the prompt cut as the saved list cuts
    /// it, or the session id.
    pub title: String,
    /// The last part of the folder, the model, and the status as a word.
    pub detail: String,
    /// `child of <the parent>` when the record has a parent.
    pub parent: Option<String>,
    /// Whether the row waits for the user, which takes a color of its own.
    pub waiting: bool,
}

/// The texts of `record`. `rows` is the whole feed, which names a parent.
pub fn texts(record: &Record, rows: &[Record]) -> RowText {
    RowText {
        title: title(record),
        detail: format!(
            "{} · {} · {}",
            folder(&record.cwd),
            record.model,
            status(record.status)
        ),
        parent: record
            .parent
            .as_ref()
            .map(|parent| format!("child of {}", parent_name(&parent.session, rows))),
        waiting: record.status == Status::Waiting,
    }
}

/// The saved sessions that the feed does not hold: a session shows in one
/// list only.
pub fn saved_only<'a>(saved: &'a [SavedSession], rows: &[Record]) -> Vec<&'a SavedSession> {
    (saved.iter())
        .filter(|session| !rows.iter().any(|row| row.session == session.id))
        .collect()
}

/// The status as the wire and the window say it.
pub fn status(status: Status) -> &'static str {
    match status {
        Status::Idle => "idle",
        Status::Running => "running",
        Status::Waiting => "waiting",
        Status::Stopped => "stopped",
    }
}

fn title(record: &Record) -> String {
    if !record.title.is_empty() {
        return record.title.clone();
    }
    let prompt = first_line(&record.prompt, MAX_PROMPT_BYTES);
    if prompt.is_empty() {
        record.session.clone()
    } else {
        prompt
    }
}

fn parent_name(session: &str, rows: &[Record]) -> String {
    rows.iter()
        .find(|row| row.session == session)
        .map_or_else(|| session.to_owned(), title)
}

/// The last part of the folder path; the whole path for a root or an empty
/// one.
fn folder(cwd: &str) -> String {
    match std::path::Path::new(cwd).file_name() {
        Some(name) if !name.is_empty() => name.to_string_lossy().into_owned(),
        _ => cwd.to_owned(),
    }
}

/// The first line of `text`, cut to `max` bytes, as the saved list cuts a
/// prompt.
fn first_line(text: &str, max: usize) -> String {
    let line = (text.split(['\n', '\r'])).next().unwrap_or("");
    head(line, max).0.to_owned()
}

#[cfg(test)]
mod tests {
    use super::{saved_only, texts};
    use helyx_client_core::frame::SavedSession;
    use helyx_client_core::records::{Parent, ParentKind, Record, Status, User, Visibility};

    fn record(session: &str, title: &str, prompt: &str, cwd: &str, status: Status) -> Record {
        Record {
            session: session.into(),
            owner: User {
                id: "u1".into(),
                name: "ada".into(),
            },
            project: None,
            title: title.into(),
            labels: vec![],
            visibility: Visibility::Private,
            archived: false,
            created_at: 1,
            updated_at: 1,
            cwd: cwd.into(),
            model: "fake/echo".into(),
            prompt: prompt.into(),
            active_at: 1,
            parent: None,
            status,
        }
    }

    fn saved(id: &str) -> SavedSession {
        SavedSession {
            id: id.into(),
            cwd: "/r".into(),
            model: "fake/echo".into(),
            mtime: 1,
            prompt: "a prompt".into(),
        }
    }

    #[test]
    fn the_title_then_the_prompt_then_the_id() {
        let titled = record("s1", "fix the build", "ignored", "/r", Status::Idle);
        assert_eq!(texts(&titled, &[]).title, "fix the build");

        let prompted = record("s2", "", "one\ntwo", "/r", Status::Idle);
        assert_eq!(texts(&prompted, &[]).title, "one");

        let cut = format!("{}émore", "a".repeat(199));
        let long = record("s3", "", &cut, "/r", Status::Idle);
        let title = texts(&long, &[]).title;
        assert_eq!(title, "a".repeat(199));
        assert!(title.is_char_boundary(title.len()));

        let bare = record("s4", "", "", "/r", Status::Idle);
        assert_eq!(texts(&bare, &[]).title, "s4");
    }

    #[test]
    fn the_row_takes_the_last_part_of_the_folder() {
        let nested = record("s1", "t", "", "/home/ada/src/helyx", Status::Idle);
        assert_eq!(texts(&nested, &[]).detail, "helyx · fake/echo · idle");
        let root = record("s2", "t", "", "/", Status::Idle);
        assert_eq!(texts(&root, &[]).detail, "/ · fake/echo · idle");
    }

    #[test]
    fn each_status_has_its_word() {
        for (status, word) in [
            (Status::Idle, "idle"),
            (Status::Running, "running"),
            (Status::Waiting, "waiting"),
            (Status::Stopped, "stopped"),
        ] {
            let row = record("s1", "t", "", "/r", status);
            let texts = texts(&row, &[]);
            assert!(texts.detail.ends_with(&format!("· {word}")));
            assert_eq!(texts.waiting, status == Status::Waiting);
        }
    }

    #[test]
    fn a_parent_line_names_the_parent_in_the_rows_or_its_id() {
        let parent = record("p1", "the parent", "", "/r", Status::Idle);
        let mut child = record("c1", "the child", "", "/r", Status::Idle);
        child.parent = Some(Parent {
            session: "p1".into(),
            kind: ParentKind::Child,
        });
        assert_eq!(
            texts(&child, &[parent.clone(), child.clone()]).parent,
            Some("child of the parent".into())
        );
        assert_eq!(
            texts(&child, &[child.clone()]).parent,
            Some("child of p1".into())
        );
        // A parent with no title falls back to its prompt, then its id.
        let bare = record("p2", "", "the prompt", "/r", Status::Idle);
        let mut child = record("c2", "", "", "/r", Status::Idle);
        child.parent = Some(Parent {
            session: "p2".into(),
            kind: ParentKind::Thread,
        });
        assert_eq!(
            texts(&child, &[bare]).parent,
            Some("child of the prompt".into())
        );
    }

    #[test]
    fn the_saved_list_leaves_out_a_session_of_the_feed() {
        let saved = [saved("a"), saved("b")];
        let rows = [record("b", "t", "", "/r", Status::Idle)];
        let shown = saved_only(&saved, &rows);
        assert_eq!(shown.len(), 1);
        assert_eq!(shown[0].id, "a");
        assert_eq!(saved_only(&saved, &[]).len(), 2);
    }
}
