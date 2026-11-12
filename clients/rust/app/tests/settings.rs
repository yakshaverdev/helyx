//! The read of the server file of a data folder, at its bounds.

use helyx_desktop::settings::{MAX_FILE_BYTES, read};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

/// A fresh data folder of mode 0700 for the test `name`.
fn folder(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("helyx-desktop-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    dir
}

const GOOD: &str = r#"{"address":"127.0.0.1","port":4000,"token":"t"}"#;

#[test]
fn a_valid_file_gives_the_server_and_debug_hides_the_token() {
    let dir = folder("valid");
    std::fs::write(dir.join("server.json"), GOOD).unwrap();
    let server = read(&dir).unwrap();
    assert_eq!(server.url(), "ws://127.0.0.1:4000");
    assert_eq!(server.local_parts().unwrap().2, "t");
    assert!(!format!("{server:?}").contains("\"t\""));
    let v6 = r#"{"address":"::1","port":1,"token":"t"}"#;
    std::fs::write(dir.join("server.json"), v6).unwrap();
    assert_eq!(read(&dir).unwrap().url(), "ws://[::1]:1");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_folder_that_others_can_write_is_refused() {
    let dir = folder("writable");
    std::fs::write(dir.join("server.json"), GOOD).unwrap();
    for mode in [0o720, 0o702] {
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(mode)).unwrap();
        assert!(
            read(&dir).unwrap_err().contains("other users can write"),
            "{mode:o}"
        );
    }
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_file_out_of_its_bounds_is_not_valid() {
    let dir = folder("bounds");
    let file = dir.join("server.json");
    let pad = |n: usize| format!("{GOOD}{}", " ".repeat(n - GOOD.len()));
    std::fs::write(&file, pad(MAX_FILE_BYTES as usize)).unwrap();
    assert!(read(&dir).is_ok());
    std::fs::write(&file, pad(MAX_FILE_BYTES as usize + 1)).unwrap();
    assert_eq!(read(&dir).unwrap_err(), "the server file is not valid");
    for bad in [
        r#"{"address":"localhost","port":4000,"token":"t"}"#,
        r#"{"address":"127.0.0.1","port":0,"token":"t"}"#,
        r#"{"address":"127.0.0.1","port":65536,"token":"t"}"#,
        r#"{"address":"127.0.0.1","port":4000}"#,
        r#"{"address":"127.0.0.1","port":4000,"token":1}"#,
        "not json",
    ] {
        std::fs::write(&file, bad).unwrap();
        assert_eq!(
            read(&dir).unwrap_err(),
            "the server file is not valid",
            "{bad}"
        );
    }
    std::fs::remove_file(&file).unwrap();
    std::os::unix::fs::symlink(dir.join("elsewhere"), &file).unwrap();
    assert!(read(&dir).is_err());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_missing_folder_is_no_server() {
    let dir = std::env::temp_dir().join(format!("helyx-desktop-{}-missing", std::process::id()));
    assert_eq!(
        read(&dir).unwrap_err(),
        "no server runs for the data folder"
    );
    let file = folder("file").join("plain");
    std::fs::write(&file, "x").unwrap();
    assert!(read(&file).unwrap_err().contains("is not a directory"));
}
