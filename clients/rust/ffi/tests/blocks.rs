//! The block and answer surface of the bindings (`docs/features/ios-app.md`,
//! "What the Swift views need"): a form, an approval, a kind that the core
//! does not know, and a broken block; each answer; the open ask of a session.

use helyx_client_ffi::{
    Ask, BlockView, FormAnswerItem, FormOption, FormQuestion, answering, approval_answer,
    form_answer, read_block,
};

/// An ask whose request is the JSON `request`.
fn ask(ask_id: &str, request: &str) -> Ask {
    Ask {
        ask_id: ask_id.into(),
        call_id: "c1".into(),
        tool: "question".into(),
        request: request.into(),
    }
}

#[test]
fn a_form_reads_its_questions_and_options() {
    let block = read_block(
        r#"{"kind":"form","text":"1 question","questions":[{"question":"Which?","header":"Pick",
           "options":[{"label":"a","description":""},{"label":"b","description":"the other"}],
           "multi_select":true}]}"#
            .into(),
    );
    assert_eq!(
        block,
        BlockView::Form {
            text: "1 question".into(),
            questions: vec![FormQuestion {
                question: "Which?".into(),
                header: "Pick".into(),
                options: vec![
                    FormOption {
                        label: "a".into(),
                        description: "".into(),
                    },
                    FormOption {
                        label: "b".into(),
                        description: "the other".into(),
                    },
                ],
                multi_select: true,
            }],
        }
    );
}

#[test]
fn an_approval_reads_its_tool_provider_and_arguments() {
    assert_eq!(
        read_block(
            r#"{"kind":"approval","text":"allow bash?","tool":"bash","arguments":"{\"command\":\"ls\"}"}"#
                .into(),
        ),
        BlockView::Approval {
            text: "allow bash?".into(),
            tool: "bash".into(),
            provider: None,
            arguments: r#"{"command":"ls"}"#.into(),
        }
    );
    assert_eq!(
        read_block(
            r#"{"kind":"approval","text":"allow ls?","tool":"ls","provider":"p","arguments":"{}"}"#
                .into(),
        ),
        BlockView::Approval {
            text: "allow ls?".into(),
            tool: "ls".into(),
            provider: Some("p".into()),
            arguments: "{}".into(),
        }
    );
}

#[test]
fn another_kind_is_its_text_and_keeps_its_kind() {
    assert_eq!(
        read_block(r#"{"kind":"diff","text":"a diff","cut":true}"#.into()),
        BlockView::Text {
            kind: "diff".into(),
            text: "a diff".into(),
        }
    );
    // A kind that the core knows, whose fields it cannot read: its text.
    assert_eq!(
        read_block(
            r#"{"kind":"form","text":"1 question","questions":[{"question":"q","header":"h",
               "options":[{"label":"only","description":""}],"multi_select":false}]}"#
                .into(),
        ),
        BlockView::Text {
            kind: "form".into(),
            text: "1 question".into(),
        }
    );
}

#[test]
fn a_text_that_is_not_a_block_is_a_text_with_no_kind() {
    // A block whose envelope fails: the text is the text that the host gave.
    assert_eq!(
        read_block(r#"{"kind":"Form","text":"x"}"#.into()),
        BlockView::Text {
            kind: "".into(),
            text: r#"{"kind":"Form","text":"x"}"#.into(),
        }
    );
    // A text that is not JSON at all.
    assert_eq!(
        read_block("not a block".into()),
        BlockView::Text {
            kind: "".into(),
            text: "not a block".into(),
        }
    );
    assert_eq!(
        read_block("{".into()),
        BlockView::Text {
            kind: "".into(),
            text: "{".into(),
        }
    );
}

#[test]
fn a_text_that_is_not_a_block_is_cut_at_the_bound_of_a_block() {
    let bound = helyx_client_core::ui_block::MAX_BYTES;
    // A text of 2-byte characters at the bound, and one over it, which cuts
    // at a character boundary.
    let at = "é".repeat(bound / 2);
    let BlockView::Text { text: shown, .. } = read_block(at.clone()) else {
        panic!("a text that is not a block");
    };
    assert_eq!(shown, at);
    let over = format!("a{}", "é".repeat(bound));
    let BlockView::Text { text: shown, .. } = read_block(over.clone()) else {
        panic!("a text that is not a block");
    };
    assert_eq!(shown.len(), bound - 1);
    assert!(over.starts_with(&shown));
}

#[test]
fn a_form_answer_is_one_item_for_each_question_in_order() {
    assert_eq!(
        form_answer(vec![
            FormAnswerItem {
                selected: vec!["a".into(), "b".into()],
                other: None,
            },
            FormAnswerItem {
                selected: vec![],
                other: Some("Other".into()),
            },
        ]),
        r#"{"answers":[{"selected":["a","b"]},{"other":"Other"}]}"#
    );
    // An item with no pick and no text leaves both keys out.
    assert_eq!(
        form_answer(vec![FormAnswerItem {
            selected: vec![],
            other: None,
        }]),
        r#"{"answers":[{}]}"#
    );
}

#[test]
fn an_approval_answer_is_allow_or_deny() {
    assert_eq!(approval_answer(true), r#"{"decision":"allow"}"#);
    assert_eq!(approval_answer(false), r#"{"decision":"deny"}"#);
}

#[test]
fn the_open_ask_is_the_oldest_of_a_kind_that_the_host_reads() {
    let form = r#"{"kind":"form","text":"1 question","questions":[{"question":"q","header":"h",
                  "options":[{"label":"a","description":""},{"label":"b","description":""}],
                  "multi_select":false}]}"#;
    let approval = r#"{"kind":"approval","text":"allow bash?","tool":"bash","arguments":"{}"}"#;
    let diff = r#"{"kind":"diff","text":"a diff"}"#;
    let no_kind = r#"{"questions":[]}"#;
    // A kind that the host cannot answer, and an ask with no kind, are
    // skipped; the oldest form or approval is the open one.
    let asks = [
        ask("a1", diff),
        ask("a2", no_kind),
        ask("a3", form),
        ask("a4", approval),
    ];
    assert_eq!(answering(&asks), Some("a3".into()));
    assert_eq!(answering(&asks[2..]), Some("a3".into()));
    assert_eq!(answering(&asks[3..]), Some("a4".into()));
    assert_eq!(answering(&asks[..2]), None);
    assert_eq!(answering(&[]), None);
}
