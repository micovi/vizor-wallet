//! The two trust anchors a Nyctis channel has that the indexer does not get to supply.
//!
//! Everything the indexer serves is data availability: message bodies, the verifying key, the
//! state root it computed. The replay checks every proof, recomputes every `msg_id` and rebuilds
//! the whole state, so a hostile indexer cannot forge a balance — **provided the key the proofs
//! are checked against is the channel's**. A key is only a hash away from being anyone's: an
//! indexer that ran its own ceremony holds the toxic waste for its own key and can prove anything
//! against it, and it can publish that key's hash in `/api/status` just as easily as the real one.
//! Comparing the key with a hash from the same server therefore pins nothing. What pins it is a
//! value that did not come from the indexer at all, carried in the channel configuration next to
//! the channel's UIVK, and that is [`check_vk_pin`].
//!
//! The second anchor is the pair the channel configuration is made of: the UIVK the wallet reads
//! with and the unified address it writes to. They are two independent settings, and a pair that
//! does not belong together reads channel A and pays into channel B — the ZEC is spent and the
//! payment never appears where the wallet looks. [`check_channel_address`] refuses such a pair.

use nyctis_zk::prover::vk_hash_bytes;
use zcash_keys::address::Address as ZcashAddress;
use zcash_keys::keys::UnifiedIncomingViewingKey;

use crate::wallet::network::WalletNetwork;

/// What a pin error starts with, so a caller that only has the message can still tell "this key
/// is not the channel's" from every other reason a replay can fail.
pub const VK_PIN_ERROR_PREFIX: &str = "verifying key not trusted:";

/// Parse the configured `vk_hash` pin: 32 bytes of hex.
///
/// **Empty is an error, not "no pin".** A channel configuration without a pin is one the wallet
/// cannot verify anything on, and falling back to the indexer's own hash in that case is exactly
/// the unpinned behaviour this module exists to remove.
pub fn parse_vk_pin(pinned: &str) -> Result<[u8; 32], String> {
    let trimmed = pinned.trim();
    if trimmed.is_empty() {
        return Err(format!(
            "{VK_PIN_ERROR_PREFIX} no verifying-key hash is pinned for this channel, so no proof \
             on it can be checked against a key this wallet trusts"
        ));
    }
    let raw = hex::decode(trimmed).map_err(|e| {
        format!("{VK_PIN_ERROR_PREFIX} the pinned verifying-key hash {trimmed:?} is not hex: {e}")
    })?;
    raw.try_into().map_err(|_| {
        format!("{VK_PIN_ERROR_PREFIX} the pinned verifying-key hash {trimmed:?} is not 32 bytes")
    })
}

/// Refuse `vk` unless it is the key the channel configuration pins.
///
/// The hash is `nyctis_zk::prover::vk_hash_bytes` — `BLAKE2b-256` of the compressed key bytes,
/// exactly as `/api/vk` serves them and as `zk-setup` writes into the `.circuit` sidecar — and it
/// is taken over the **whole** buffer, so a key with trailing bytes is a different key here, as
/// it is to `Groth16Verifier::from_vk_bytes`. Returns the hash on success so a caller can report
/// the identity it verified.
///
/// This runs before a single proof is verified and regardless of what `/api/status` says: the
/// indexer's advertised hash is a claim about its own key, and agreeing with it is not evidence.
pub fn check_vk_pin(vk: &[u8], pinned: &str) -> Result<[u8; 32], String> {
    let want = parse_vk_pin(pinned)?;
    let got = vk_hash_bytes(vk);
    if got != want {
        return Err(format!(
            "{VK_PIN_ERROR_PREFIX} the indexer served a verifying key hashing to {}, but this \
             channel pins {}. Proofs checked against it would prove nothing, so none are",
            hex::encode(got),
            hex::encode(want),
        ));
    }
    Ok(got)
}

/// Refuse a channel address that the channel UIVK cannot receive at.
///
/// The Ironwood receiver of `address` must be one of the UIVK's own diversified addresses
/// (`diversifier_index` is `Some`), and the address must be for `network`. A Nyctis memo rides
/// an Ironwood output, so the Ironwood half is the one that has to match; a transparent or
/// Sapling receiver in the same UA is irrelevant to the channel and is not checked.
pub fn check_channel_address(
    network: WalletNetwork,
    channel_uivk: &str,
    address: &str,
) -> Result<(), String> {
    let uivk = UnifiedIncomingViewingKey::decode(&network, channel_uivk.trim())
        .map_err(|e| format!("The channel viewing key does not decode on this network: {e}"))?;
    let ivk = uivk.orchard().clone().ok_or_else(|| {
        "The channel viewing key has no Ironwood component, so it cannot read a channel."
            .to_string()
    })?;
    let decoded = ZcashAddress::decode(&network, address.trim()).ok_or_else(|| {
        "The channel address is not a unified address for this network.".to_string()
    })?;
    let ZcashAddress::Unified(ua) = decoded else {
        return Err(
            "The channel address is not a unified address, so it has no Ironwood receiver."
                .to_string(),
        );
    };
    let receiver = ua.orchard().ok_or_else(|| {
        "The channel address has no Ironwood receiver, so no Nyctis memo can be sent to it."
            .to_string()
    })?;
    if ivk.diversifier_index(receiver).is_none() {
        return Err(
            "The channel address does not belong to the channel viewing key: this wallet would \
             read one channel and pay into another. Check the channel in Nyctis settings."
                .to_string(),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use zcash_keys::keys::{ReceiverRequirement, UnifiedAddressRequest, UnifiedSpendingKey};

    /// The hash the live devnet's `zk-setup` printed for circuit_version 0x05
    /// (`constraints=136263;instances=32;vk_hash=a860…a51a`).
    const DEVNET_V5_VK_HASH: &str =
        "a8600f3032389c0ea927b88b2814631b0880619ce38ec13f590495526373a51a";

    /// `vk_hash_bytes` is BLAKE2b-256 with a 32-byte digest over the raw buffer — pinned here
    /// against the textbook value so a change of hash function (or of personalisation) upstream
    /// shows up as a failing test rather than as every pin on every channel silently failing.
    #[test]
    fn the_pin_hash_is_blake2b_256_of_the_key_bytes() {
        // BLAKE2b-256("") from RFC 7693's reference implementation.
        assert_eq!(
            hex::encode(vk_hash_bytes(b"")),
            "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"
        );
        assert_eq!(check_vk_pin(b"", "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8").unwrap(), vk_hash_bytes(b""));
    }

    /// The devnet key folder, when this machine has one: the real 0x05 key must hash to the value
    /// its ceremony printed, through the same function the pin check uses. Skips (with a reason)
    /// on a machine without the devnet, since the key is not checked in.
    #[test]
    fn the_devnet_key_hashes_to_the_pinned_ceremony_value() {
        let dir = std::env::var("NYCTIS_KEYS_DIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| {
                std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../../nyctis/.devnet/keys")
            });
        let Ok(vk) = std::fs::read(dir.join("interpreter-v0.vk")) else {
            eprintln!("skipping: no devnet verifying key at {}", dir.display());
            return;
        };
        if !std::fs::read_to_string(dir.join("interpreter-v0.circuit"))
            .unwrap_or_default()
            .contains(DEVNET_V5_VK_HASH)
        {
            eprintln!("skipping: the devnet at {} is not the 0x05 ceremony", dir.display());
            return;
        }
        assert_eq!(hex::encode(check_vk_pin(&vk, DEVNET_V5_VK_HASH).unwrap()), DEVNET_V5_VK_HASH);
        assert!(check_vk_pin(&vk, &"00".repeat(32)).is_err());
    }

    /// A key whose hash is not the pin is refused whatever else is true of it, and the error says
    /// which is which. One flipped byte and one trailing byte are both a different key.
    #[test]
    fn a_key_that_is_not_the_pinned_one_is_refused() {
        let vk = vec![7u8; 1784];
        let pin = hex::encode(vk_hash_bytes(&vk));
        assert!(check_vk_pin(&vk, &pin).is_ok());
        assert!(check_vk_pin(&vk, &pin.to_uppercase()).is_ok(), "hex case is not identity");

        let mut flipped = vk.clone();
        flipped[0] ^= 1;
        let e = check_vk_pin(&flipped, &pin).unwrap_err();
        assert!(e.starts_with(VK_PIN_ERROR_PREFIX), "{e}");
        assert!(e.contains(&pin), "{e}");

        let mut padded = vk.clone();
        padded.push(b'\n');
        assert!(check_vk_pin(&padded, &pin).is_err());
    }

    /// **A missing pin fails closed.** Empty, blank, malformed and short pins are all refusals,
    /// never a fall-back to trusting whatever key arrived.
    #[test]
    fn a_missing_or_malformed_pin_is_a_refusal_not_a_fallback() {
        let vk = vec![1u8; 64];
        for pin in ["", "   ", "not hex", "0e0f", &"zz".repeat(32)] {
            let e = check_vk_pin(&vk, pin).unwrap_err();
            assert!(e.starts_with(VK_PIN_ERROR_PREFIX), "{pin:?}: {e}");
        }
    }

    fn channel_pair(seed: &[u8]) -> (String, String) {
        let network = WalletNetwork::Regtest;
        let usk = UnifiedSpendingKey::from_seed(&network, seed, zip32::AccountId::ZERO).unwrap();
        let ufvk = usk.to_unified_full_viewing_key();
        let uivk = ufvk.to_unified_incoming_viewing_key();
        let request = UnifiedAddressRequest::custom(
            ReceiverRequirement::Require,
            ReceiverRequirement::Omit,
            ReceiverRequirement::Omit,
        )
        .unwrap();
        let (ua, _) = ufvk.default_address(request).unwrap();
        (uivk.encode(&network), ua.encode(&network))
    }

    #[test]
    fn a_channel_address_is_accepted_only_with_its_own_viewing_key() {
        let (uivk_a, addr_a) = channel_pair(&[1u8; 32]);
        let (uivk_b, addr_b) = channel_pair(&[2u8; 32]);
        check_channel_address(WalletNetwork::Regtest, &uivk_a, &addr_a).unwrap();
        check_channel_address(WalletNetwork::Regtest, &uivk_b, &addr_b).unwrap();
        // pasted with whitespace is still the same pair
        check_channel_address(WalletNetwork::Regtest, &format!(" {uivk_a}\n"), &format!("{addr_a} "))
            .unwrap();

        let e = check_channel_address(WalletNetwork::Regtest, &uivk_a, &addr_b).unwrap_err();
        assert!(e.contains("does not belong"), "{e}");
        let e = check_channel_address(WalletNetwork::Regtest, &uivk_b, &addr_a).unwrap_err();
        assert!(e.contains("does not belong"), "{e}");
    }

    #[test]
    fn a_malformed_or_foreign_channel_is_refused_with_a_sentence() {
        let (uivk, addr) = channel_pair(&[3u8; 32]);
        assert!(check_channel_address(WalletNetwork::Regtest, "uivk-nonsense", &addr).is_err());
        assert!(check_channel_address(WalletNetwork::Regtest, &uivk, "not an address").is_err());
        // a regtest pair checked as mainnet decodes as neither
        assert!(check_channel_address(WalletNetwork::Main, &uivk, &addr).is_err());
    }
}
