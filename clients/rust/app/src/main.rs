//! The reference desktop app of Helyx (`docs/features/client-kit.md`,
//! slice 4): the window on macOS, over the network thread of `net`.

#[cfg(target_os = "macos")]
mod ui;

use helyx_desktop::settings;
use std::path::PathBuf;

fn main() {
    let folder = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .or_else(settings::default_folder);
    let Some(folder) = folder else {
        eprintln!("helyx-desktop: no data folder: give one, or set HOME");
        std::process::exit(1);
    };
    match settings::read(&folder) {
        Ok(server) => start(server),
        Err(line) => {
            eprintln!("helyx-desktop: {line}");
            std::process::exit(1);
        }
    }
}

#[cfg(target_os = "macos")]
fn start(server: settings::Server) {
    ui::run(server);
}

#[cfg(not(target_os = "macos"))]
fn start(_server: settings::Server) {
    eprintln!("helyx-desktop: the window runs on macOS only");
    std::process::exit(1);
}
