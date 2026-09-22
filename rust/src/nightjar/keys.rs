//! The Nightjar identity a wallet seed already carries.
//!
//! Nightjar derives its account straight from raw seed bytes with a BLAKE2b path that has nothing
//! to do with ZIP 32 (`nightjar_zk::keys::Account::from_seed`), so the identity comes along with
//! whatever seed the wallet is already holding and needs no second backup. That also means the
//! Nightjar account is *not* keyed by ZIP 32 account index: two Vizor accounts derived from one
//! mnemonic at different indices share one Nightjar identity. That is a property of the upstream
//! derivation, not a choice made here; a per-account Nightjar identity would need a domain change
//! in `nightjar-zk`.

use nightjar_zk::keys::Account;

use crate::nightjar::network::NightjarNetwork;
use crate::wallet::network::WalletNetwork;

/// The three public values a user needs to receive Nightjar assets.
pub struct Identity {
    /// Bech32m address, `0x00 ‖ ak ‖ nkc ‖ pk_enc` under this network's prefix.
    pub address: String,
    pub ak: [u8; 32],
    pub nkc: [u8; 32],
}

/// The account a seed names. Infallible by construction, and deliberately kept as the one place
/// this module calls into `nightjar-zk`'s key derivation.
///
/// `SpendAuthority::from_seed` *panics* on a label outside `KEY_LABELS`, which is correct for a
/// workspace where every call site passes a literal. `Account::from_seed` passes the literals
/// `"spend"` and `"issue"`, both listed, so no input this function accepts can reach that
/// assertion — but the guarantee is upstream's to keep, not ours, so everything reachable from
/// the FFI still runs inside the `catch()` guard in `api/nightjar.rs`.
pub fn account(seed: &[u8]) -> Account {
    Account::from_seed(seed)
}

/// Render an account as the identity to show the user on `network`.
pub fn identity(seed: &[u8], network: WalletNetwork) -> Result<Identity, String> {
    let account = account(seed);
    let address = account
        .address()
        .encode(network.nj_hrp())
        .map_err(|e| format!("encoding Nightjar address: {e}"))?;
    Ok(Identity {
        address,
        ak: account.spend.ak_bytes(),
        nkc: account.nkc().to_bytes(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The devnet demo seed and the address, `ak` and `nkc` the Nightjar CLI's `nj-address`
    /// prints for it. Pinned rather than recomputed: this is the value a user backs up and
    /// hands out, so any change to the derivation, to the address layout or to the HRP table
    /// must fail here and not silently reissue everyone a new receive address.
    const DEMO_SEED_HEX: &str = "a22927e214bb3b5f0308f1d440e8133545256e855c1d662734c5a318399ae3ae";
    const DEMO_ADDRESS: &str = "njreg1qzczdd9769asmc88wjuf6pa56vnrf32adr703vrygd0dad9tavmqnqvss7m567y45dkvdhxfngr56l8u2jsvlzh5n0f5j4zs9upfz0c8hn7d8gv3zj5j0np9y0xp39ecnav3j3k7afdu9gwlla22lcyxk58qlyelch";
    const DEMO_AK: &str = "b026b4bed17b0de0e774b89d07b4d32634c55d68fcf8b064435edeb4abeb3609";

    fn demo_seed() -> Vec<u8> {
        hex::decode(DEMO_SEED_HEX).unwrap()
    }

    #[test]
    fn the_demo_seed_derives_the_known_devnet_identity() {
        let id = identity(&demo_seed(), WalletNetwork::Regtest).unwrap();
        assert_eq!(id.address, DEMO_ADDRESS);
        assert_eq!(hex::encode(id.ak), DEMO_AK);
        // the address must actually decode back to the same three keys under the same prefix
        let (hrp, decoded) = nightjar_zk::keys::Address::decode(&id.address).unwrap();
        assert_eq!(hrp, "njreg");
        assert_eq!(decoded.ak, id.ak);
        assert_eq!(decoded.nkc, id.nkc);
    }

    /// One seed, three networks, three different address strings with the same key material:
    /// the network lives in the prefix only, so a user who pastes the wrong one is refused by
    /// `Address::decode`'s HRP rather than paying an account they do not control.
    #[test]
    fn the_network_changes_only_the_prefix() {
        let seed = demo_seed();
        let ids: Vec<Identity> = [
            WalletNetwork::Main,
            WalletNetwork::Test,
            WalletNetwork::Regtest,
        ]
        .into_iter()
        .map(|n| identity(&seed, n).unwrap())
        .collect();
        for w in ids.windows(2) {
            assert_ne!(w[0].address, w[1].address);
            assert_eq!(w[0].ak, w[1].ak);
            assert_eq!(w[0].nkc, w[1].nkc);
        }
        assert!(ids[0].address.starts_with("nj1"));
        assert!(ids[1].address.starts_with("njtest1"));
        assert!(ids[2].address.starts_with("njreg1"));
    }

    /// Derivation is a pure function of the seed bytes, and a one-bit change is a different
    /// account. Cheap, but it is the property that makes the pinned vector above meaningful.
    #[test]
    fn derivation_is_deterministic_and_seed_separated() {
        let seed = demo_seed();
        assert_eq!(
            identity(&seed, WalletNetwork::Regtest).unwrap().address,
            identity(&seed, WalletNetwork::Regtest).unwrap().address
        );
        let mut other = seed.clone();
        other[0] ^= 1;
        assert_ne!(
            identity(&other, WalletNetwork::Regtest).unwrap().address,
            DEMO_ADDRESS
        );
    }
}
