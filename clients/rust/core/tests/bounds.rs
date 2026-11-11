//! The client has the bounds and the error codes of
//! `test/fixtures/wire/bounds.json`, the one file that the server tests read too.

use helyx_client_core::json::{Json, decode};
use helyx_client_core::{frame, operation, parts};

#[test]
fn the_client_has_the_bounds_of_the_file() {
    let text = include_str!("../../../../test/fixtures/wire/bounds.json");
    let bounds = decode(text).unwrap();
    let int = |v: &Json, key: &str| v.get(key).and_then(Json::as_u64).unwrap();

    assert_eq!(parts::FRAME_BYTES as u64, int(&bounds, "frame_bytes"));
    assert_eq!(parts::PART_BYTES as u64, int(&bounds, "part_bytes"));
    assert_eq!(parts::REQUEST_BYTES as u64, int(&bounds, "request_bytes"));

    let deadlines = bounds.get("deadlines_ms").unwrap();
    for (key, op) in [
        ("default", "prompt"),
        ("subscribe", "subscribe"),
        ("abort", "abort"),
        ("stop", "stop"),
    ] {
        let ms = operation::deadline(op).unwrap().as_millis() as u64;
        assert_eq!(ms, int(deadlines, key), "{op}");
    }

    let codes: Vec<&str> = bounds
        .get("error_codes")
        .and_then(Json::as_array)
        .unwrap()
        .iter()
        .map(|code| code.as_str().unwrap())
        .collect();
    assert_eq!(frame::ERROR_CODES, codes.as_slice());
}
