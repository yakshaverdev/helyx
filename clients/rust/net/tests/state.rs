//! The state file of a paired client: the mode of the file and its folder,
//! the checks of a read, and the write that never replaces a state without a
//! new pairing (`docs/features/client-kit.md`, "A remote server").

use helyx_client_core::key::Key;
use helyx_client_net as net;
use net::state::{FileStore, MAX_STATE_BYTES, State, Store};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// A fresh folder of a test, with a `clients` folder inside.
fn folder(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("helyx-state-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("clients")).unwrap();
    std::fs::set_permissions(dir.join("clients"), std::fs::Permissions::from_mode(0o700)).unwrap();
    dir
}

fn store(dir: &Path) -> FileStore {
    FileStore::new(dir.join("clients"))
}

fn state(name: &str) -> State {
    net::stub::state(4_000, name, Key::generate())
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn a_write_leaves_0600_in_a_0700_folder() {
    let dir = folder("write");
    let store = store(&dir);
    store.save(&state("phone"), true).unwrap();
    let path = store.path("phone");
    assert_eq!(mode(&path), 0o600);
    assert_eq!(mode(&dir.join("clients")), 0o700);
    // A load gives the state back, every field.
    let loaded = store.load("phone").unwrap().expect("the state");
    assert_eq!(
        (loaded.host.as_str(), loaded.port, loaded.name.as_str()),
        ("127.0.0.1", 4_000, "phone")
    );
    assert_eq!(loaded.pin, net::stub::pin());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_second_write_without_a_new_pairing_keeps_the_first() {
    let dir = folder("replace");
    let store = store(&dir);
    store.save(&state("phone"), true).unwrap();
    let second = state("phone");
    let line = store.save(&second, false).unwrap_err();
    assert!(line.contains("pair again"), "{line}");
    // The first state is still the one that loads.
    let loaded = store.load("phone").unwrap().unwrap();
    assert_ne!(loaded.key.public_key(), second.key.public_key());
    // A new pairing of the name replaces it.
    store.save(&second, true).unwrap();
    let loaded = store.load("phone").unwrap().unwrap();
    assert_eq!(loaded.key.public_key(), second.key.public_key());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_symlink_is_refused() {
    let dir = folder("symlink");
    let store = store(&dir);
    let target = dir.join("elsewhere.json");
    std::fs::write(&target, state("phone").to_bytes()).unwrap();
    std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::os::unix::fs::symlink(&target, store.path("phone")).unwrap();
    let line = store.load("phone").unwrap_err();
    assert!(line.contains("is a symlink"), "{line}");
    assert!(line.contains("phone.json"), "{line}");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_loose_mode_is_refused_with_the_file() {
    let dir = folder("loose");
    let store = store(&dir);
    store.save(&state("phone"), true).unwrap();
    let path = store.path("phone");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    let line = store.load("phone").unwrap_err();
    assert!(line.contains("readable by other users"), "{line}");
    assert!(line.contains("phone.json"), "{line}");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_file_that_is_not_there_is_no_state() {
    let dir = folder("absent");
    let store = store(&dir);
    assert!(store.load("phone").unwrap().is_none());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_cut_json_a_missing_field_and_a_large_file_are_refused() {
    let dir = folder("broken");
    let store = store(&dir);
    let path = store.path("phone");
    let write = |text: &str| {
        std::fs::write(&path, text).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    };
    let good = String::from_utf8(state("phone").to_bytes()).unwrap();
    for (text, what) in [
        (good[..good.len() / 2].to_owned(), "cut"),
        (good.replace("\"pin\":", "\"pinn\":"), "missing field"),
        (good.replace("\"port\":4000", "\"port\":0"), "a port"),
        (
            good.replace("\"name\":\"phone\"", "\"name\":\"Phone\""),
            "a name",
        ),
        (
            format!("{good}{}", " ".repeat(MAX_STATE_BYTES as usize)),
            "over",
        ),
    ] {
        write(&text);
        let line = store.load("phone").unwrap_err();
        assert!(
            line.contains("is not valid") || line.contains("is over its size"),
            "{what}: {line}"
        );
    }
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_file_that_is_not_regular_is_refused() {
    let dir = folder("folder");
    let store = store(&dir);
    std::fs::create_dir(store.path("phone")).unwrap();
    let line = store.load("phone").unwrap_err();
    assert!(line.contains("is not a regular file"), "{line}");
    std::fs::remove_dir_all(dir).unwrap();
}
