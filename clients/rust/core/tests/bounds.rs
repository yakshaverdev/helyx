//! The constants of the client equal `test/fixtures/wire/bounds.json`, the one
//! file that holds the numbers of the wire; the server reads the same file.

use helyx_client_core::json::{Json, WIRE, decode};
use helyx_client_core::{frame, handshake, operation, parts, records};

#[test]
fn the_client_has_the_bounds_of_the_file() {
    let bounds = decode(include_str!("../../../../test/fixtures/wire/bounds.json")).unwrap();
    let int = |v: &Json, key: &str| v.get(key).and_then(Json::as_u64).unwrap();

    assert_eq!(handshake::PROTOCOL, int(&bounds, "protocol"));
    assert_eq!(parts::FRAME_BYTES as u64, int(&bounds, "frame_bytes"));
    assert_eq!(parts::PART_BYTES as u64, int(&bounds, "part_bytes"));
    assert_eq!(parts::REQUEST_BYTES as u64, int(&bounds, "request_bytes"));
    assert_eq!(WIRE.frame_bytes as u64, int(&bounds, "server_frame_bytes"));
    assert_eq!(WIRE.values as u64, int(&bounds, "server_frame_values"));
    assert_eq!(WIRE.integer_chars as u64, int(&bounds, "integer_chars"));
    assert_eq!(records::MAX_ROWS as u64, int(&bounds, "record_rows"));

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
