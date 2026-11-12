//! The reference desktop app of Helyx (`docs/features/client-kit.md`,
//! slice 4 and "A remote server"): the window on macOS, over the network
//! thread of `net`.

#[cfg(target_os = "macos")]
mod ui;

use helyx_desktop::cli::{self, Launch};
use helyx_desktop::net::{FileStore, Server, Store};
use helyx_desktop::settings;
use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::Arc;

fn main() {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    match cli::parse(args) {
        Ok(Launch::Local(folder)) => local(folder),
        Ok(Launch::Pair(link)) => pair(link),
        Ok(Launch::Remote(name)) => remote(&name),
        Err(line) => stop(&line),
    }
}

/// The local server of a data folder, as before.
fn local(folder: Option<std::path::PathBuf>) {
    let folder = folder.or_else(settings::default_folder);
    let Some(folder) = folder else {
        stop("no data folder: give one, or set HOME");
    };
    match settings::read(&folder) {
        // The window reads the folder again before each connection, so a
        // restarted server is found.
        Ok(server) => start(Some(folder), server, None),
        Err(line) => stop(&line),
    }
}

/// A pairing: the state is saved at the `welcome` of its one connection, so
/// the first use needs no second one.
fn pair(link: helyx_client_core::link::Link) {
    let Some(store) = FileStore::default_store() else {
        stop("no home folder: set HOME");
    };
    match Server::pair(&link, &store) {
        Ok(server) => start(None, server, Some(Arc::new(store))),
        Err(line) => stop(&line),
    }
}

/// The paired client of the saved state of `name`.
fn remote(name: &str) {
    let Some(store) = FileStore::default_store() else {
        stop("no home folder: set HOME");
    };
    match store.load(name) {
        Ok(Some(state)) => start(None, Server::paired(state), None),
        Ok(None) => stop(&format!("no saved state for {name}; pair it with --pair")),
        Err(line) => stop(&line),
    }
}

fn stop(line: &str) -> ! {
    eprintln!("helyx-desktop: {line}");
    std::process::exit(1);
}

#[cfg(target_os = "macos")]
fn start(folder: Option<PathBuf>, server: Server, store: Option<Arc<dyn Store>>) {
    ui::run(folder, server, store);
}

#[cfg(not(target_os = "macos"))]
fn start(_folder: Option<PathBuf>, _server: Server, _store: Option<Arc<dyn Store>>) {
    stop("the window runs on macOS only");
}
