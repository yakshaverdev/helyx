//! Runs `test/fixtures/wire/records.json` against the records fold of the
//! client core (`docs/features/live-records.md`): the reply, the `record` and
//! `records` frames, and the folds. A frame is decoded by the decoder of the
//! core, so an integer keeps its digits.

use helyx_client_core::frame::{self, Reply, ServerFrame};
use helyx_client_core::json::{self, Json, object};
use helyx_client_core::records::{self, Feed, Record, RecordFrame, Status};

mod common;
use common::{at, load, matches};

fn text(value: &Json) -> &str {
    value.as_str().unwrap()
}

/// `value` as the server sends it: its text, decoded as a frame.
fn decode(value: &Json) -> Json {
    json::decode(&value.encode()).unwrap()
}

fn status(status: Status) -> &'static str {
    match status {
        Status::Idle => "idle",
        Status::Running => "running",
        Status::Waiting => "waiting",
        Status::Stopped => "stopped",
    }
}

/// The state of the feed in the shape of an `expect` of the fixture.
fn observe(feed: &Feed) -> Json {
    let strings = |items: Vec<&str>| Json::Array(items.into_iter().map(Json::from).collect());

    object([
        (
            "rows",
            strings(feed.rows().iter().map(|row| row.session.as_str()).collect()),
        ),
        (
            "statuses",
            strings(feed.rows().iter().map(|row| status(row.status)).collect()),
        ),
        ("more", Json::Bool(feed.more())),
        ("ended", Json::Bool(feed.ended())),
    ])
}

fn apply(feed: &mut Feed, parsed: ServerFrame) {
    match parsed {
        ServerFrame::Record(RecordFrame::Change(change)) => feed.applied(change),
        ServerFrame::Record(RecordFrame::Full { records, more }) => feed.full(records, more),
        ServerFrame::RecordsEnd => feed.end(),
        other => panic!("{other:?}"),
    }
}

#[test]
fn reply() {
    for case in at(&load("records.json"), "reply").as_array().unwrap() {
        let name = text(at(case, "name"));
        let parsed = frame::parse(&decode(at(case, "frame")), |_| Some("records.subscribe"));
        let expect = at(case, "expect");

        match (parsed, expect) {
            (Err(_), Json::String(what)) => assert!(what == "broken", "{name}"),
            (Err(broken), _) => panic!("{name}: {broken:?}"),
            (Ok(ServerFrame::Res { result, .. }), Json::Object(_)) => {
                let Ok(Reply::Records { records, more }) = result else {
                    panic!("{name}: {result:?}")
                };
                let held = observe(&Feed::subscribed(records, more));
                assert!(matches(expect, &held), "{name}: {}", held.encode());
            }
            (Ok(other), _) => panic!("{name}: {other:?}"),
        }
    }
}

#[test]
fn frames() {
    for case in at(&load("records.json"), "frames").as_array().unwrap() {
        let name = text(at(case, "name"));
        let mut feed = match case.get("start") {
            Some(start) => {
                let records = (start.as_array().unwrap().iter())
                    .map(|value| records::parse_record(&decode(value)).unwrap())
                    .collect();
                Feed::subscribed(records, false)
            }
            None => Feed::default(),
        };
        let expect = at(case, "expect");

        if let Json::String(what) = expect {
            assert!(what == "broken", "{name}");
            assert!(
                frame::parse(&decode(at(case, "frame")), |_| None).is_err(),
                "{name}"
            );
            continue;
        }

        let parsed = frame::parse(&decode(at(case, "frame")), |_| None)
            .unwrap_or_else(|broken| panic!("{name}: {broken:?}"));
        apply(&mut feed, parsed);
        let held = observe(&feed);
        assert!(matches(expect, &held), "{name}: {}", held.encode());
    }
}

#[test]
fn folds() {
    for case in at(&load("records.json"), "folds").as_array().unwrap() {
        let name = text(at(case, "name"));
        let mut feed = Feed::default();
        let mut in_flight: Option<(String, &'static str)> = None;

        for step in at(case, "steps").as_array().unwrap() {
            if let Some(request) = step.get("client") {
                assert_eq!(text(at(request, "op")), "records.subscribe", "{name}");
                let params = at(request, "params");
                let sent = Json::Object(vec![]);
                assert!(matches(params, &sent), "{name}: {}", params.encode());
                in_flight = Some((text(at(request, "id")).to_owned(), "records.subscribe"));
            } else if let Some(server) = step.get("server") {
                let parsed = frame::parse(&decode(server), |id| {
                    in_flight
                        .as_ref()
                        .filter(|(request, _)| request == id)
                        .map(|(_, op)| *op)
                })
                .unwrap_or_else(|broken| panic!("{name}: {broken:?}"));

                match parsed {
                    ServerFrame::Res {
                        result: Ok(Reply::Records { records, more }),
                        ..
                    } => {
                        feed = Feed::subscribed(records, more);
                        in_flight = None;
                    }
                    other => apply(&mut feed, other),
                }
            } else if let Some(expect) = step.get("expect") {
                let held = observe(&feed);
                assert!(matches(expect, &held), "{name}: {}", held.encode());
            } else {
                assert!(step.get("close").is_some(), "{name}: {}", step.encode());
            }
        }
    }
}

fn record(session: &str, status: Status, active_at: u64) -> Record {
    Record {
        session: session.into(),
        owner: records::User {
            id: "u1".into(),
            name: "ada".into(),
        },
        project: None,
        title: String::new(),
        labels: vec![],
        visibility: records::Visibility::Private,
        archived: false,
        created_at: 1,
        updated_at: 1,
        cwd: "/tmp".into(),
        model: "fake/echo".into(),
        prompt: String::new(),
        active_at,
        parent: None,
        status,
    }
}

#[test]
fn the_fold_stays_at_its_bound() {
    let max = records::MAX_ROWS;

    // A stopped record leaves before an idle one.
    let mut rows: Vec<Record> = (0..max)
        .map(|n| record(&format!("i{n}"), Status::Idle, n as u64 + 1))
        .collect();
    rows.push(record("s0", Status::Stopped, 0));
    let feed = Feed::subscribed(rows, false);
    assert_eq!(feed.rows().len(), max);
    assert!(!feed.rows().iter().any(|row| row.session == "s0"));

    // With no stopped record, the oldest record that does not wait leaves.
    let mut rows: Vec<Record> = (0..max)
        .map(|n| record(&format!("i{n}"), Status::Idle, n as u64 + 1))
        .collect();
    rows.push(record("old", Status::Idle, 0));
    let feed = Feed::subscribed(rows, false);
    assert_eq!(feed.rows().len(), max);
    assert!(!feed.rows().iter().any(|row| row.session == "old"));

    // A waiting record stays while another can leave.
    let mut rows: Vec<Record> = (0..max)
        .map(|n| record(&format!("i{n}"), Status::Idle, n as u64 + 1))
        .collect();
    rows.push(record("waits", Status::Waiting, 0));
    let feed = Feed::subscribed(rows, false);
    assert_eq!(feed.rows().len(), max);
    assert!(feed.rows().iter().any(|row| row.session == "waits"));
}
