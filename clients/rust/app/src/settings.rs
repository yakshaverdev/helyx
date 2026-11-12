//! The server of a data folder, as the TUI finds it
//! (`docs/features/tui-attach.md`, decisions 1 and 2): `<data folder>/server.json`,
//! a regular file of at most 4,096 bytes, a JSON object with `address` an IP
//! address, `port` from 1 to 65535, and `token` a string. A data folder that
//! its group or other users can write is refused: such a user could write a
//! server file that sends the prompts of the user to another server. `source`
//! gives the read to the network thread, which reads the file again before
//! each connection (`docs/features/client-kit.md`, "The network layer").

use helyx_client_core::json::{Json, decode};
use std::io::Read;
use std::path::{Path, PathBuf};

/// The server of the network layer: the address, the port, and the token of
/// its handshake.
pub use helyx_client_net::Server;

/// The bytes of the server file.
pub const MAX_FILE_BYTES: u64 = 4_096;

/// The default data folder of the server, `~/.helyx/sessions`.
pub fn default_folder() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".helyx/sessions"))
}

/// Reads the server of `folder`, or the line that says why there is none.
pub fn read(folder: &Path) -> Result<Server, String> {
    let shown = folder.display();
    let meta = std::fs::metadata(folder).map_err(|e| match e.kind() {
        // A data folder that is not there is no server, as for the TUI.
        std::io::ErrorKind::NotFound => "no server runs for the data folder".to_owned(),
        _ => format!("could not read the data folder {shown}: {e}"),
    })?;
    if !meta.is_dir() {
        return Err(format!("the data folder {shown} is not a directory"));
    }
    if writable_by_others(&meta) {
        return Err(format!(
            "other users can write the data folder {shown}; run chmod go-w on it"
        ));
    }
    let path = folder.join("server.json");
    let file_meta = std::fs::symlink_metadata(&path)
        .map_err(|_| "no server runs for the data folder".to_owned())?;
    let invalid = || "the server file is not valid".to_owned();
    if !file_meta.is_file() || file_meta.len() > MAX_FILE_BYTES {
        return Err(invalid());
    }
    let mut text = String::new();
    let file = std::fs::File::open(&path).map_err(|_| invalid())?;
    // The file can grow between the stat and the read.
    file.take(MAX_FILE_BYTES + 1)
        .read_to_string(&mut text)
        .map_err(|_| invalid())?;
    if text.len() as u64 > MAX_FILE_BYTES {
        return Err(invalid());
    }
    parse(&text).ok_or_else(invalid)
}

/// A source of the server of `folder` for the network thread: it reads the
/// file again at each call, so a server that restarted at another port and
/// with another token is found again (`read`). The app gives it to
/// `helyx_client_net::run`, which calls it before each connection.
pub fn source(folder: &Path) -> impl Fn() -> Result<Server, String> + Send + Sync + 'static {
    let folder = folder.to_path_buf();
    move || read(&folder)
}

fn parse(text: &str) -> Option<Server> {
    let value = decode(text).ok()?;
    let address = value.get("address").and_then(Json::as_str)?.parse().ok()?;
    let port = value
        .get("port")
        .and_then(Json::as_u64)
        .filter(|p| (1..=65_535).contains(p))?;
    let token = value.get("token").and_then(Json::as_str)?.to_owned();
    Some(Server::local(address, port as u16, token))
}

#[cfg(unix)]
fn writable_by_others(meta: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    meta.permissions().mode() & 0o022 != 0
}

// No mode to check: refused, so no unchecked folder passes.
#[cfg(not(unix))]
fn writable_by_others(_meta: &std::fs::Metadata) -> bool {
    true
}
