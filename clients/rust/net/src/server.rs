//! The server that a connection reaches (`docs/features/client-kit.md`, "A
//! remote server"): the local server of today, with the token of its
//! handshake, or a remote server over TLS with the pin of its certificate.
//! `Debug` holds no token and no key byte.

use crate::state::{State, Store};
use helyx_client_core::handshake::{Credential, Token};
use helyx_client_core::key::Key;
use helyx_client_core::link::Link;
use std::net::{IpAddr, Ipv6Addr};

/// The server of one connection.
#[derive(Clone)]
pub enum Server {
    /// The local server of today: the loopback address, the port, and the
    /// token of its handshake.
    Local {
        address: IpAddr,
        port: u16,
        token: String,
    },
    /// A remote server over TLS: the state of a paired client, and the
    /// bootstrap token of a pairing that has not finished. No token is a
    /// paired client.
    Remote { state: State, token: Option<Token> },
}

impl Server {
    /// The local server at `address`:`port`, which proves `token`.
    pub fn local(address: IpAddr, port: u16, token: impl Into<String>) -> Server {
        Server::Local {
            address,
            port,
            token: token.into(),
        }
    }

    /// The paired client of a saved state.
    pub fn paired(state: State) -> Server {
        Server::Remote { state, token: None }
    }

    /// The pairing of `link`, with the key that the pairing made.
    pub fn pairing(link: &Link, key: Key) -> Server {
        Server::Remote {
            state: State {
                host: link.host.clone(),
                port: link.port,
                pin: link.pin.clone(),
                name: link.name.clone(),
                key,
            },
            token: Some(link.token.clone()),
        }
    }

    /// The pairing of `link` with a new key, unless `store` holds a state of
    /// the name for another server: a pairing replaces only the state of its
    /// own server, so the key of the other one is not lost. The check runs
    /// before the connection, so the link is not used.
    pub fn pair(link: &Link, store: &dyn Store) -> Result<Server, String> {
        match store.load(&link.name)? {
            Some(old) if (&old.host, old.port, &old.pin) != (&link.host, link.port, &link.pin) => {
                Err(format!(
                    "the name {} is paired with {}:{}; make a link with another name",
                    link.name, old.host, old.port
                ))
            }
            _ => Ok(Server::pairing(link, Key::generate())),
        }
    }

    /// The URL of the WebSocket: `ws://` for a local server, `wss://` for a
    /// remote one.
    pub fn url(&self) -> String {
        match self {
            Server::Local { address, port, .. } => match address {
                IpAddr::V4(ip) => format!("ws://{ip}:{port}"),
                IpAddr::V6(ip) => format!("ws://[{ip}]:{port}"),
            },
            Server::Remote { state, .. } => match state.host.parse::<Ipv6Addr>() {
                Ok(ip) => format!("wss://[{ip}]:{}", state.port),
                Err(_) => format!("wss://{}:{}", state.host, state.port),
            },
        }
    }

    /// The credential of a connection. `pairing` says that this connection is
    /// the first one of a pairing, before its state is saved.
    pub fn credential(&self, pairing: bool) -> Credential {
        match self {
            Server::Local { token, .. } => Credential::token(token.clone()),
            Server::Remote { state, token } => match (pairing, token) {
                (true, Some(token)) => Credential::Pair {
                    token: token.clone(),
                    pin: state.pin.clone(),
                    name: state.name.clone(),
                    key: state.key.clone(),
                },
                _ => Credential::Paired {
                    pin: state.pin.clone(),
                    name: state.name.clone(),
                    key: state.key.clone(),
                },
            },
        }
    }

    /// Whether this server is a pairing whose state is not saved yet.
    pub fn is_pairing(&self) -> bool {
        matches!(self, Server::Remote { token: Some(_), .. })
    }

    /// The state of a remote server.
    pub fn state(&self) -> Option<&State> {
        match self {
            Server::Local { .. } => None,
            Server::Remote { state, .. } => Some(state),
        }
    }

    /// The address, the port, and the token of a local server, for a host
    /// that starts a connection from them.
    pub fn local_parts(&self) -> Option<(IpAddr, u16, &str)> {
        match self {
            Server::Local {
                address,
                port,
                token,
            } => Some((*address, *port, token)),
            Server::Remote { .. } => None,
        }
    }
}

impl std::fmt::Debug for Server {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Server({})", self.url())
    }
}
