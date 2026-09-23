//! The Nyctis identity a wallet seed already carries, and the viewing half of it.
//!
//! Nyctis derives its account from raw seed bytes with a BLAKE2b path that has nothing to do
//! with ZIP 32 (`nyctis_zk::keys::Account::from_seed`). **The bytes this wallet feeds it are the
//! BIP39 seed** — the same 64 bytes every Zcash key of the account is derived from, passphrase
//! applied — never the stored mnemonic text or the JSON envelope a passphrase wallet stores it in.
//! [`account_from_mnemonic`] is the one place that conversion happens, through the wallet's own
//! `mnemonic_bytes_to_seed`, so any other implementation that restores the same mnemonic and
//! passphrase derives the same Nyctis identity, and a change to how secrets are *stored* cannot
//! move it.
//!
//! The account is not keyed by ZIP 32 account index: two Vizor accounts derived from one mnemonic
//! at different indices share one Nyctis identity. That is a property of the upstream
//! derivation, not a choice made here.
//!
//! # Reading needs only viewing material
//!
//! Reading a channel — "which notes are mine, and which of them are spent" — needs the account's
//! incoming key `ivk` (to trial-decrypt) and its nullifier key `nk` (to recompute nullifiers), and
//! showing the receive address needs `ak` as well. None of that can sign. [`ViewingKey`] is that
//! triple; it is derived once when the wallet is unlocked and is all the read path ever receives,
//! so the seed crosses the FFI only to sign a payment. It is still secret — it reveals every
//! payment this account has received and when each was spent — so it lives in memory only, the
//! way the wallet treats every other decrypted secret.

use nyctis_zk::keys::{Account, Address, SpendAuthority};
use nyctis_zk::{Element, Fq, Fr};
use secrecy::ExposeSecret;
use zeroize::{Zeroize, Zeroizing};

use crate::nyctis::network::NyctisNetwork;
use crate::wallet::network::WalletNetwork;

/// Length of [`ViewingKey::to_bytes`]: `ak ‖ nk ‖ ivk`, 32 bytes each.
pub const VIEWING_KEY_LEN: usize = 96;

/// The three public values a user needs to receive Nyctis assets.
pub struct Identity {
    /// Bech32m address, `0x00 ‖ ak ‖ nkc ‖ pk_enc` under this network's prefix.
    pub address: String,
    pub ak: [u8; 32],
    pub nkc: [u8; 32],
}

/// The account a raw seed names. Infallible by construction, and deliberately kept as the one
/// place this module calls into `nyctis-zk`'s key derivation.
///
/// `seed` is the **BIP39 seed**, not a mnemonic: production code reaches this only through
/// [`account_from_mnemonic`]. Tests call it directly with the recorded devnet seeds, which are raw
/// seeds by construction.
///
/// `SpendAuthority::from_seed` *panics* on a label outside `KEY_LABELS`, which is correct for a
/// workspace where every call site passes a literal. `Account::from_seed` passes the literals
/// `"spend"` and `"issue"`, both listed, so no input this function accepts can reach that
/// assertion — but the guarantee is upstream's to keep, not ours, so everything reachable from
/// the FFI still runs inside the `catch()` guard in `api/nyctis.rs`.
pub fn account(seed: &[u8]) -> Account {
    Account::from_seed(seed)
}

/// The account this wallet's stored secret names: `mnemonic_bytes_to_seed` (envelope-aware,
/// BIP39 passphrase applied), then [`account`] over the 64-byte seed.
///
/// The BIP39 seed is held in a `SecretVec` and zeroized when it drops at the end of this call;
/// the caller keeps responsibility for `mnemonic` itself, which the FFI layer wraps in
/// `Zeroizing`.
pub fn account_from_mnemonic(mnemonic: &[u8]) -> Result<SecretAccount, String> {
    let seed = crate::wallet::keys::mnemonic_bytes_to_seed(mnemonic)?;
    Ok(SecretAccount(account(seed.expose_secret())))
}

/// An [`Account`] whose secret field elements are zeroized when it drops.
///
/// `nk` and `ivk` are wiped. The spend and issue authorities are `decaf377-rdsa` signing keys,
/// which implement no `Zeroize` in the version this tree links, so those two cannot be wiped
/// from here; they live only for the duration of one `build_pay` call.
pub struct SecretAccount(Account);

impl std::ops::Deref for SecretAccount {
    type Target = Account;
    fn deref(&self) -> &Account {
        &self.0
    }
}

impl Drop for SecretAccount {
    fn drop(&mut self) {
        self.0.nk.zeroize();
        self.0.ivk.zeroize();
    }
}

/// Render an account as the identity to show the user on `network`.
pub fn identity(seed: &[u8], network: WalletNetwork) -> Result<Identity, String> {
    ViewingKey::of(&account(seed)).identity(network)
}

/// The viewing half of a Nyctis account: `ak`, `nk` and `ivk`. Enough to find every note the
/// account owns, tell which are spent, and render its address; not enough to sign anything.
pub struct ViewingKey {
    ak: [u8; 32],
    nk: Fq,
    ivk: Fr,
}

/// Redacted: `nk` and `ivk` never reach a log line.
impl std::fmt::Debug for ViewingKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ViewingKey")
            .field("ak", &hex::encode(self.ak))
            .finish_non_exhaustive()
    }
}

impl Drop for ViewingKey {
    fn drop(&mut self) {
        self.nk.zeroize();
        self.ivk.zeroize();
    }
}

impl ViewingKey {
    pub fn of(account: &Account) -> Self {
        ViewingKey {
            ak: account.spend.ak_bytes(),
            nk: account.nk,
            ivk: account.ivk,
        }
    }

    /// `ak ‖ nk ‖ ivk`, each the canonical 32-byte encoding. Zeroized on drop.
    pub fn to_bytes(&self) -> Zeroizing<Vec<u8>> {
        let mut out = Zeroizing::new(Vec::with_capacity(VIEWING_KEY_LEN));
        out.extend_from_slice(&self.ak);
        out.extend_from_slice(&self.nk.to_bytes());
        out.extend_from_slice(&self.ivk.to_bytes());
        out
    }

    /// Parse [`Self::to_bytes`]. Every component must be canonical and `ak` a valid decaf377
    /// point: a key that decodes to something else would find nothing and report an empty
    /// wallet, which reads as a balance of zero rather than as the malformed input it is.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() != VIEWING_KEY_LEN {
            return Err(format!(
                "a Nyctis viewing key is {VIEWING_KEY_LEN} bytes, not {}",
                bytes.len()
            ));
        }
        let ak: [u8; 32] = bytes[..32].try_into().expect("32 bytes");
        decaf377_rdsa::VerificationKey::<decaf377_rdsa::SpendAuth>::try_from(ak)
            .map_err(|_| "the viewing key's ak is not a decaf377 point".to_string())?;
        let mut nk_b: [u8; 32] = bytes[32..64].try_into().expect("32 bytes");
        let mut ivk_b: [u8; 32] = bytes[64..].try_into().expect("32 bytes");
        let nk = Fq::from_bytes_checked(&nk_b);
        let ivk = Fr::from_bytes_checked(&ivk_b);
        nk_b.zeroize();
        ivk_b.zeroize();
        Ok(ViewingKey {
            ak,
            nk: nk.map_err(|_| "the viewing key's nk is not canonical".to_string())?,
            ivk: ivk.map_err(|_| "the viewing key's ivk is not canonical".to_string())?,
        })
    }

    /// The account's receive address. Identical to `Account::address()` for the account this
    /// key was taken from: `(ak, nkc(nk), [ivk]·B)`.
    pub fn address(&self) -> Address {
        Address {
            ak: self.ak,
            nkc: nyctis_zk::hash::nkc(&self.nk).to_bytes(),
            pk_enc: (Element::GENERATOR * self.ivk).vartime_compress().0,
        }
    }

    pub fn identity(&self, network: WalletNetwork) -> Result<Identity, String> {
        let address = self.address();
        Ok(Identity {
            address: address
                .encode(network.ny_hrp())
                .map_err(|e| format!("encoding Nyctis address: {e}"))?,
            ak: address.ak,
            nkc: address.nkc,
        })
    }

    /// An `Account` for the **read path only**: its `nk` and `ivk` are this key's, and its spend
    /// and issue authorities are fresh random keys that belong to nobody.
    ///
    /// `owned::owned_notes` and `nyctis_zk::transition::recover` take an `Account` but read only
    /// `ivk` (trial decryption), `nk` (nullifiers) and `nkc()` (published notes). The placeholder
    /// authorities exist to satisfy the type; nothing may sign with this value, and nothing may
    /// read `spend`/`issue`/`address()` off it — use [`Self::address`] for the address. Kept
    /// crate-private and wrapped so the placeholder is wiped like any other account.
    pub(crate) fn reading_account(&self) -> SecretAccount {
        SecretAccount(Account {
            spend: SpendAuthority::random(),
            issue: SpendAuthority::random(),
            nk: self.nk,
            ivk: self.ivk,
        })
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use nyctis_codec::transition::{Ciphertext, Shape, Transition, CIRCUIT_VERSION, PROOF_LEN};
    use nyctis_zk::note::{encrypt, plaintext, Note};

    /// The devnet demo seed and the address, `ak` and `nkc` the Nyctis CLI's `ny-address`
    /// prints for it. Pinned rather than recomputed: this is the value a user backs up and
    /// hands out, so any change to the derivation, to the address layout or to the HRP table
    /// must fail here and not silently reissue everyone a new receive address.
    const DEMO_SEED_HEX: &str = "a22927e214bb3b5f0308f1d440e8133545256e855c1d662734c5a318399ae3ae";
    const DEMO_ADDRESS: &str = "nyreg1qzxdgxkjg4vgjux6rw63t0akwkq03q5stfz9txpjcqx0mgcmpfrqk2per2w388qnrtc7t5mh9nux7ftrxq0xsc9gjv9shuymray29qq8yqcqxexsz2hwz2f6nmtmvgr46ja60dfgkasmf5tsg3a3jtq9hs9sxafxqq";
    const DEMO_AK: &str = "8cd41ad245588970da1bb515bfb67580f882905a44559832c00cfda31b0a460b";

    fn demo_seed() -> Vec<u8> {
        hex::decode(DEMO_SEED_HEX).unwrap()
    }

    #[test]
    fn the_demo_seed_derives_the_known_devnet_identity() {
        let id = identity(&demo_seed(), WalletNetwork::Regtest).unwrap();
        assert_eq!(id.address, DEMO_ADDRESS);
        assert_eq!(hex::encode(id.ak), DEMO_AK);
        // the address must actually decode back to the same three keys under the same prefix
        let (hrp, decoded) = nyctis_zk::keys::Address::decode(&id.address).unwrap();
        assert_eq!(hrp, "nyreg");
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
        assert!(ids[0].address.starts_with("ny1"));
        assert!(ids[1].address.starts_with("nytest1"));
        assert!(ids[2].address.starts_with("nyreg1"));
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

    /// A transition carrying nothing but the fields `recover` and the verifier read: the given
    /// nullifiers, commitments and ciphertexts, an all-zero proof and no signatures. Shared with
    /// the `pay` tests, which need a transition whose proof is certainly wrong.
    pub(crate) fn bare_transition(
        nullifiers: Vec<[u8; 32]>,
        commitments: Vec<[u8; 32]>,
        ciphertexts: Vec<Vec<Ciphertext>>,
    ) -> Transition {
        Transition {
            circuit_version: CIRCUIT_VERSION,
            shape: Shape {
                n_in: nullifiers.len() as u8,
                n_out: commitments.len() as u8,
                k: [0; 2],
                h: [false; 2],
                issue: false,
                z: [false; 2],
                issue_public: false,
                b: [false; 2],
                export: false,
                out_slot: 0,
            },
            anchor: [0; 32],
            declared_height: 0,
            nullifiers,
            commitments,
            rks: vec![],
            preimages: vec![],
            rk_issuer: None,
            asset_issue: None,
            issued_amount: 0,
            max_supply: 0,
            index: 0,
            collection_id: None,
            collection_max_supply: 0,
            export: None,
            expiries: vec![],
            zec_claims: vec![],
            proof: [0; PROOF_LEN],
            signatures: vec![],
            ciphertexts,
        }
    }

    /// A transition paying `amount` to `to`, encrypted exactly as a sender would.
    fn payment_to(to: &Account, amount: u64) -> Transition {
        let policy = to.address().default_policy();
        let note = Note {
            policy_root: nyctis_zk::hash::policy_hash(&policy),
            asset_id: Fq::from(7u64),
            amount,
            nkc: to.nkc(),
            data: Fq::from(0u64),
            rseed: Note::random_rseed(),
            recoverable_from: None,
            explicit_rcm: None,
        };
        let cm = note.commitment();
        let (epk, ct) = encrypt(&plaintext(&note, None, &policy), &cm, &note.esk(), &to.pk_enc());
        bare_transition(vec![], vec![cm.to_bytes()], vec![vec![Ciphertext { epk, ct }]])
    }

    const ABANDON: &str = "abandon abandon abandon abandon abandon abandon abandon abandon \
                           abandon abandon abandon about";

    /// **C6 — the identity comes from the BIP39 seed.** The stored secret is the mnemonic text
    /// (or, for a passphrase wallet, a JSON envelope around it); hashing *that* made the Nyctis
    /// identity a function of the storage format, unreachable from any other wallet restoring the
    /// same words, and silently different the day the envelope's serialization changed.
    #[test]
    fn the_identity_is_the_bip39_seeds_not_the_stored_texts() {
        let seed = crate::wallet::keys::mnemonic_to_seed(ABANDON).unwrap();
        let from_text = account_from_mnemonic(ABANDON.as_bytes()).unwrap();
        assert_eq!(
            from_text.address(),
            account(seed.expose_secret()).address(),
            "the mnemonic path must land on the BIP39 seed's account"
        );
        assert_ne!(
            from_text.address(),
            account(ABANDON.as_bytes()).address(),
            "the old derivation, over the mnemonic text itself, must not survive anywhere"
        );
        assert_eq!(seed.expose_secret().len(), 64);
    }

    /// A passphrase wallet's secret is stored as a JSON envelope. The passphrase must be applied,
    /// and the envelope's field order, whitespace and escaping must not be part of the identity.
    #[test]
    fn a_passphrase_wallet_derives_from_its_passphrase_seed_whatever_the_envelope_looks_like() {
        let with_pass = crate::wallet::keys::mnemonic_to_seed_with_passphrase(ABANDON, "TREZOR")
            .unwrap();
        // the BIP39 reference vector for these words and "TREZOR"
        assert_eq!(
            hex::encode(with_pass.expose_secret()),
            "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
        );
        let want = account(with_pass.expose_secret()).address();

        let compact = format!(
            r#"{{"version":1,"mnemonic":"{ABANDON}","bip39Passphrase":"TREZOR"}}"#
        );
        let reordered = format!(
            "  {{ \"bip39Passphrase\": \"TREZOR\",\n \"mnemonic\": \"{ABANDON}\", \"version\": 1 }}"
        );
        for envelope in [compact, reordered] {
            let got = account_from_mnemonic(envelope.as_bytes()).unwrap();
            assert_eq!(got.address(), want, "{envelope}");
            assert_ne!(got.address(), account(envelope.as_bytes()).address());
        }
        assert_ne!(
            want,
            account_from_mnemonic(ABANDON.as_bytes()).unwrap().address(),
            "the passphrase is part of the seed, so it is part of the Nyctis identity"
        );
    }

    /// Pinned: the Nyctis address of the BIP39 test mnemonic, with and without the "TREZOR"
    /// passphrase. This is the value a user backs up by backing up their words, so any change
    /// to the seed path, the derivation or the address layout must fail here.
    ///
    /// The no-passphrase value is what the reference CLI prints (`nyctis wallet ny-address`)
    /// for a wallet directory whose `seed.hex` is that mnemonic's BIP39 seed
    /// (`5eb00bbd…ce9e38e4`), which is the interoperability C6 is about: restore the words in
    /// either and the Nyctis identity is the same.
    #[test]
    fn the_bip39_test_mnemonic_has_a_pinned_nyctis_address() {
        let plain = ViewingKey::of(&account_from_mnemonic(ABANDON.as_bytes()).unwrap())
            .identity(WalletNetwork::Regtest)
            .unwrap();
        let envelope = format!(
            r#"{{"version":1,"mnemonic":"{ABANDON}","bip39Passphrase":"TREZOR"}}"#
        );
        let pass = ViewingKey::of(&account_from_mnemonic(envelope.as_bytes()).unwrap())
            .identity(WalletNetwork::Regtest)
            .unwrap();
        assert_eq!(plain.address, BIP39_ABANDON_ADDRESS);
        assert_eq!(pass.address, BIP39_ABANDON_TREZOR_ADDRESS);
    }

    const BIP39_ABANDON_ADDRESS: &str = "nyreg1qqmdz7075mdaxadzc4fhmg295tz4d7f6mfq62ksgye6kuatlm5psruav5kyn7qvsez39vkd4stuxvzlad9da4p7amfsde6hczejmsxst8nt7sc8hw6t9lk46r506rg92x7585s6ch4q6jw6zjc480ma42sysrhvc0n";
    const BIP39_ABANDON_TREZOR_ADDRESS: &str = "nyreg1qp5vyw6we6la4zp0zs34plajak63cmrnju5yus3t3m3gcwg2kkgs0xff876zvcy9zp6q9599lphadvdae4d03maghreq9vstyrcg2xg2ypps8kjgrrd64z7av4uzhkqs4mw0jpvcxnvt6m2g5f0mg5n08sqq262azl";

    /// Malformed secrets are errors, not a Nyctis account over garbage bytes.
    #[test]
    fn a_secret_that_is_not_a_mnemonic_is_refused() {
        assert!(account_from_mnemonic(b"").is_err());
        assert!(account_from_mnemonic(b"not a mnemonic at all").is_err());
        assert!(account_from_mnemonic(&[0xff, 0xfe]).is_err());
        assert!(account_from_mnemonic(br#"{"version":2,"mnemonic":"x","bip39Passphrase":""}"#).is_err());
    }

    /// The viewing key renders the same address as the account it came from, and survives the
    /// FFI's byte round trip exactly.
    #[test]
    fn the_viewing_key_round_trips_and_names_the_same_address() {
        let acct = account(&demo_seed());
        let vk = ViewingKey::of(&acct);
        assert_eq!(vk.address(), acct.address());
        assert_eq!(vk.identity(WalletNetwork::Regtest).unwrap().address, DEMO_ADDRESS);

        let bytes = vk.to_bytes();
        assert_eq!(bytes.len(), VIEWING_KEY_LEN);
        let back = ViewingKey::from_bytes(&bytes).unwrap();
        assert_eq!(back.address(), acct.address());
        assert_eq!(*back.to_bytes(), *bytes);
    }

    #[test]
    fn a_malformed_viewing_key_is_refused() {
        let good = ViewingKey::of(&account(&demo_seed())).to_bytes();
        assert!(ViewingKey::from_bytes(&good[..95]).is_err());
        assert!(ViewingKey::from_bytes(&[good.as_slice(), &[0]].concat()).is_err());
        let mut bad_nk = good.to_vec();
        bad_nk[32..64].copy_from_slice(&[0xff; 32]);
        assert!(ViewingKey::from_bytes(&bad_nk).unwrap_err().contains("nk"));
        let mut bad_ivk = good.to_vec();
        bad_ivk[64..].copy_from_slice(&[0xff; 32]);
        assert!(ViewingKey::from_bytes(&bad_ivk).unwrap_err().contains("ivk"));
    }

    /// **The read path needs no seed.** An account rebuilt from the viewing key alone recovers
    /// exactly the notes the full account recovers — same note, same `nk`, so the same nullifier
    /// and therefore the same spent/unspent verdict — and nothing addressed to someone else.
    #[test]
    fn the_viewing_key_alone_recovers_what_the_seed_recovers() {
        let me = account(&demo_seed());
        let reader = ViewingKey::of(&me).reading_account();
        let stranger = account(b"somebody else entirely");

        let mine = payment_to(&me, 42);
        let with_seed = nyctis_zk::transition::recover(&mine, &me);
        let with_view = nyctis_zk::transition::recover(&mine, &reader);
        assert_eq!(with_seed.len(), 1);
        assert_eq!(with_view.len(), 1);
        assert_eq!(with_view[0].note, with_seed[0].note);
        assert_eq!(with_view[0].nk, with_seed[0].nk);
        assert_eq!(
            with_view[0].note.nullifier(&with_view[0].nk, 5).to_bytes(),
            with_seed[0].note.nullifier(&with_seed[0].nk, 5).to_bytes(),
        );
        assert_eq!(reader.nkc(), me.nkc(), "published notes are matched on nkc");

        let theirs = payment_to(&stranger, 42);
        assert!(nyctis_zk::transition::recover(&theirs, &reader).is_empty());
    }

    /// The placeholder authorities on a reading account are nobody's: they must not coincide with
    /// the real spend key, or a read-path value could be mistaken for one that can sign.
    #[test]
    fn a_reading_account_cannot_sign_as_the_real_one() {
        let me = account(&demo_seed());
        let reader = ViewingKey::of(&me).reading_account();
        assert_ne!(reader.spend.ak_bytes(), me.spend.ak_bytes());
        assert_ne!(reader.issue.ak_bytes(), me.issue.ak_bytes());
    }
}
