//! The decoder of the core at its bounds (`docs/features/wire-protocol.md`,
//! "Bounds", the outbound decode bounds; `docs/features/client-kit.md`).

use helyx_client_core::json::{Json, Limits, WIRE, decode, decode_within};

// The bounds at a small scale, so a test does not build a value of 38
// million items; `the_wire_limits` checks the numbers of the wire.
const SMALL: Limits = Limits {
    frame_bytes: 64,
    values: 10,
    integer_chars: 5,
    depth: 3,
};
const MAX_INTEGER_CHARS: usize = 5;
const MAX_DEPTH: usize = 3;
const MAX_VALUES: usize = 10;

fn ok(text: &str) -> bool {
    decode_within(text, SMALL).is_ok()
}

#[test]
fn the_wire_limits() {
    let doc = Limits {
        frame_bytes: 1_611_661_312,
        values: 38_797_312,
        integer_chars: 1_024,
        depth: 1_024,
    };
    assert_eq!(WIRE, doc);
    assert!(decode(&"9".repeat(1_024)).is_ok());
    assert!(decode(&"9".repeat(1_025)).is_err());
    let nest = |n| format!("{}{}", "[".repeat(n), "]".repeat(n));
    assert!(decode(&nest(1_024)).is_ok());
    assert!(decode(&nest(1_025)).is_err());
}

#[test]
fn a_text_has_at_most_the_bytes_of_the_bound() {
    let string = |n: usize| format!("\"{}\"", "a".repeat(n - 2));
    assert!(ok(&string(64)));
    assert!(!ok(&string(65)));
    // Multibyte: 31 characters of two bytes and the quotes are 64 bytes.
    assert!(ok(&format!("\"{}\"", "é".repeat(31))));
    assert!(!ok(&format!("\"{}a\"", "é".repeat(31))));
}

#[test]
fn an_integer_has_at_most_its_characters_with_its_sign() {
    let nines = |n| "9".repeat(n);
    assert!(ok(&nines(MAX_INTEGER_CHARS)));
    assert!(!ok(&nines(MAX_INTEGER_CHARS + 1)));
    assert!(ok(&format!("-{}", nines(MAX_INTEGER_CHARS - 1))));
    assert!(!ok(&format!("-{}", nines(MAX_INTEGER_CHARS))));
    // The text of a number stays as it came.
    assert_eq!(
        decode_within(&nines(MAX_INTEGER_CHARS), SMALL).unwrap(),
        Json::Number(nines(MAX_INTEGER_CHARS))
    );
}

#[test]
fn a_float_is_finite() {
    assert!(ok("1e308"));
    assert!(!ok("1e400"));
    assert!(!ok("-1e400"));
    assert!(ok("0.5"));
}

#[test]
fn the_grammar_of_numbers() {
    for bad in ["01", "-", "1.", ".5", "1e", "+1", "0x10", "NaN", "1.5e+"] {
        assert!(!ok(bad), "{bad}");
    }
    for good in ["0", "-0", "1.5e+3", "2E-2"] {
        assert!(ok(good), "{good}");
    }
}

#[test]
fn nesting_has_at_most_the_depth() {
    let nest = |n| format!("{}{}", "[".repeat(n), "]".repeat(n));
    assert!(ok(&nest(MAX_DEPTH)));
    assert!(!ok(&nest(MAX_DEPTH + 1)));
    let objects = |n| format!("{}1{}", r#"{"a":"#.repeat(n), "}".repeat(n));
    assert!(ok(&objects(MAX_DEPTH)));
    assert!(!ok(&objects(MAX_DEPTH + 1)));
}

#[test]
fn a_frame_has_at_most_the_bound_of_values() {
    // An array counts one, and each item one.
    let ok = |text: &str| {
        decode_within(
            text,
            Limits {
                frame_bytes: 1 << 20,
                ..SMALL
            },
        )
        .is_ok()
    };
    let array = |items: usize| format!("[{}]", vec!["0"; items].join(","));
    assert!(ok(&array(MAX_VALUES - 1)));
    assert!(!ok(&array(MAX_VALUES)));
}

#[test]
fn a_key_counts_one_value() {
    // An object of n pairs counts 1 + 2n.
    let pairs = (MAX_VALUES - 1) / 2;
    let ok = |text: &str| {
        decode_within(
            text,
            Limits {
                frame_bytes: 1 << 20,
                ..SMALL
            },
        )
        .is_ok()
    };
    let object = |n: usize| {
        let body: Vec<String> = (0..n).map(|i| format!(r#""{i}":0"#)).collect();
        format!("{{{}}}", body.join(","))
    };
    assert!(ok(&object(pairs)));
    assert!(!ok(&object(pairs + 1)));
}

#[test]
fn strings_and_escapes() {
    // `e(x)` is the JSON escape of a backslash and `x`.
    let e = |x: &str| format!("{}{x}", '\\');
    let text = format!("\"a{}{}{}{}\"", e("u00e9"), e("ud83d"), e("ude00"), e("n"));
    assert_eq!(
        decode(&text).unwrap(),
        Json::String("a\u{e9}\u{1f600}\n".into())
    );
    assert_eq!(decode("\"\u{e9}\"").unwrap(), Json::String("\u{e9}".into()));
    let bad = [
        format!("\"{}\"", e("ud800")),
        format!("\"{}\"", e("udc00")),
        format!("\"{}{}\"", e("ud800"), e("u0041")),
        "\"a\u{1}\"".to_owned(),
        format!("\"{}\"", e("x")),
        "\"a".to_owned(),
    ];
    for text in bad {
        assert!(!ok(&text), "{text}");
    }
}

#[test]
fn the_text_is_one_value() {
    assert!(ok(" {\"a\": [true, false, null]} \n"));
    for bad in ["", "1 2", "{\"a\" 1}", "[1,]", "{,}", "tru", "{1:2}"] {
        assert!(!ok(bad), "{bad}");
    }
}

#[test]
fn a_lookup_takes_the_first_pair_and_encode_keeps_every_pair() {
    let value = decode(r#"{"a":1,"a":2}"#).unwrap();
    assert_eq!(value.get("a"), Some(&Json::Number("1".into())));
    assert_eq!(value.encode(), r#"{"a":1,"a":2}"#);
    let text = "{\"t\":\"q\\\"\\\\\\n\\u0001é\"}";
    assert_eq!(
        decode(&decode(text).unwrap().encode()).unwrap(),
        decode(text).unwrap()
    );
}
