//! TLS 1.3 of a remote server, with the pin of its certificate
//! (`docs/features/remote-hands.md`, "Certificate"; `docs/features/
//! client-kit.md`, "A remote server"). The verifier accepts exactly the
//! certificate whose pin is the pin of the link or of the saved state, and
//! checks nothing else of it: no name, no dates, no chain. The handshake
//! signature of the session is still checked with the key of that
//! certificate, so the pin proves the peer holds its key.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::WebPkiSupportedAlgorithms;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{
    ClientConfig, ClientConnection, DigitallySignedStruct, Error, SignatureScheme, StreamOwned,
};
use std::io::ErrorKind;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// The line of a certificate whose pin is not the paired one.
pub const MISMATCH: &str = "the certificate is not the paired one";

/// The TLS stream of a connection: the plaintext side of the socket.
pub type Stream = StreamOwned<ClientConnection, TcpStream>;

/// Connects a TCP socket to `host:port` within `wait` in all. The name
/// resolution is the resolver's own wait: it has no bound here.
pub fn connect(host: &str, port: u16, wait: Duration) -> Result<TcpStream, String> {
    let addrs = (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("could not resolve {host}: {e}"))?;
    let deadline = Instant::now() + wait;
    let mut last = None;
    for addr in addrs {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        match TcpStream::connect_timeout(&addr, left) {
            Ok(stream) => return Ok(stream),
            Err(e) => last = Some(e),
        }
    }
    Err(last.map_or_else(
        || format!("could not connect to {host}:{port}"),
        |e| e.to_string(),
    ))
}

/// The TLS 1.3 handshake of `stream` with the server `host`, which must hold
/// the certificate of `pin`. A read that times out is retried until the
/// watchdog of the connection shuts the socket down.
pub fn handshake(stream: TcpStream, host: &str, pin: &str) -> Result<Stream, String> {
    let rejected = Arc::new(AtomicBool::new(false));
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier = Arc::new(Pinned {
        pin: pin.to_owned(),
        rejected: rejected.clone(),
        algorithms: provider.signature_verification_algorithms,
        schemes: provider
            .signature_verification_algorithms
            .supported_schemes(),
    });
    let config = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|e| e.to_string())?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth();
    let name = ServerName::try_from(host.to_owned())
        .map_err(|_| format!("the host {host} is not a DNS name or an IP address"))?;
    let conn = ClientConnection::new(Arc::new(config), name).map_err(|e| e.to_string())?;
    let mut tls = StreamOwned::new(conn, stream);
    loop {
        match tls.conn.complete_io(&mut tls.sock) {
            Ok(_) if !tls.conn.is_handshaking() => return Ok(tls),
            Ok(_) => continue,
            Err(e) if retry(&e) => continue,
            Err(e) => {
                return Err(match rejected.load(Ordering::SeqCst) {
                    true => MISMATCH.to_owned(),
                    false => e.to_string(),
                });
            }
        }
    }
}

fn retry(e: &std::io::Error) -> bool {
    matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut)
}

/// The pin of a certificate: the base64url, without padding, of the SHA-256
/// of the DER of its SubjectPublicKeyInfo (`Helyx.Transport.WebSocket.TLS.pin/1`).
pub fn pin(der: &[u8]) -> Option<String> {
    let spki = spki(der)?;
    let digest = ring::digest::digest(&ring::digest::SHA256, spki);
    Some(URL_SAFE_NO_PAD.encode(digest.as_ref()))
}

/// The DER of the SubjectPublicKeyInfo of a DER certificate: the seventh
/// element of its TBSCertificate, after the optional version. A certificate
/// of another shape gives none.
fn spki(der: &[u8]) -> Option<&[u8]> {
    let (tag, outer, _, _) = element(der)?;
    if tag != 0x30 {
        return None;
    }
    let (tag, tbs, _, _) = element(outer)?;
    if tag != 0x30 {
        return None;
    }
    let mut rest = tbs;
    // The version is an optional context tag before the serial number.
    if rest.first() == Some(&0xa0) {
        rest = element(rest)?.3;
    }
    // The serial number, the signature, the issuer, the validity, and the
    // subject come before the subject public key info.
    for _ in 0..5 {
        rest = element(rest)?.3;
    }
    let (tag, _, whole, _) = element(rest)?;
    (tag == 0x30).then_some(whole)
}

/// One DER element: its tag, its content, its whole encoding, and the bytes
/// after it.
type Element<'a> = (u8, &'a [u8], &'a [u8], &'a [u8]);

/// One DER element at the start of `der`. A length over three bytes is none:
/// no certificate has one.
fn element(der: &[u8]) -> Option<Element<'_>> {
    let (&tag, rest) = der.split_first()?;
    let (&first, rest) = rest.split_first()?;
    let (len, rest) = match first {
        0x00..=0x7f => (usize::from(first), rest),
        0x81 => {
            let (&n, rest) = rest.split_first()?;
            (usize::from(n), rest)
        }
        0x82 => {
            let (n, rest) = rest.split_at_checked(2)?;
            (usize::from(u16::from_be_bytes(n.try_into().ok()?)), rest)
        }
        0x83 => {
            let (n, rest) = rest.split_at_checked(3)?;
            let n: [u8; 4] = [0, n[0], n[1], n[2]];
            (u32::from_be_bytes(n) as usize, rest)
        }
        _ => return None,
    };
    let (content, after) = rest.split_at_checked(len)?;
    let whole = &der[..der.len() - after.len()];
    Some((tag, content, whole, after))
}

/// The verifier of a pin: it accepts the end certificate whose pin holds, and
/// no other. The TLS handshake signature is checked with the key of that
/// certificate.
#[derive(Debug)]
struct Pinned {
    pin: String,
    rejected: Arc<AtomicBool>,
    algorithms: WebPkiSupportedAlgorithms,
    schemes: Vec<SignatureScheme>,
}

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        match pin(end_entity.as_ref()) {
            Some(pin) if pin == self.pin => Ok(ServerCertVerified::assertion()),
            _ => {
                self.rejected.store(true, Ordering::SeqCst);
                Err(Error::General(MISMATCH.to_owned()))
            }
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.schemes.clone()
    }
}
