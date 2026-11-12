//! The arguments of the desktop app (`docs/features/client-kit.md`, "A remote
//! server"): `--pair <link>` pairs with the server of a link, `--remote
//! <name>` starts the paired client of a saved state, and a folder, or no
//! argument, keeps the local server of the data folder. A bad argument is one
//! line, and the text of a link is never printed back.

use helyx_client_core::link::{Link, name_ok};
use std::ffi::OsString;
use std::path::PathBuf;

/// What the app starts.
#[derive(Debug, Clone, PartialEq)]
pub enum Launch {
    /// The local server of a data folder, or of the default folder when
    /// there is none.
    Local(Option<PathBuf>),
    /// A pairing with a link, whose state is saved for its name.
    Pair(Link),
    /// The paired client of the saved state of a name.
    Remote(String),
}

/// The launch of the arguments after the program name, or the line that says
/// why there is none.
pub fn parse(args: Vec<OsString>) -> Result<Launch, String> {
    let mut rest = args.into_iter();
    let Some(first) = rest.next() else {
        return Ok(Launch::Local(None));
    };
    let first = first.to_string_lossy().into_owned();
    let value = rest.next();
    if rest.next().is_some() {
        return Err("takes one argument".into());
    }
    match (first.as_str(), value) {
        ("--pair", Some(link)) => Link::parse(&link.to_string_lossy())
            .map(Launch::Pair)
            .map_err(|fault| fault.text().to_owned()),
        ("--pair", None) => Err("--pair takes a link".into()),
        ("--remote", Some(name)) => {
            let name = name.to_string_lossy().into_owned();
            match name_ok(&name) {
                true => Ok(Launch::Remote(name)),
                false => Err("--remote takes a name of 1 to 64 bytes of a-z, 0-9, and _".into()),
            }
        }
        ("--remote", None) => Err("--remote takes a name".into()),
        // A link in the place of another argument is printed with its body
        // replaced: it holds a token.
        (arg, _) if arg.contains("helyx-pair:") => Err(format!("unknown argument {}", shown(arg))),
        (arg, _) if arg.starts_with('-') => Err(format!("unknown argument {}", shown(arg))),
        (_, Some(_)) => Err("takes one argument".into()),
        (folder, None) => Ok(Launch::Local(Some(PathBuf::from(folder)))),
    }
}

/// `arg`, with the body of a link replaced. A line of the app never holds the
/// token of a link.
pub fn shown(arg: &str) -> String {
    const PREFIX: &str = "helyx-pair:";
    match arg.find(PREFIX) {
        Some(at) => format!("{}…", &arg[..at + PREFIX.len()]),
        None => arg.to_owned(),
    }
}
