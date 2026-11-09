//! The server of a data folder, as the TUI finds it
//! (`docs/features/tui-attach.md`, decisions 1 and 2): `<data folder>/server.json`,
//! a regular file of at most 4,096 bytes, a JSON object with `address` an IP
//! address, `port` from 1 to 65535, and `token` a string. A data folder that
//! its group or other users can write is refused: such a user could write a
//! server file that sends the prompts of the user to another server.

use helyx_client_core::json::{Json, decode};
use std::io::Read;
use std::net::IpAddr;
use std::path::{Path, PathBuf};

/// The bytes of the server file.
pub const MAX_FILE_BYTES: u64 = 4_096;

/// The server of a data folder. `Debug` leaves out the token.
#[derive(Clone, PartialEq, Eq)]
pub struct Server {
    pub address: IpAddr,
    pub port: u16,
    pub token: String,
}

impl std::fmt::Debug for Server {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Server({})", self.url())
    }
}

impl Server {
    /// The URL of the WebSocket, as `CodingAgent.Serve.url/2` writes it.
    pub fn url(&self) -> String {
        match self.address {
            IpAddr::V4(ip) => format!("ws://{ip}:{}", self.port),
            IpAddr::V6(ip) => format!("ws://[{ip}]:{}", self.port),
        }
    }
}

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

fn parse(text: &str) -> Option<Server> {
    let value = decode(text).ok()?;
    let address = value.get("address").and_then(Json::as_str)?.parse().ok()?;
    let port = value
        .get("port")
        .and_then(Json::as_u64)
        .filter(|p| (1..=65_535).contains(p))?;
    let token = value.get("token").and_then(Json::as_str)?.to_owned();
    Some(Server {
        address,
        port: port as u16,
        token,
    })
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
