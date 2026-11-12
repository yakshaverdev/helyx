//! The operations of a host (`operation`): the checks of each builder, the
//! params of the schema, the deadline of each op, the requests in flight, the
//! reply that matches one by id, and the lost reply (`docs/features/
//! client-kit.md`, slice 2).

#[allow(unused)]
mod common;

use helyx_client_core::client::{Client, Next, Output, Refusal};
use helyx_client_core::frame::Reply;
use helyx_client_core::json::{Json, decode};
use helyx_client_core::operation::{
    FormAnswer, Invalid, MAX_ANSWER_BYTES, MAX_CWD_BYTES, MAX_LIMIT, MAX_MODEL_BYTES,
    MAX_TEXT_BYTES, Operation, Saved, approval_answer, deadline, form_answer,
};
use serde_json::json;
use std::time::Duration;

const CHALLENGE: &str =
    r#"{"type":"challenge","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"#;
const WELCOME: &str = r#"{"type":"welcome","protocol":13}"#;

/// The frames that the client sends among `outputs`, decoded.
fn sent(outputs: &[Output]) -> Vec<Json> {
    outputs
        .iter()
        .filter_map(|o| match o {
            Output::Send(text) => Some(decode(text).unwrap()),
            _ => None,
        })
        .collect()
}

/// A client past the handshake of a new connection.
fn welcomed(client: &mut Client) -> Vec<Output> {
    client.connect(None);
    let hello = client.receive(CHALLENGE).unwrap();
    assert_eq!(
        sent(&hello)[0].get("type").and_then(Json::as_str),
        Some("hello")
    );
    let outputs = client.receive(WELCOME).unwrap();
    assert_eq!(outputs[0], Output::Welcome);
    outputs
}

#[test]
fn each_operation_gives_the_params_of_the_schema() {
    let cases = [
        (
            Operation::prompt("s1", "hi").unwrap(),
            "prompt",
            r#"{"session":"s1","text":"hi"}"#,
        ),
        (
            Operation::steer("s1", "hi").unwrap(),
            "steer",
            r#"{"session":"s1","text":"hi"}"#,
        ),
        (
            Operation::follow_up("s1", "hi").unwrap(),
            "follow_up",
            r#"{"session":"s1","text":"hi"}"#,
        ),
        (Operation::abort("s1"), "abort", r#"{"session":"s1"}"#),
        (Operation::stop("s1"), "stop", r#"{"session":"s1"}"#),
        (
            Operation::set_model("s1", "fake/echo").unwrap(),
            "set_model",
            r#"{"session":"s1","model":"fake/echo"}"#,
        ),
        (
            Operation::compact("s1", "trim").unwrap(),
            "compact",
            r#"{"session":"s1","text":"trim"}"#,
        ),
        (
            // An empty text sends none, so the default of the server holds.
            Operation::compact("s1", "").unwrap(),
            "compact",
            r#"{"session":"s1"}"#,
        ),
        (
            Operation::answer("s1", "a1", approval_answer(true)).unwrap(),
            "answer",
            r#"{"session":"s1","ask_id":"a1","answer":{"decision":"allow"}}"#,
        ),
        (
            Operation::start("/r", None).unwrap(),
            "start",
            r#"{"cwd":"/r"}"#,
        ),
        (
            Operation::start("/r", Some("fake/echo")).unwrap(),
            "start",
            r#"{"cwd":"/r","model":"fake/echo"}"#,
        ),
        (Operation::resume("abc"), "resume", r#"{"id":"abc"}"#),
        (
            Operation::resume_folder("/r").unwrap(),
            "resume",
            r#"{"cwd":"/r"}"#,
        ),
        (
            Operation::saved(Saved {
                cwd: Some("/r".into()),
                after: Some("c1".into()),
                limit: Some(50),
            })
            .unwrap(),
            "sessions.saved",
            r#"{"cwd":"/r","after":"c1","limit":50}"#,
        ),
        (
            Operation::saved(Saved::default()).unwrap(),
            "sessions.saved",
            "{}",
        ),
    ];
    for (operation, name, params) in cases {
        assert_eq!(operation.name(), name);
        assert_eq!(operation.params(), decode(params).unwrap(), "{name}");
    }
    // Only a session operation names a session.
    for operation in [
        Operation::abort("s1"),
        Operation::stop("s1"),
        Operation::set_model("s1", "fake/echo").unwrap(),
        Operation::compact("s1", "").unwrap(),
    ] {
        assert_eq!(operation.session(), Some("s1"), "{}", operation.name());
    }
    for other in [
        Operation::start("/r", None).unwrap(),
        Operation::resume("abc"),
        Operation::resume_folder("/r").unwrap(),
        Operation::saved(Saved::default()).unwrap(),
    ] {
        assert_eq!(other.session(), None, "{}", other.name());
    }
}

#[test]
fn a_text_is_checked_by_its_bytes() {
    let at = "a".repeat(MAX_TEXT_BYTES);
    assert!(Operation::prompt("s1", &at).is_ok());
    assert!(Operation::steer("s1", &at).is_ok());
    assert!(Operation::follow_up("s1", &at).is_ok());
    let over = "a".repeat(MAX_TEXT_BYTES + 1);
    for operation in [
        Operation::prompt("s1", &over),
        Operation::steer("s1", &over),
        Operation::follow_up("s1", &over),
    ] {
        assert_eq!(operation, Err(Invalid::TextTooLarge));
    }
    // A character of two bytes counts its bytes: 2,097,152 of them are at the
    // bound, and one more character is over it.
    let text = "é".repeat(MAX_TEXT_BYTES / 2);
    assert_eq!(text.len(), MAX_TEXT_BYTES);
    assert!(Operation::prompt("s1", &text).is_ok());
    assert_eq!(
        Operation::prompt("s1", &format!("{text}é")),
        Err(Invalid::TextTooLarge)
    );
    assert_eq!(Invalid::TextTooLarge.text(), "the text is over 4 MiB");
}

#[test]
fn a_model_ref_is_checked_by_its_bytes_and_its_slash() {
    // A ref of exactly the bound is accepted, and one byte more is refused.
    let at = format!("p/{}", "a".repeat(MAX_MODEL_BYTES - 2));
    assert_eq!(at.len(), MAX_MODEL_BYTES);
    assert!(Operation::set_model("s1", &at).is_ok());
    let over = format!("{at}a");
    assert_eq!(Operation::set_model("s1", &over), Err(Invalid::ModelRef));
    // The bound counts bytes: 127 characters of two bytes fill it.
    let multibyte = format!("p/{}", "é".repeat((MAX_MODEL_BYTES - 2) / 2));
    assert_eq!(multibyte.len(), MAX_MODEL_BYTES);
    assert!(Operation::set_model("s1", &multibyte).is_ok());
    // A space, a tab, a control character, no slash, and an empty part on
    // either side of the slash are refused.
    for bad in ["p/m x", "p/m\tx", "p/m\u{7}", "pm", "/m", "p/"] {
        assert_eq!(
            Operation::set_model("s1", bad),
            Err(Invalid::ModelRef),
            "{bad:?}"
        );
    }
    assert_eq!(
        Invalid::ModelRef.text(),
        "not a model ref: use provider/model"
    );
}

#[test]
fn compact_takes_the_bound_of_a_message_and_no_text_when_it_is_empty() {
    let empty = Operation::compact("s1", "").unwrap();
    assert_eq!(empty.text(), None);
    let instructions = Operation::compact("s1", "trim").unwrap();
    assert_eq!(instructions.text(), Some("trim"));
    // The text is the message bound of a prompt.
    let at = "a".repeat(MAX_TEXT_BYTES);
    assert!(Operation::compact("s1", &at).is_ok());
    assert_eq!(
        Operation::compact("s1", &format!("{at}a")),
        Err(Invalid::TextTooLarge)
    );
}

#[test]
fn a_folder_and_a_page_limit_are_checked() {
    let at = "/".repeat(MAX_CWD_BYTES);
    assert!(Operation::start(&at, None).is_ok());
    assert_eq!(
        Operation::start(&format!("{at}/"), None),
        Err(Invalid::CwdTooLarge)
    );
    assert_eq!(
        Operation::resume_folder(&format!("{at}/")),
        Err(Invalid::CwdTooLarge)
    );
    assert_eq!(
        Operation::saved(Saved {
            cwd: Some(format!("{at}/")),
            ..Saved::default()
        }),
        Err(Invalid::CwdTooLarge)
    );
    assert!(
        Operation::saved(Saved {
            limit: Some(1),
            ..Saved::default()
        })
        .is_ok()
    );
    assert!(
        Operation::saved(Saved {
            limit: Some(MAX_LIMIT),
            ..Saved::default()
        })
        .is_ok()
    );
    for limit in [0, MAX_LIMIT + 1] {
        assert_eq!(
            Operation::saved(Saved {
                limit: Some(limit),
                ..Saved::default()
            }),
            Err(Invalid::Limit)
        );
    }
}

#[test]
fn an_answer_is_an_object_within_its_bound() {
    let answer = form_answer(&[
        FormAnswer {
            selected: vec!["Yes".into()],
            other: None,
        },
        FormAnswer {
            selected: vec![],
            other: Some("Other".into()),
        },
        FormAnswer::default(),
    ]);
    assert_eq!(
        answer,
        decode(r#"{"answers":[{"selected":["Yes"]},{"other":"Other"},{}]}"#).unwrap()
    );
    assert_eq!(
        approval_answer(false),
        decode(r#"{"decision":"deny"}"#).unwrap()
    );
    assert!(Operation::answer("s1", "a1", answer).is_ok());
    assert_eq!(
        Operation::answer("s1", "a1", Json::Array(vec![])),
        Err(Invalid::AnswerNotObject)
    );
    // `{"text":"…"}` is 11 bytes around its string.
    let at = common::j(&json!({"text": "a".repeat(MAX_ANSWER_BYTES - 11)}));
    assert_eq!(at.encode().len(), MAX_ANSWER_BYTES);
    assert!(Operation::answer("s1", "a1", at).is_ok());
    let over = common::j(&json!({"text": "a".repeat(MAX_ANSWER_BYTES - 10)}));
    assert_eq!(over.encode().len(), MAX_ANSWER_BYTES + 1);
    assert_eq!(
        Operation::answer("s1", "a1", over),
        Err(Invalid::AnswerTooLarge)
    );
    assert_eq!(
        Operation::answer("s1", "a1", Json::Null),
        Err(Invalid::AnswerNotObject)
    );
}

/// The raw texts of an answer: a number of `NaN`, a container kept as its
/// text that is not JSON, and an integer of more than 100 digits are values
/// that the server refuses, so the core makes no operation of them.
#[test]
fn an_answer_is_checked_by_its_raw_texts_and_its_integers() {
    let answer = |value: Json| Operation::answer("s1", "a1", value);
    // A number text that is not a number.
    let nan = helyx_client_core::json::object([("n", Json::Number("NaN".into()))]);
    assert_eq!(answer(nan), Err(Invalid::AnswerNotJson));
    // A text that reads as a container but is not JSON.
    let deep = helyx_client_core::json::object([("n", Json::Deep("[1, ".into()))]);
    assert_eq!(answer(deep), Err(Invalid::AnswerNotJson));
    // A container kept as its text with an integer over 100 digits.
    let big_deep = helyx_client_core::json::object([(
        "n",
        Json::Deep(format!("{{ \"n\": {} }}", "1".repeat(101))),
    )]);
    assert_eq!(answer(big_deep), Err(Invalid::AnswerInteger));
    // A number that is not an integer can change its encode size on the
    // server (`1e2` is `100.0`), so it is refused; `-12` is an integer.
    for text in ["1e2", "1.5", "1E-7"] {
        assert_eq!(
            answer(helyx_client_core::json::object([(
                "n",
                Json::Number(text.into()),
            )])),
            Err(Invalid::AnswerNumber),
            "{text}"
        );
    }
    assert!(
        answer(helyx_client_core::json::object([(
            "n",
            Json::Number("-12".into()),
        )]))
        .is_ok()
    );
    // The rule holds inside a container kept as its text.
    assert_eq!(
        answer(helyx_client_core::json::object([(
            "n",
            Json::Deep("[1e2]".into()),
        )])),
        Err(Invalid::AnswerNumber)
    );
    // An integer of 100 digits is within the bound; 101 is not.
    let at = helyx_client_core::json::object([("n", Json::Number("1".repeat(100)))]);
    assert!(answer(at).is_ok());
    let over = helyx_client_core::json::object([("n", Json::Number("1".repeat(101)))]);
    assert_eq!(answer(over), Err(Invalid::AnswerInteger));
    // The sign does not count, as the server judges the value.
    let negative =
        helyx_client_core::json::object([("n", Json::Number(format!("-{}", "1".repeat(100))))]);
    assert!(answer(negative).is_ok());
}

#[test]
fn the_deadline_is_the_table_of_the_wire() {
    let ms = |ms| Some(Duration::from_millis(ms));
    assert_eq!(deadline("prompt"), ms(6_000));
    assert_eq!(deadline("steer"), ms(6_000));
    assert_eq!(deadline("follow_up"), ms(6_000));
    assert_eq!(deadline("answer"), ms(6_000));
    assert_eq!(deadline("history"), ms(6_000));
    assert_eq!(deadline("abort"), ms(46_000));
    assert_eq!(deadline("stop"), ms(77_000));
    // A model switch and a compaction take the default of the table.
    assert_eq!(deadline("set_model"), ms(6_000));
    assert_eq!(deadline("compact"), ms(6_000));
    // 10,000 ms, or 15,000 ms under a Hub: the client knows the larger.
    assert_eq!(deadline("sessions.saved"), ms(15_000));
    assert_eq!(deadline("subscribe"), ms(5_000));
    // The server bounds the open of a session itself.
    assert_eq!(deadline("start"), None);
    assert_eq!(deadline("resume"), None);
}

#[test]
fn a_request_is_in_flight_until_its_reply_matches_it() {
    let mut client = Client::new();
    welcomed(&mut client);
    let (id, frames) = client
        .perform(Operation::prompt("s1", "hi").unwrap())
        .unwrap();
    assert_eq!(
        sent(&[Output::Send(frames[0].clone())])[0]
            .get("op")
            .and_then(Json::as_str),
        Some("prompt")
    );
    // A `start` has no deadline, which the request keeps with it.
    let (start, _) = client
        .perform(Operation::start("/r", None).unwrap())
        .unwrap();
    assert_eq!(
        client.outstanding(),
        [
            (id.as_str(), "prompt", deadline("prompt")),
            (start.as_str(), "start", None)
        ]
    );
    let reply = json!({"type": "res", "id": id, "ok": true, "result": {}}).to_string();
    assert_eq!(
        client.receive(&reply).unwrap(),
        [Output::Reply {
            id: id.clone(),
            result: Ok(Reply::Empty)
        }]
    );
    assert_eq!(client.outstanding(), [(start.as_str(), "start", None)]);
    // A reply of no request in flight is a break.
    let mut client = Client::new();
    welcomed(&mut client);
    let reply = json!({"type": "res", "id": "0", "ok": true, "result": {}}).to_string();
    assert!(client.receive(&reply).is_err());
}

#[test]
fn a_request_waits_for_the_welcome_and_is_not_queued() {
    let mut client = Client::new();
    client.connect(None);
    client.receive(CHALLENGE).unwrap();
    assert_eq!(
        client.perform(Operation::abort("s1")),
        Err(Refusal::NotReady)
    );
    assert!(client.outstanding().is_empty());
    // After a close, nothing of the old connection waits for the next one.
    let mut client = Client::new();
    welcomed(&mut client);
    let (id, _) = client.perform(Operation::abort("s1")).unwrap();
    assert_eq!(client.closed(None).unknown, [(id, "abort")]);
    assert_eq!(
        client.perform(Operation::abort("s1")),
        Err(Refusal::NotReady)
    );
}

#[test]
fn a_lost_reply_is_unknown_and_never_sent_again() {
    let mut client = Client::new();
    welcomed(&mut client);
    let (prompt, _) = client
        .perform(Operation::prompt("s1", "hi").unwrap())
        .unwrap();
    let (abort, _) = client.perform(Operation::abort("s1")).unwrap();
    let closed = client.closed(None);
    assert_eq!(closed.next, Next::Reconnect);
    assert_eq!(closed.unknown, [(prompt, "prompt"), (abort, "abort")]);
    // The next connection states no intent of its own: neither goes again.
    client.connect(None);
    client.receive(CHALLENGE).unwrap();
    assert_eq!(client.receive(WELCOME).unwrap(), [Output::Welcome]);
    assert!(client.outstanding().is_empty());
    // A `start` and a `resume` have no session, and a lost reply of one is
    // unknown too.
    let mut client = Client::new();
    welcomed(&mut client);
    let (start, _) = client
        .perform(Operation::start("/r", None).unwrap())
        .unwrap();
    let (saved, _) = client
        .perform(Operation::saved(Saved::default()).unwrap())
        .unwrap();
    assert_eq!(
        client.closed(None).unknown,
        [(start, "start"), (saved, "sessions.saved")]
    );
}

#[test]
fn a_reconciling_request_is_not_a_lost_reply() {
    let mut client = Client::new();
    // The subscribe waits for the welcome, so the intent outlives it.
    client.subscribe("s1").unwrap();
    welcomed(&mut client);
    // Its subscribe is in flight: the intent of the host, not one of its
    // operations.
    assert!(client.outstanding().is_empty());
    let closed = client.closed(None);
    assert!(closed.unknown.is_empty());
    assert_eq!(closed.next, Next::Reconnect);
    // The next connection states the intent again.
    let outputs = {
        client.connect(None);
        client.receive(CHALLENGE).unwrap();
        client.receive(WELCOME).unwrap()
    };
    assert_eq!(outputs.len(), 2, "{outputs:?}");
    assert_eq!(
        sent(&outputs)[0].get("op").and_then(Json::as_str),
        Some("subscribe")
    );
}

#[test]
fn a_break_ends_the_connection_and_its_requests() {
    let mut client = Client::new();
    welcomed(&mut client);
    let (id, _) = client.perform(Operation::abort("s1")).unwrap();
    // A frame that is not a server frame after the welcome.
    assert!(client.receive(r#"{"type":"nope"}"#).is_err());
    let closed = client.closed(None);
    assert_eq!(closed.next, Next::Stop);
    assert_eq!(closed.unknown, [(id, "abort")]);
}
