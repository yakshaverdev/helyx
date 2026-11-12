//! The state of a paired client (`docs/features/client-kit.md`, "A remote
//! server"): the address, the pin, the name, and the key, saved in
//! `<home>/.helyx/clients/<name>.json` with mode 0600 in a folder of mode
//! 0700. The storage is one trait, `Store`, so a keychain store is a later
//! change of one place; this build implements the file store only.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use helyx_client_core::json::{Json, decode, object};
use helyx_client_core::key::{Key, SEED_BYTES};
use helyx_client_core::link::{name_ok, pin_ok};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// The bytes of a state file: the five fields of a state, with a margin.
pub const MAX_STATE_BYTES: u64 = 4_096;
/// The mode of the state file: the user reads and writes it.
#[cfg(unix)]
const FILE_MODE: u32 = 0o600;
/// The mode of the folder of the state files.
#[cfg(unix)]
const FOLDER_MODE: u32 = 0o700;
/// The attempts to make the temp file of a write.
const TEMP_TRIES: u64 = 3;

/// What a pairing saves: the server, the pin of its certificate, the name of
/// the peer, and the key that the pairing made. `Debug` holds no key byte.
#[derive(Clone, PartialEq, Eq)]
pub struct State {
    /// The host that the link carried: a DNS name or an IP address.
    pub host: String,
    pub port: u16,
    /// The pin of the server's certificate.
    pub pin: String,
    pub name: String,
    pub key: Key,
}

impl State {
    /// The bytes of the saved file: a JSON object with every field.
    pub fn to_bytes(&self) -> Vec<u8> {
        object([
            ("host", Json::String(self.host.clone())),
            ("key", Json::String(URL_SAFE_NO_PAD.encode(self.key.seed()))),
            ("name", Json::String(self.name.clone())),
            ("pin", Json::String(self.pin.clone())),
            ("port", Json::from(u64::from(self.port))),
        ])
        .encode()
        .into_bytes()
    }

    /// The state of `text`, or none when a field is missing, is of the wrong
    /// type, or is out of its bound.
    pub fn from_bytes(text: &str) -> Option<State> {
        let value = decode(text).ok()?;
        let host = string(&value, "host")?;
        if host.is_empty() {
            return None;
        }
        let port = value.get("port").and_then(Json::as_u64)?;
        if !(1..=65_535).contains(&port) {
            return None;
        }
        let pin = string(&value, "pin")?;
        if !pin_ok(pin) {
            return None;
        }
        let name = string(&value, "name")?;
        if !name_ok(name) {
            return None;
        }
        let seed = URL_SAFE_NO_PAD.decode(string(&value, "key")?).ok()?;
        let seed: [u8; SEED_BYTES] = seed.try_into().ok()?;
        Some(State {
            host: host.to_owned(),
            port: port as u16,
            pin: pin.to_owned(),
            name: name.to_owned(),
            key: Key::from_seed(seed)?,
        })
    }
}

impl std::fmt::Debug for State {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "State({}:{}, {})", self.host, self.port, self.name)
    }
}

/// Where the state of a paired client is saved and read. A keychain store
/// implements the same two functions; this build has the file store only.
pub trait Store: Send + Sync {
    /// Saves the state of a pairing. `replace` says that the save is of a new
    /// pairing of the name, so a state of that name may be replaced; a save
    /// without it leaves an existing state as it is.
    fn save(&self, state: &State, replace: bool) -> Result<(), String>;
    /// The state saved for `name`, or none when there is none.
    fn load(&self, name: &str) -> Result<Option<State>, String>;
}

/// The state files of `<home>/.helyx/clients`.
#[derive(Debug, Clone)]
pub struct FileStore {
    folder: PathBuf,
}

impl FileStore {
    /// The store of `folder`.
    pub fn new(folder: impl Into<PathBuf>) -> FileStore {
        FileStore {
            folder: folder.into(),
        }
    }

    /// The store of the default folder, `~/.helyx/clients`, or none when the
    /// home folder is not known.
    pub fn default_store() -> Option<FileStore> {
        std::env::var_os("HOME")
            .map(|home| FileStore::new(PathBuf::from(home).join(".helyx/clients")))
    }

    /// The file of the state of `name`.
    pub fn path(&self, name: &str) -> PathBuf {
        self.folder.join(format!("{name}.json"))
    }

    /// Makes the folder, with mode 0700.
    fn folder(&self) -> Result<(), String> {
        let folder = &self.folder;
        std::fs::create_dir_all(folder)
            .map_err(|e| format!("could not make the folder {}: {e}", folder.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(folder, std::fs::Permissions::from_mode(FOLDER_MODE))
                .map_err(|e| format!("could not set the mode of {}: {e}", folder.display()))?;
        }
        Ok(())
    }
}

impl Store for FileStore {
    fn save(&self, state: &State, replace: bool) -> Result<(), String> {
        if !name_ok(&state.name) {
            return Err("the state name is not 1 to 64 bytes of a-z, 0-9, and _".into());
        }
        let path = self.path(&state.name);
        if !replace && path.exists() {
            return Err(format!(
                "the state file {} exists; pair again to replace it",
                path.display()
            ));
        }
        self.folder()?;
        let bytes = state.to_bytes();
        let temp = self.temp(&path)?;
        let written = (|| {
            let mut file = temp.open()?;
            file.write_all(&bytes)?;
            file.sync_all()
        })();
        if let Err(e) = written {
            let _ = std::fs::remove_file(&temp.1);
            return Err(format!(
                "could not write the state file {}: {e}",
                path.display()
            ));
        }
        // A rename leaves the old file or the new one, never a half of each.
        std::fs::rename(&temp.1, &path).map_err(|e| {
            let _ = std::fs::remove_file(&temp.1);
            format!("could not save the state file {}: {e}", path.display())
        })
    }

    fn load(&self, name: &str) -> Result<Option<State>, String> {
        if !name_ok(name) {
            return Ok(None);
        }
        let path = self.path(name);
        let shown = path.display();
        let meta = match std::fs::symlink_metadata(&path) {
            Ok(meta) => meta,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("could not read the state file {shown}: {e}")),
        };
        if meta.file_type().is_symlink() {
            return Err(format!("the state file {shown} is a symlink"));
        }
        if !meta.is_file() {
            return Err(format!("the state file {shown} is not a regular file"));
        }
        if meta.len() > MAX_STATE_BYTES {
            return Err(over(&shown));
        }
        mode_ok(&meta, &shown)?;
        let mut text = String::new();
        let file = std::fs::File::open(&path)
            .map_err(|e| format!("could not read the state file {shown}: {e}"))?;
        // The file can grow between the stat and the read.
        file.take(MAX_STATE_BYTES + 1)
            .read_to_string(&mut text)
            .map_err(|_| format!("the state file {shown} is not valid"))?;
        if text.len() as u64 > MAX_STATE_BYTES {
            return Err(over(&shown));
        }
        State::from_bytes(&text)
            .map(Some)
            .ok_or_else(|| format!("the state file {shown} is not valid"))
    }
}

/// The temp file of a save and its path: created here, so a write never
/// follows a link that another user left at its name.
struct Temp(std::fs::File, PathBuf);

impl Temp {
    fn open(&self) -> std::io::Result<std::fs::File> {
        self.0.try_clone()
    }
}

impl FileStore {
    fn temp(&self, path: &Path) -> Result<Temp, String> {
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("state");
        for try_ in 0..TEMP_TRIES {
            let temp = self
                .folder
                .join(format!(".{name}.{}.{try_}.tmp", std::process::id()));
            let mut options = std::fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(FILE_MODE);
            }
            match options.open(&temp) {
                Ok(file) => return Ok(Temp(file, temp)),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => {
                    return Err(format!(
                        "could not make the temp file {}: {e}",
                        temp.display()
                    ));
                }
            }
        }
        Err(format!(
            "could not make the temp file of {}",
            path.display()
        ))
    }
}

fn over(shown: &std::path::Display<'_>) -> String {
    format!("the state file {shown} is over its size")
}

#[cfg(unix)]
fn mode_ok(meta: &std::fs::Metadata, shown: &std::path::Display<'_>) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    if meta.permissions().mode() & 0o077 != 0 {
        return Err(format!(
            "the state file {shown} is readable by other users; run chmod 600 on it"
        ));
    }
    Ok(())
}

// No mode to check: refused, so no unchecked file passes.
#[cfg(not(unix))]
fn mode_ok(_meta: &std::fs::Metadata, shown: &std::path::Display<'_>) -> Result<(), String> {
    Err(format!(
        "the state file {shown} has no mode to check on this platform"
    ))
}

fn string<'a>(value: &'a Json, key: &'static str) -> Option<&'a str> {
    value.get(key).and_then(Json::as_str)
}
