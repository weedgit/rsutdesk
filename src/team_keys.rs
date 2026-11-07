//! Team edition: remembered public keys of LAN desktops ("trust on first use", like SSH).
//!
//! There is no ID server to vouch for a desktop's key, so the controller remembers the key a
//! desktop shows on the first connection and expects the same key afterwards. Sessions are
//! encrypted either way; a changed key is held back until the user confirms it.

use hbb_common::{
    config::{self, Config},
    log,
    protobuf::{Message as _, UnknownValueRef},
    sodiumoxide::crypto::sign,
};
use serde_derive::{Deserialize, Serialize};
use std::{collections::HashMap, path::PathBuf, sync::Mutex};

use hbb_common::rendezvous_proto::IdPk;

/// Unknown-field number in the signed `IdPk` that carries the desktop's long-term signing key.
/// An unknown field keeps the shared protocol definition untouched; older builds ignore it.
pub const SIGN_PK_FIELD: u32 = 1001;

#[derive(Debug, Default, Serialize, Deserialize)]
struct KnownKeys {
    #[serde(default)]
    keys: HashMap<String, String>,
}

lazy_static::lazy_static! {
    static ref LOCK: Mutex<()> = Mutex::new(());
    /// Keys that differed from the remembered one, waiting for the user's decision.
    static ref CHANGED: Mutex<HashMap<String, Vec<u8>>> = Default::default();
}

fn file() -> PathBuf {
    Config::path("team_known_keys.toml")
}

fn norm(peer: &str) -> String {
    peer.trim().to_lowercase()
}

/// Adds our long-term signing key to the `IdPk` the desktop signs during the handshake.
pub fn attach_sign_pk(id_pk: &mut IdPk, sign_pk: &[u8]) {
    id_pk
        .mut_unknown_fields()
        .add_length_delimited(SIGN_PK_FIELD, sign_pk.to_vec());
}

/// The signing key a desktop put inside its signed `IdPk`. Not yet verified: the caller checks
/// the signature with it, then compares it with the remembered key.
pub fn signed_sign_pk(signed: &[u8]) -> Option<[u8; sign::PUBLICKEYBYTES]> {
    if signed.len() <= sign::SIGNATUREBYTES {
        return None;
    }
    let id_pk = IdPk::parse_from_bytes(&signed[sign::SIGNATUREBYTES..]).ok()?;
    match id_pk.unknown_fields().get(SIGN_PK_FIELD) {
        Some(UnknownValueRef::LengthDelimited(b)) if b.len() == sign::PUBLICKEYBYTES => {
            let mut pk = [0u8; sign::PUBLICKEYBYTES];
            pk.copy_from_slice(b);
            Some(pk)
        }
        _ => None,
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum KeyCheck {
    /// First connection: the key is now remembered.
    New,
    Match,
    /// Differs from the remembered key; held until [`trust`] or the next connection.
    Changed,
}

pub fn check(peer: &str, sign_pk: &[u8]) -> KeyCheck {
    let peer = norm(peer);
    let encoded = crate::encode64(sign_pk);
    let _lock = LOCK.lock().unwrap();
    let mut known: KnownKeys = config::load_path(file());
    match known.keys.get(&peer) {
        Some(saved) if *saved == encoded => {
            CHANGED.lock().unwrap().remove(&peer);
            KeyCheck::Match
        }
        Some(_) => {
            log::warn!("LAN key of {} changed since the last connection", peer);
            CHANGED.lock().unwrap().insert(peer, sign_pk.to_vec());
            KeyCheck::Changed
        }
        None => {
            log::info!("Remembering LAN key of {}", peer);
            known.keys.insert(peer, encoded);
            if let Err(e) = config::store_path(file(), known) {
                log::error!("Failed to save LAN key: {}", e);
            }
            KeyCheck::New
        }
    }
}

/// The changed key of `peer` waiting for the user's decision, if any.
pub fn take_changed(peer: &str) -> Option<Vec<u8>> {
    CHANGED.lock().unwrap().remove(&norm(peer))
}

/// Replaces the remembered key of `peer` after the user accepted it.
pub fn trust(peer: &str, sign_pk: &[u8]) {
    let peer = norm(peer);
    let _lock = LOCK.lock().unwrap();
    let mut known: KnownKeys = config::load_path(file());
    known.keys.insert(peer.clone(), crate::encode64(sign_pk));
    match config::store_path(file(), known) {
        Ok(()) => log::info!("Trusted new LAN key of {}", peer),
        Err(e) => log::error!("Failed to save LAN key: {}", e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_pk_round_trips_through_signed_id_pk() {
        let (pk, sk) = sign::gen_keypair();
        let mut id_pk = IdPk {
            id: "123".to_owned(),
            pk: vec![7u8; 32].into(),
            ..Default::default()
        };
        attach_sign_pk(&mut id_pk, &pk.0);
        let signed = sign::sign(&id_pk.write_to_bytes().unwrap(), &sk);
        assert_eq!(signed_sign_pk(&signed), Some(pk.0));
        // The signature still verifies, and the regular fields survive.
        let (id, box_pk, _, _) = crate::common::decode_id_pk_dtls(&signed, &pk).unwrap();
        assert_eq!(id, "123");
        assert_eq!(box_pk, [7u8; 32]);
    }

    #[test]
    fn missing_field_means_old_build() {
        let (_, sk) = sign::gen_keypair();
        let id_pk = IdPk {
            id: "123".to_owned(),
            pk: vec![7u8; 32].into(),
            ..Default::default()
        };
        let signed = sign::sign(&id_pk.write_to_bytes().unwrap(), &sk);
        assert_eq!(signed_sign_pk(&signed), None);
        assert_eq!(signed_sign_pk(&[0u8; 10]), None);
    }
}
