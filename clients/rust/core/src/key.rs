//! The Ed25519 key of a pairing (`docs/features/remote-hands.md`, "Peers").
//! A pairing makes a key with the system random source, and the private key
//! signs the signature text of each `hello`. The seed and the key pair are in
//! no `Debug` form, log, or error text: `Key` shows no byte of them.

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{ED25519, Ed25519KeyPair, KeyPair, UnparsedPublicKey};
use std::sync::Arc;

/// The bytes of the seed of a key.
pub const SEED_BYTES: usize = 32;
/// The bytes of a public key.
pub const PUBLIC_KEY_BYTES: usize = 32;
/// The bytes of a signature.
pub const SIGNATURE_BYTES: usize = 64;

/// A key pair of Ed25519: the seed that it was made from, and the pair that
/// signs. A clone shares the pair.
#[derive(Clone)]
pub struct Key {
    seed: [u8; SEED_BYTES],
    pair: Arc<Ed25519KeyPair>,
}

impl Key {
    /// A new key from the system random source.
    pub fn generate() -> Key {
        let mut seed = [0u8; SEED_BYTES];
        SystemRandom::new()
            .fill(&mut seed)
            .expect("the system random source");
        Key::from_seed(seed).expect("a seed of 32 bytes")
    }

    /// The key of `seed`, or none when the seed makes no key.
    pub fn from_seed(seed: [u8; SEED_BYTES]) -> Option<Key> {
        let pair = Ed25519KeyPair::from_seed_unchecked(&seed).ok()?;
        Some(Key {
            seed,
            pair: Arc::new(pair),
        })
    }

    /// The seed that the key was made from: the bytes that its saved state
    /// holds.
    pub fn seed(&self) -> [u8; SEED_BYTES] {
        self.seed
    }

    /// The public key as the base64 that a `hello` carries.
    pub fn public_key(&self) -> String {
        STANDARD.encode(self.pair.public_key().as_ref())
    }

    /// The signature of `text` as the base64 that a `hello` carries.
    pub fn sign(&self, text: &[u8]) -> String {
        STANDARD.encode(self.pair.sign(text).as_ref())
    }
}

impl PartialEq for Key {
    fn eq(&self, other: &Key) -> bool {
        self.seed == other.seed
    }
}

impl Eq for Key {}

impl std::fmt::Debug for Key {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Key(..)")
    }
}

/// Whether `signature` is the signature of `text` with `public_key`, both as
/// the base64 that a `hello` carries. A peer checks a signature with it.
pub fn verify(public_key: &str, text: &[u8], signature: &str) -> bool {
    let (Ok(key), Ok(signature)) = (STANDARD.decode(public_key), STANDARD.decode(signature)) else {
        return false;
    };
    if key.len() != PUBLIC_KEY_BYTES || signature.len() != SIGNATURE_BYTES {
        return false;
    }
    UnparsedPublicKey::new(&ED25519, key)
        .verify(text, &signature)
        .is_ok()
}
