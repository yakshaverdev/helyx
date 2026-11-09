//! The models of the UI block vocabulary (`docs/features/ui-blocks.md`, "The
//! vocabulary"): every UI block of the wire conformance fixtures reads as a
//! model, and the fields of each kind at their bounds.

mod common;
use common::{at, j, load};
use helyx_client_core::event::EventData;
use helyx_client_core::frame::{self, OPS, Reply, ServerFrame, Subscribed};
use helyx_client_core::json::{self, Json};
use helyx_client_core::message::{Ask, Message};
use helyx_client_core::vocabulary::{
    Approval, Choice, MAX_ARGUMENTS_BYTES, Question, UiBlock, View, head,
};
use serde_json::{Value, json};

/// The UI blocks of a valid frame of the fixtures: those of a tool result,
/// of a `ui_block` event, of a snapshot, and the request of an ask with a
/// kind, each with the name of its case.
fn blocks_of(frame: ServerFrame) -> Vec<Json> {
    let messages = |messages: &[Message]| -> Vec<Json> {
        messages.iter().flat_map(|m| m.ui_blocks.clone()).collect()
    };
    let ask = |ask: &Ask| ask.request.get("kind").map(|_| ask.request.clone());
    match frame {
        ServerFrame::Event { event, .. } => match event.data {
            Some(EventData::ToolExecutionEnd(message)) => message.ui_blocks,
            Some(EventData::UiBlock(shown)) => vec![shown.block],
            Some(EventData::Ask(a)) => ask(&a).into_iter().collect(),
            _ => vec![],
        },
        ServerFrame::Res {
            result:
                Ok(Reply::Subscribe {
                    subscribed: Subscribed::Snapshot(snapshot),
                    ..
                }),
            ..
        } => (messages(&snapshot.messages).into_iter())
            .chain(snapshot.ui_blocks.into_iter().map(|s| s.block))
            .chain(snapshot.asks.iter().filter_map(ask))
            .collect(),
        _ => vec![],
    }
}

/// Every UI block of the valid cases of `server_frames.json`, by case name.
fn fixture_blocks() -> Vec<(String, Json)> {
    let fixture = load("server_frames.json");
    let mut found = vec![];
    for section in ["res", "event"] {
        for case in at(&fixture, section).as_array().unwrap() {
            if at(case, "expect") != &Json::from("valid") {
                continue;
            }
            let op = (case.get("op").and_then(Json::as_str))
                .map(|name| *OPS.iter().find(|op| **op == name).unwrap());
            let sent = json::decode(&at(case, "frame").encode()).unwrap();
            let parsed = frame::parse(&sent, |id| op.filter(|_| id == "1")).unwrap();
            let name = at(case, "name").as_str().unwrap().to_owned();
            found.extend(blocks_of(parsed).into_iter().map(|b| (name.clone(), b)));
        }
    }
    found
}

fn read(value: Value) -> UiBlock {
    UiBlock::read(&j(&value)).unwrap()
}

#[test]
fn every_ui_block_of_the_fixtures_reads_as_a_model() {
    let found = fixture_blocks();
    assert!(found.len() >= 8, "{}", found.len());
    for (name, value) in &found {
        let block = UiBlock::read(value).unwrap_or_else(|b| panic!("{name}: {b:?}"));
        assert_eq!(
            Some(block.kind.as_str()),
            value.get("kind").unwrap().as_str()
        );
        assert_eq!(
            Some(block.text.as_str()),
            value.get("text").unwrap().as_str()
        );
        assert_eq!(block.cut, value.get("cut") == Some(&Json::Bool(true)));
    }
    // Each kind of the document draws natively, any other kind as its text.
    let view = |case: &str| {
        let (_, value) = found.iter().find(|(name, _)| name == case).unwrap();
        UiBlock::read(value).unwrap().view
    };
    let View::Form(form) = view("ask: a request of the kind form") else {
        panic!()
    };
    assert_eq!(
        form.questions,
        [Question {
            question: "Which?".into(),
            header: "Pick".into(),
            multi_select: false,
            options: vec![
                Choice {
                    label: "a".into(),
                    description: "".into()
                },
                Choice {
                    label: "b".into(),
                    description: "the other".into()
                },
            ],
        }]
    );
    assert_eq!(
        view("ask: a request of the kind approval"),
        View::Approval(Approval {
            tool: "bash".into(),
            provider: None,
            arguments: r#"{"command":"ls"}"#.into(),
        })
    );
    for case in [
        "ask: a form whose fields a client cannot read, which shows its text",
        "ui_block of a call",
        "ui_block of the turn, of a kind that the client does not know",
        "tool_execution_end: a result with UI blocks",
        "subscribe: a snapshot with the UI blocks of a call and of the turn",
    ] {
        assert!(
            found
                .iter()
                .filter(|(name, _)| name == case)
                .all(|(_, value)| UiBlock::read(value).unwrap().view == View::Text),
            "{case}"
        );
    }
}

#[test]
fn a_value_that_fails_the_envelope_is_not_a_ui_block() {
    for value in [
        json!("form"),
        json!({"kind": "form"}),
        json!({"kind": "Form", "text": ""}),
        json!({"kind": "form", "text": "", "cut": "yes"}),
    ] {
        assert!(UiBlock::read(&j(&value)).is_err(), "{value}");
    }
    let cut = read(json!({"kind": "future_kind", "text": "x", "cut": true}));
    assert!(cut.cut && cut.view == View::Text);
}

fn question(question: &str, header: &str, options: Value) -> Value {
    json!({"question": question, "header": header, "multi_select": true, "options": options})
}

fn options(n: usize) -> Value {
    (0..n)
        .map(|i| json!({"label": format!("o{i}"), "description": ""}))
        .collect()
}

fn form(questions: Value) -> View {
    read(json!({"kind": "form", "text": "q", "questions": questions})).view
}

#[test]
fn a_form_reads_within_the_bounds_of_its_fields() {
    let ok = question("q", "h", options(2));
    let is_form = |questions: Value| matches!(form(questions), View::Form(_));
    // 1 to 4 questions.
    assert!(!is_form(json!([])));
    assert!(is_form(json!([ok, ok, ok, ok])));
    assert!(!is_form(json!([ok, ok, ok, ok, ok])));
    assert!(!is_form(json!("q")));
    // A question of 1 to 1,000 bytes, multibyte too.
    assert!(!is_form(json!([question("", "h", options(2))])));
    assert!(is_form(json!([question(
        &"é".repeat(500),
        "h",
        options(2)
    )])));
    assert!(!is_form(json!([question(
        &format!("{}a", "é".repeat(500)),
        "h",
        options(2)
    )])));
    // A header of 1 to 12 code points, not bytes.
    assert!(!is_form(json!([question("q", "", options(2))])));
    assert!(is_form(json!([question("q", &"é".repeat(12), options(2))])));
    assert!(!is_form(json!([question(
        "q",
        &"é".repeat(13),
        options(2)
    )])));
    // 2 to 4 options.
    assert!(!is_form(json!([question("q", "h", options(1))])));
    assert!(is_form(json!([question("q", "h", options(4))])));
    assert!(!is_form(json!([question("q", "h", options(5))])));
    // A label of 1 to 60 bytes, unique; a description of at most 300 bytes.
    let option =
        |label: &str, description: &str| json!({"label": label, "description": description});
    let with = |a: Value, b: Value| json!([question("q", "h", json!([a, b]))]);
    assert!(is_form(with(option(&"l".repeat(60), ""), option("b", ""))));
    assert!(!is_form(with(option(&"l".repeat(61), ""), option("b", ""))));
    assert!(!is_form(with(option("", ""), option("b", ""))));
    assert!(!is_form(with(option("a", ""), option("a", "other"))));
    assert!(is_form(with(
        option("a", &"d".repeat(300)),
        option("b", "")
    )));
    assert!(!is_form(with(
        option("a", &"d".repeat(301)),
        option("b", "")
    )));
    assert!(!is_form(with(json!({"label": "a"}), option("b", ""))));
    // `multi_select`: absent is a single pick; a value is a boolean.
    let mut single = question("q", "h", options(2));
    single.as_object_mut().unwrap().remove("multi_select");
    let View::Form(read) = form(json!([single])) else {
        panic!()
    };
    assert!(!read.questions[0].multi_select);
    single["multi_select"] = Value::Null;
    assert!(!is_form(json!([single])));
}

#[test]
fn an_approval_reads_its_fields_and_draws_at_most_the_arguments_bound() {
    let approval = |fields: Value| {
        let mut block = json!({"kind": "approval", "text": "allow bash?"});
        block
            .as_object_mut()
            .unwrap()
            .extend(fields.as_object().unwrap().clone());
        read(block).view
    };
    let View::Approval(of) = approval(json!({"tool": "t", "provider": "p", "arguments": "{}"}))
    else {
        panic!()
    };
    assert_eq!(of.provider.as_deref(), Some("p"));
    assert!(matches!(
        approval(json!({"tool": "t", "arguments": "{}"})),
        View::Approval(Approval { provider: None, .. })
    ));
    for unreadable in [
        json!({"arguments": "{}"}),
        json!({"tool": "t"}),
        json!({"tool": "t", "arguments": {}}),
        json!({"tool": "t", "provider": 1, "arguments": "{}"}),
    ] {
        assert_eq!(approval(unreadable.clone()), View::Text, "{unreadable}");
    }
}

#[test]
fn a_drawn_text_keeps_its_head_within_the_bound() {
    let shown = |text: String| {
        let (kept, more) = head(&text, MAX_ARGUMENTS_BYTES);
        (kept.len(), more)
    };
    // At the bound, one over it, and characters of 2 to 4 bytes across it.
    assert_eq!(
        shown("a".repeat(MAX_ARGUMENTS_BYTES)),
        (MAX_ARGUMENTS_BYTES, false)
    );
    assert_eq!(
        shown("a".repeat(MAX_ARGUMENTS_BYTES + 1)),
        (MAX_ARGUMENTS_BYTES, true)
    );
    for wide in ["é", "€", "𝄞"] {
        for before in 1..wide.len() {
            let across = format!("{}{wide}", "a".repeat(MAX_ARGUMENTS_BYTES - before));
            assert_eq!(shown(across), (MAX_ARGUMENTS_BYTES - before, true));
        }
    }
    assert_eq!(head("", 0), ("", false));
}

#[test]
fn an_ask_draws_the_block_of_its_request_only_when_it_has_a_kind() {
    let ask = |request: Value| {
        Ask::parse(&j(
            &json!({"ask_id": "k1", "call_id": "c1", "tool": "question", "request": request}),
        ))
        .unwrap()
    };
    assert_eq!(ask(json!({"questions": []})).block(), None);
    let block = ask(json!({"kind": "future_kind", "text": "pick one"}))
        .block()
        .unwrap();
    assert_eq!((block.text.as_str(), block.view), ("pick one", View::Text));
}
