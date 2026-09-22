//! The ZEC oracle: "did the Zcash transaction that carried this message pay the claim it makes?"
//!
//! This is spec `transition-v0.md` section 6 step 6b, and until this module existed the wallet
//! had no answer to it at all — [`nightjar_state::NoZec`] was passed to `State::apply`, which
//! refuses **every** claim. That was not a cosmetic gap. A refused claim is an *ignored* message,
//! an ignored transition appends no notes and registers no anchor, and every later message that
//! names that anchor or one of those note positions is then ignored too. On the devnet channel
//! this turned one unverifiable message into fourteen: 1 claim + 9 "unknown anchor" +
//! 4 "note: position N does not exist", and a `state_root` that no other verifier computes.
//!
//! # Why this is a port and not a dependency
//!
//! The reference implementation is `PaidClaims` in `nightjar-scanner`, which the indexer and the
//! CLI both use. **It cannot be linked here.** `nightjar-scanner` depends on `zcash_keys`,
//! `zcash_primitives`, `zcash_client_backend` and `orchard` from upstream librustzcash, while
//! this wallet is built on the `zakura-*` forks of exactly those crates; linking both puts two
//! incompatible Zcash stacks — two `orchard`s, two note-encryption domains — into one binary.
//! That constraint is why the fork links only `nightjar-codec`, `-state` and `-zk`, the three
//! Nightjar crates with no Zcash dependency at all.
//!
//! So the logic below is a **port**, function for function, of
//! `crates/nightjar-scanner/src/lib.rs` (`claim_account`, `uivk_string`, `paid_to`,
//! `PaidClaims`). Because it is a port, agreement with the reference is not guaranteed by
//! construction and has to be established by test: `replay::tests` replays the live devnet
//! channel — claims and all — and asserts this wallet reaches the indexer's `state_root`,
//! `tree_root` and per-message verdicts. That test is the only thing that says the port is
//! faithful. A wallet that verifies claims *differently* from the network is worse than one that
//! refuses them all, because it is confidently wrong instead of visibly incomplete.
//!
//! Keep the two files in step. The upstream API is stable enough that the Zakura forks expose it
//! identically (`Transaction::ironwood_bundle`, `IronwoodDomain::for_action`,
//! `UnifiedIncomingViewingKey::decode`, `IncomingViewingKey::to_bytes`), so the port is nearly
//! character-for-character and a diff against the scanner is a meaningful review.
//!
//! # Fail closed
//!
//! The scanner is handed the block it is scanning, so "the carrying transaction" is never in
//! doubt for it. This wallet is handed message *bodies* over HTTP and has to go and fetch the
//! transaction ([`crate::nightjar::carrier`]), which can fail — no lightwalletd, a pruned
//! server, a transaction the wallet's own database never saw. **A fetch that fails is not a
//! paid claim.** [`PaidClaims::paid`] answers `false` exactly as `NoZec` did, and records *why*
//! in [`PaidClaims::refusals`] so the replay can say "could not be checked" rather than
//! "checked and unpaid". Treating "I could not look" as "yes" is the failure this whole cut
//! exists to prevent.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::sync::Arc;

use nightjar_codec::transition::{Transition, ZecClaim};
use nightjar_codec::transport::{Location, Network as WireNetwork, KIND_TRANSITION};
use nightjar_state::ZecOracle;
use orchard::keys::{IncomingViewingKey, PreparedIncomingViewingKey};
use orchard::note_encryption::IronwoodDomain;
use zcash_keys::keys::UnifiedIncomingViewingKey;
use zcash_primitives::transaction::Transaction;
use zcash_protocol::consensus::{BlockHeight, BranchId};

use crate::nightjar::replay::Message;
use crate::wallet::network::WalletNetwork;

/// The `uivk…` Bech32m string of a ZIP 316 payload, which is how
/// [`UnifiedIncomingViewingKey::decode`] wants to be handed one.
///
/// Ported from `nightjar_scanner::uivk_string`. The HRPs are the protocol's, not this wallet's
/// choice: a claim's payload is bytes on the wire and the only way back to a key is through the
/// encoding the key was published in.
pub fn uivk_string(network: WireNetwork, payload: &[u8]) -> Option<String> {
    let hrp = match network {
        WireNetwork::Mainnet => "uivk",
        WireNetwork::Testnet => "uivktest",
        WireNetwork::Regtest => "uivkregtest",
    };
    bech32::encode::<bech32::Bech32m>(bech32::Hrp::parse(hrp).ok()?, payload).ok()
}

/// The Ironwood incoming viewing key a ZIP 316 payload names, or `None` when the payload is not a
/// unified incoming viewing key with an Ironwood component (spec step 6b requires that it
/// parses, and a message whose claim does not is ignored).
///
/// **F24.** Its raw encoding — not the payload — is the identity of the *account*. ZIP 316 admits
/// many payloads for one account: an unknown typecode, an added receiver, a re-rendered UIVK. A
/// budget keyed on the payload therefore gave each encoding a full budget out of one payment, so
/// two differently-encoded claims to the same account were both paid by a single transfer. That
/// is why [`ZecOracle::account_key`] exists at all and why this function, not the raw bytes, is
/// what feeds it.
///
/// Ported from `nightjar_scanner::claim_account`.
pub fn claim_account(
    params: &WalletNetwork,
    network: WireNetwork,
    uivk: &[u8],
) -> Option<IncomingViewingKey> {
    let key = UnifiedIncomingViewingKey::decode(params, &uivk_string(network, uivk)?).ok()?;
    key.orchard().clone()
}

/// Sum of the Ironwood outputs of `tx` that decrypt with `ivk`.
///
/// Ported from `nightjar_scanner::paid_to`. `saturating_add` rather than `+` for the same reason
/// it is there: the values come off the wire and a verifier must not panic on a transaction
/// somebody else built.
pub fn paid_to(tx: &Transaction, ivk: &IncomingViewingKey) -> u64 {
    let Some(bundle) = tx.ironwood_bundle() else {
        return 0;
    };
    let pivk = PreparedIncomingViewingKey::new(ivk);
    let mut total = 0u64;
    for action in bundle.actions().iter() {
        let domain = IronwoodDomain::for_action(action);
        if let Some((note, _addr, _memo)) =
            zcash_note_encryption::try_note_decryption(&domain, &pivk, action)
        {
            total = total.saturating_add(note.value().inner());
        }
    }
    total
}

/// Why a claim could not be *checked*, as distinct from having been checked and found unpaid.
///
/// This is the whole reason the type exists: `ZecOracle::paid` returns a `bool`, so both
/// outcomes reach `State::apply` as `false` and come back out as the same sentence — "ZEC claim
/// of N zatoshi not paid by the carrying transaction". That sentence is a *lie* when the wallet
/// never managed to look at the transaction, and it is the kind of lie that makes a wallet look
/// like it disagrees with the network when it is merely blind. The oracle therefore keeps the
/// distinction on the side and [`crate::nightjar::replay`] folds it back into the outcome.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    /// User-facing clause, appended to the state machine's own reason.
    pub why: String,
}

/// Carrying transactions, per `(height, tx_index)`, as [`crate::nightjar::carrier`] resolved
/// them: the bytes, or the reason there are none.
///
/// Keyed on the location rather than on the txid because that is what `ZecOracle` is asked
/// about, and because the location is what binds a claim to *the transaction that carried the
/// message* rather than to any transaction at that height.
#[derive(Clone, Debug, Default)]
pub struct CarryingTxs {
    pub have: BTreeMap<(u32, u32), Arc<Vec<u8>>>,
    pub missing: BTreeMap<(u32, u32), String>,
}

impl CarryingTxs {
    pub fn is_empty(&self) -> bool {
        self.have.is_empty() && self.missing.is_empty()
    }
}

/// The ZEC oracle of spec `transition-v0.md` section 6 step 6b: what each completing transaction
/// pays to each claimed **account**, as a budget the messages it completes draw down.
///
/// **F26 — every unit of work here is lazy and cached**, exactly as in the scanner. Nothing is
/// parsed or trial-decrypted until a message that has already passed its proof, its signatures
/// and the single-transaction rule actually claims a payment: `transition-v0.md` section 6 puts
/// the proof at step 5 and the claim at 6b, and an oracle that decrypted eagerly would let a body
/// that merely survived `decode` buy a full sweep of a 330-action transaction. The carrying
/// transaction is parsed at most once per `(height, tx_index)`, each claimed payload is derived
/// to its account at most once, and each `(transaction, account)` budget is computed at most
/// once.
///
/// The scanner builds one of these per block; this builds one per replay. The two are equivalent
/// because every budget key carries the height, so no two blocks can share a budget entry.
pub struct PaidClaims<'a> {
    params: WalletNetwork,
    network: WireNetwork,
    txs: &'a CarryingTxs,
    cache: RefCell<Cache>,
    /// Locations whose claim was refused for want of evidence rather than for want of payment.
    refusals: RefCell<BTreeMap<Location, Refusal>>,
}

/// Memoised work. Behind a `RefCell` because `ZecOracle::paid` takes `&self`: the oracle is a
/// pure function of the chain, and caching does not change what it answers.
#[derive(Default)]
struct Cache {
    /// Parsed carrying transaction per `(height, tx_index)`; `None` once parsing has failed.
    txs: BTreeMap<(u32, u32), Option<Arc<Transaction>>>,
    /// ZIP 316 payload → the account it names (F24).
    accounts: BTreeMap<Vec<u8>, Option<IncomingViewingKey>>,
    /// Remaining budget per `(height, tx_index, account)`.
    budget: BTreeMap<(u32, u32, [u8; 64]), u64>,
}

impl<'a> PaidClaims<'a> {
    pub fn new(params: WalletNetwork, network: WireNetwork, txs: &'a CarryingTxs) -> Self {
        PaidClaims {
            params,
            network,
            txs,
            cache: RefCell::new(Cache::default()),
            refusals: RefCell::new(BTreeMap::new()),
        }
    }

    /// Why the claim at `location` could not be checked, when that is the reason it failed.
    /// `None` means either that it was checked, or that no claim was made there.
    pub fn refusal(&self, location: Location) -> Option<Refusal> {
        self.refusals.borrow().get(&location).cloned()
    }

    fn refuse(&self, location: Location, why: String) {
        self.refusals
            .borrow_mut()
            .entry(location)
            .or_insert(Refusal { why });
    }

    fn account(&self, uivk: &[u8]) -> Option<IncomingViewingKey> {
        let mut cache = self.cache.borrow_mut();
        if let Some(hit) = cache.accounts.get(uivk) {
            return hit.clone();
        }
        let derived = claim_account(&self.params, self.network, uivk);
        cache.accounts.insert(uivk.to_vec(), derived.clone());
        derived
    }

    /// The parsed carrying transaction at `(height, tx_index)`, parsed at most once.
    ///
    /// `BranchId::for_height` mirrors the scanner. It has no effect on anything Nightjar carries:
    /// a Nightjar memo rides in an Ironwood action, which only exists in a v6 transaction, and
    /// `Transaction::read` ignores the branch id for v5 and v6 (it is only consulted to pick the
    /// v4 reader). It is passed anyway so that a diff against `nightjar-scanner` stays clean.
    fn transaction(&self, height: u32, tx_index: u32) -> Option<Arc<Transaction>> {
        let mut cache = self.cache.borrow_mut();
        if let Some(hit) = cache.txs.get(&(height, tx_index)) {
            return hit.clone();
        }
        let parsed = self
            .txs
            .have
            .get(&(height, tx_index))
            .and_then(|raw| {
                Transaction::read(
                    &raw[..],
                    BranchId::for_height(&self.params, BlockHeight::from_u32(height)),
                )
                .ok()
            })
            .map(Arc::new);
        cache.txs.insert((height, tx_index), parsed.clone());
        parsed
    }

    /// Remaining budget of `(location, account)`, trial-decrypting the carrying transaction once.
    ///
    /// The scanner's version returns `0` when the transaction is not in hand, which for it can
    /// only mean a transaction with no Nightjar memo. Here it is the fail-closed path, so it is
    /// recorded before the zero is returned.
    fn remaining(&self, location: Location, ivk: &IncomingViewingKey) -> u64 {
        let key = (location.0, location.1, ivk.to_bytes());
        if let Some(b) = self.cache.borrow().budget.get(&key) {
            return *b;
        }
        let paid = match self.transaction(location.0, location.1) {
            Some(tx) => paid_to(&tx, ivk),
            None => {
                let why = self
                    .txs
                    .missing
                    .get(&(location.0, location.1))
                    .cloned()
                    .unwrap_or_else(|| {
                        "the carrying Zcash transaction was not fetched".to_string()
                    });
                self.refuse(location, why);
                0
            }
        };
        self.cache.borrow_mut().budget.insert(key, paid);
        paid
    }
}

impl ZecOracle for PaidClaims<'_> {
    fn account_key(&self, uivk: &[u8]) -> Option<Vec<u8>> {
        self.account(uivk).map(|ivk| ivk.to_bytes().to_vec())
    }

    fn paid(&self, location: Location, claim: &ZecClaim) -> bool {
        // `State::apply` has already resolved the account (a claim it could not resolve made the
        // message ignored), so a miss here can only mean the payload stopped parsing.
        let Some(ivk) = self.account(&claim.uivk) else {
            return false;
        };
        self.remaining(location, &ivk) >= claim.zatoshi
    }

    fn consume(&mut self, location: Location, claim: &ZecClaim) {
        let Some(ivk) = self.account(&claim.uivk) else {
            return;
        };
        let left = self
            .remaining(location, &ivk)
            .saturating_sub(claim.zatoshi);
        self.cache
            .borrow_mut()
            .budget
            .insert((location.0, location.1, ivk.to_bytes()), left);
    }
}

/// Which messages carry a ZEC claim, and therefore which carrying transactions have to be
/// fetched before the replay can run.
///
/// **This is what keeps the fetch bounded.** A channel with a thousand messages issues at most
/// one round trip per *distinct claim-carrying transaction*, not one per message: the result is
/// keyed on `(height, tx_index)`, and `carrier::fetch` dedupes on it again. A channel with no
/// claims at all — which is every channel that has never traded — issues none, and the replay
/// stays exactly as cheap as it was before this module existed.
///
/// A body that does not decode is not an error here. `State::apply` decodes it too and will
/// ignore the message with its own reason; pre-empting that with a different one would make the
/// wallet's outcome list disagree with the reference verifier's over a message neither of them
/// applies.
pub fn claim_carrying(messages: &[Message]) -> Vec<&Message> {
    messages
        .iter()
        .filter(|m| {
            m.kind == KIND_TRANSITION
                && Transition::decode(&m.body)
                    .map(|t| !t.zec_claims.is_empty())
                    .unwrap_or(false)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nightjar::testdata::claims as testdata;

    /// F24 in one assertion, against the port rather than against the scanner: two distinct ZIP
    /// 316 payloads that name one Ironwood account must produce one account key.
    ///
    /// The second payload here is the first with an extra unknown-typecode item appended, which
    /// is exactly the shape ZIP 316 tells a parser to ignore — and exactly the shape that, keyed
    /// on the raw payload, bought a second full budget from one payment.
    #[test]
    fn two_encodings_of_one_account_have_one_account_key() {
        let payload = testdata::claim_uivk_payload();
        let txs = CarryingTxs::default();
        let oracle = PaidClaims::new(WalletNetwork::Regtest, WireNetwork::Regtest, &txs);
        let a = oracle
            .account_key(&payload)
            .expect("the devnet claim payload names an Ironwood account");
        assert_eq!(a.len(), 64, "an Ironwood ivk is 64 bytes");

        // Re-render the same key through `UnifiedIncomingViewingKey`: a different payload for the
        // same account, which is the F24 case.
        let key = UnifiedIncomingViewingKey::decode(
            &WalletNetwork::Regtest,
            &uivk_string(WireNetwork::Regtest, &payload).unwrap(),
        )
        .unwrap();
        let rerendered = key.encode(&WalletNetwork::Regtest);
        let (_hrp, rerendered_payload) = bech32::decode(&rerendered).unwrap();
        let b = oracle
            .account_key(&rerendered_payload)
            .expect("the re-rendered key still names the account");
        assert_eq!(a, b, "one account, one budget key");
    }

    /// A payload that is not a UIVK at all has no account, which is what makes `State::apply`
    /// ignore the message rather than treat the claim as unpaid.
    #[test]
    fn a_payload_that_is_not_a_viewing_key_has_no_account() {
        let txs = CarryingTxs::default();
        let oracle = PaidClaims::new(WalletNetwork::Regtest, WireNetwork::Regtest, &txs);
        assert_eq!(oracle.account_key(&[0u8; 8]), None);
        assert_eq!(oracle.account_key(&[]), None);
    }

    /// With no transaction in hand the oracle answers exactly what `NoZec` answered — and, unlike
    /// `NoZec`, says so. The recorded reason is what the outcome list shows instead of claiming
    /// the transaction was checked.
    #[test]
    fn a_claim_with_no_transaction_is_refused_and_says_why() {
        let mut txs = CarryingTxs::default();
        txs.missing
            .insert((275, 1), "lightwalletd said NotFound".to_string());
        let oracle = PaidClaims::new(WalletNetwork::Regtest, WireNetwork::Regtest, &txs);
        let claim = ZecClaim {
            zatoshi: 1,
            uivk: testdata::claim_uivk_payload(),
        };
        assert!(!oracle.paid((275, 1, 2), &claim));
        assert_eq!(
            oracle.refusal((275, 1, 2)).map(|r| r.why),
            Some("lightwalletd said NotFound".to_string())
        );
        // A location nobody asked about stays clean, so the replay cannot attach the clause to
        // the wrong message.
        assert_eq!(oracle.refusal((264, 1, 3)), None);
    }
}
