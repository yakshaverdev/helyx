//! The link of a pairing, the key, the signature text, and the three `hello`
//! forms (`docs/features/remote-hands.md`, "Pairing and the public listener";
//! `docs/features/client-kit.md`, "A remote server").

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use helyx_client_core::handshake::{Credential, Handshake, Step, Token, proof, signature_text};
use helyx_client_core::json::{Json, decode};
use helyx_client_core::key::Key;
use helyx_client_core::link::{Link, ParseError};

/// The pin of the test: the base64url, without padding, of 32 zero bytes.
const PIN: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
/// The nonce of the tests: the 32 bytes 0x00 to 0x1f.
const NONCE: [u8; 32] = [
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
];

/// The public key of the key of the seed of 32 bytes of 0x07, computed in
/// `plugins/bundled` on 2026-11-12 with `:crypto.generate_key(:eddsa,
/// :ed25519, seed)`: the same bytes that ring makes from the seed.
const PUBLIC_KEY: &str = "6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=";
/// The signature of the signature text of `PIN`, `client`, and `phone` with
/// that key, computed in `plugins/bundled` on 2026-11-12 with
/// `:crypto.sign(:eddsa, :none, text, [private, :ed25519])`.
const SIGNATURE: &str =
    "bC/qU5O170MQnAYXPoO+6Q+YeaBIvB31GHOBtl59h8T03iWUao4SnYjATlqAwVTkB2Cj9hIndwQwtPUmFoEPAw==";

fn link_of(json: &str) -> String {
    format!("helyx-pair:1:{}", URL_SAFE_NO_PAD.encode(json))
}

fn fields(host: &str, port: &str, token: &str, pin: &str, kind: &str, name: &str) -> String {
    format!(r#"{{"a":"{host}:{port}","t":"{token}","p":"{pin}","k":"{kind}","n":"{name}"}}"#)
}

fn good() -> String {
    link_of(&fields(
        "example.test",
        "443",
        "tok-1",
        PIN,
        "client",
        "phone",
    ))
}

fn challenge() -> Json {
    decode(&format!(
        r#"{{"type":"challenge","nonce":"{}"}}"#,
        base64::engine::general_purpose::STANDARD.encode(NONCE)
    ))
    .unwrap()
}

fn hello(credential: Credential) -> Json {
    match Handshake::new(credential).step(&challenge()) {
        Ok(Step::Send(hello)) => hello,
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_good_link_parses() {
    let link = Link::parse(&good()).unwrap();
    assert_eq!(link.host, "example.test");
    assert_eq!(link.port, 443);
    assert_eq!(link.pin, PIN);
    assert_eq!(link.name, "phone");
    assert_eq!(format!("{:?}", link.token), "Token(..)");
    // An IPv6 literal keeps its bare host.
    let v6 = link_of(&fields("[::1]", "8443", "t", PIN, "client", "phone"));
    let link = Link::parse(&v6).unwrap();
    assert_eq!((link.host.as_str(), link.port), ("::1", 8443));
    // A host of 253 bytes and a name of 64 still parse.
    let long = link_of(&fields(
        &"a".repeat(253),
        "65535",
        &"t".repeat(43),
        PIN,
        "client",
        &"n".repeat(64),
    ));
    assert!(Link::parse(&long).is_ok());
}

#[test]
fn every_fault_of_a_link_is_its_own_error() {
    let cases: Vec<(String, ParseError)> = vec![
        ("helyx-pair:2:abc".into(), ParseError::Prefix),
        ("other:1:abc".into(), ParseError::Prefix),
        (format!("helyx-pair:1:{}", "!!!!"), ParseError::Base64),
        (link_of("not json"), ParseError::Json),
        (link_of("[1,2]"), ParseError::Field("a")),
        (
            link_of(r#"{"t":"t","p":"p","k":"client","n":"phone"}"#),
            ParseError::Field("a"),
        ),
        (
            link_of(r#"{"a":"h:1","p":"p","k":"client","n":"phone"}"#),
            ParseError::Field("t"),
        ),
        (
            link_of(r#"{"a":"h:1","t":"t","k":"client","n":"phone"}"#),
            ParseError::Field("p"),
        ),
        (
            link_of(r#"{"a":"h:1","t":"t","p":"p","n":"phone"}"#),
            ParseError::Field("k"),
        ),
        (
            link_of(r#"{"a":"h:1","t":"t","p":"p","k":"client"}"#),
            ParseError::Field("n"),
        ),
        (
            link_of(r#"{"a":1,"t":"t","p":"p","k":"client","n":"phone"}"#),
            ParseError::Field("a"),
        ),
        (
            link_of(&fields("h", "1", "t", PIN, "hands", "phone")),
            ParseError::Kind,
        ),
        (
            link_of(&fields("h", "1", "t", PIN, "client", "")),
            ParseError::Name,
        ),
        (
            link_of(&fields("h", "1", "t", PIN, "client", "Phone")),
            ParseError::Name,
        ),
        (
            link_of(&fields("h", "1", "t", PIN, "client", "a-b")),
            ParseError::Name,
        ),
        (
            link_of(&fields("h", "1", "t", PIN, "client", &"n".repeat(65))),
            ParseError::Name,
        ),
        (
            link_of(&fields("h", "0", "t", PIN, "client", "phone")),
            ParseError::Port,
        ),
        (
            link_of(&fields("h", "65536", "t", PIN, "client", "phone")),
            ParseError::Port,
        ),
        (
            link_of(&fields("h", "x", "t", PIN, "client", "phone")),
            ParseError::Port,
        ),
        (
            link_of(&fields("", "1", "t", PIN, "client", "phone")),
            ParseError::Host,
        ),
        (
            link_of(&fields("h", "1", "t", "AAAA", "client", "phone")),
            ParseError::Pin,
        ),
        (
            link_of(&fields("h", "1", "t", &"A".repeat(44), "client", "phone")),
            ParseError::Pin,
        ),
        (
            format!("helyx-pair:1:{}", "A".repeat(2_048)),
            ParseError::Size,
        ),
    ];
    for (text, error) in cases {
        assert_eq!(Link::parse(&text), Err(error), "{text}");
    }
}

#[test]
fn no_error_and_no_debug_form_holds_the_token() {
    let token = "tok-9c41e7";
    let good = link_of(&fields("h", "1", token, PIN, "client", "phone"));
    let link = Link::parse(&good).unwrap();
    assert!(!format!("{link:?}").contains(token));
    assert!(!format!("{link:?}").contains(PIN));
    // Each fault of a link that carries the token names no part of it.
    for text in [
        link_of(&fields("h", "0", token, PIN, "client", "phone")),
        link_of(&fields("h", "1", token, PIN, "hands", "phone")),
        link_of(&fields("h", "1", token, "AAAA", "client", "phone")),
        format!(
            "helyx-pair:1:{}",
            URL_SAFE_NO_PAD.encode(format!("{{\"t\":\"{token}\""))
        ),
    ] {
        let Err(error) = Link::parse(&text) else {
            panic!("{text} parsed")
        };
        assert!(!format!("{error:?}").contains(token));
        assert!(!error.text().contains(token));
    }
}

/// The signature text of the Elixir function
/// `Helyx.Transport.WebSocket.Pairing.signature_text/4`, computed in
/// `plugins/bundled` on 2026-11-12 with the nonce of `NONCE`, the pin of
/// `PIN`, the kind `client`, and the name `phone`.
#[test]
fn the_signature_text_is_the_bytes_of_the_server() {
    let text = signature_text(PIN, "client", "phone", &NONCE);
    let hex: String = text.iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(
        hex,
        "0000001268656c79782d68616e647368616b652d7631\
         00000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\
         0000002b41414141414141414141414141414141414141414141414141414141414141414141414141414141414141\
         00000006636c69656e74\
         0000000570686f6e65"
    );
    assert_eq!(text.len(), 4 + 18 + 4 + 32 + 4 + 43 + 4 + 6 + 4 + 5);
}

#[test]
fn the_hello_of_a_token_and_of_no_token() {
    let frame = hello(Credential::token("secret"));
    assert_eq!(
        frame,
        decode(&format!(
            r#"{{"type":"hello","protocol":13,"proof":"{}"}}"#,
            proof("secret", &NONCE)
        ))
        .unwrap()
    );
    assert_eq!(
        hello(Credential::none()),
        decode(r#"{"type":"hello","protocol":13}"#).unwrap()
    );
}

#[test]
fn the_pairing_hello_is_the_frame_of_the_server() {
    let key = Key::from_seed([7; 32]).unwrap();
    let hello = hello(Credential::Pair {
        token: Token::new("bootstrap-token-fixed".into()),
        pin: PIN.into(),
        name: "phone".into(),
        key,
    });
    let expected = format!(
        concat!(
            r#"{{"client":"phone","pair":{{"proof":"{}","public_key":"{}","signature":"{}"}},"#,
            r#""protocol":13,"role":"client","type":"hello"}}"#
        ),
        proof("bootstrap-token-fixed", &NONCE),
        PUBLIC_KEY,
        SIGNATURE
    );
    assert_eq!(hello.encode(), expected);
}

#[test]
fn the_hello_of_a_paired_client_is_the_frame_of_the_server() {
    let key = Key::from_seed([7; 32]).unwrap();
    let hello = hello(Credential::Paired {
        pin: PIN.into(),
        name: "phone".into(),
        key,
    });
    let expected = format!(
        concat!(
            r#"{{"client":"phone","protocol":13,"role":"client","signature":"{}","#,
            r#""type":"hello"}}"#
        ),
        SIGNATURE
    );
    assert_eq!(hello.encode(), expected);
}

#[test]
fn the_key_signs_the_text_and_a_peer_checks_it() {
    let key = Key::from_seed([7; 32]).unwrap();
    let text = signature_text(PIN, "client", "phone", &NONCE);
    let signature = key.sign(&text);
    assert!(helyx_client_core::key::verify(
        &key.public_key(),
        &text,
        &signature
    ));
    assert!(!helyx_client_core::key::verify(
        &key.public_key(),
        &signature_text(PIN, "client", "other", &NONCE),
        &signature
    ));
    // The seed is the key: the same seed signs the same bytes.
    let again = Key::from_seed(key.seed()).unwrap();
    assert_eq!(again.public_key(), key.public_key());
    assert_eq!(again.sign(&text), signature);
    assert!(!format!("{key:?}").contains(&key.public_key()));
    assert!(!format!("{key:?}").contains(&format!("{:?}", key.seed())));
}

#[test]
fn no_debug_form_of_a_connected_client_holds_the_token_or_the_key() {
    let key = Key::from_seed([7; 32]).unwrap();
    let mut client = helyx_client_core::client::Client::new();
    client.connect(Credential::Pair {
        token: Token::new("tok-1".into()),
        pin: PIN.into(),
        name: "phone".into(),
        key: key.clone(),
    });
    let shown = format!("{client:?}");
    assert!(!shown.contains("tok-1"), "{shown}");
    assert!(!shown.contains(&key.public_key()), "{shown}");
    assert!(
        !shown.contains(&URL_SAFE_NO_PAD.encode(key.seed())),
        "{shown}"
    );
    // The credential of the handshake shows nothing either.
    let credential = Credential::Paired {
        pin: PIN.into(),
        name: "phone".into(),
        key: key.clone(),
    };
    assert_eq!(format!("{credential:?}"), "Credential(..)");
}
