//! The arguments of the app (`docs/features/client-kit.md`, "A remote
//! server"): `--pair`, `--remote`, a folder, and the one line of each fault.
//! The text of a link is never printed back.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use helyx_desktop::cli::{Launch, parse};
use std::ffi::OsString;
use std::path::PathBuf;

/// The pin of the test: the base64url, without padding, of 32 zero bytes.
const PIN: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

fn args(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

fn link_of(json: &str) -> String {
    format!("helyx-pair:1:{}", URL_SAFE_NO_PAD.encode(json))
}

fn bad_port() -> String {
    link_of(&format!(
        r#"{{"a":"example.test:0","k":"client","n":"phone","p":"{PIN}","t":"tok-fixed"}}"#
    ))
}

fn no_token() -> String {
    link_of(&format!(
        r#"{{"a":"example.test:443","k":"client","n":"phone","p":"{PIN}"}}"#
    ))
}

fn good_link() -> String {
    link_of(&format!(
        r#"{{"a":"example.test:443","k":"client","n":"phone","p":"{PIN}","t":"tok-fixed"}}"#
    ))
}

#[test]
fn no_argument_is_the_default_folder_and_a_folder_is_the_local_server() {
    assert_eq!(parse(args(&[])), Ok(Launch::Local(None)));
    assert_eq!(
        parse(args(&["/tmp/one"])),
        Ok(Launch::Local(Some(PathBuf::from("/tmp/one"))))
    );
}

#[test]
fn a_link_pairs_and_a_name_is_the_paired_client() {
    let Ok(Launch::Pair(link)) = parse(args(&["--pair", &good_link()])) else {
        panic!("a pairing")
    };
    assert_eq!(
        (link.host.as_str(), link.port, link.name.as_str()),
        ("example.test", 443, "phone")
    );
    assert_eq!(link.pin, PIN);
    assert_eq!(
        parse(args(&["--remote", "phone"])),
        Ok(Launch::Remote("phone".into()))
    );
}

#[test]
fn each_bad_argument_is_one_line() {
    for (values, line) in [
        (args(&["--pair"]), "--pair takes a link"),
        (args(&["--remote"]), "--remote takes a name"),
        (
            args(&["--remote", "Phone"]),
            "--remote takes a name of 1 to 64 bytes of a-z, 0-9, and _",
        ),
        (args(&["--nope"]), "unknown argument --nope"),
        (args(&["one", "two"]), "takes one argument"),
        (
            args(&["--pair", &bad_port()]),
            "the link port is not 1 to 65535",
        ),
        (
            args(&["--pair", &no_token()]),
            "the link token is missing or not a string",
        ),
    ] {
        assert_eq!(parse(values.clone()), Err(line.to_owned()), "{values:?}");
    }
}

#[test]
fn a_link_in_the_place_of_another_argument_is_not_printed() {
    let link = good_link();
    let attached = format!("--pair={link}");
    for values in [
        args(&[&link]),
        args(&[&attached]),
        args(&["--remote", &link]),
        args(&["--nope", &link]),
    ] {
        let line = parse(values.clone()).unwrap_err();
        assert!(!line.contains("tok-fixed"), "{line}");
        assert!(!line.contains(&link), "{line}");
        // A link that the app names shows its prefix and no body.
        if line.contains("helyx-pair:") {
            assert!(line.contains("helyx-pair:…"), "{line}");
        }
    }
}
