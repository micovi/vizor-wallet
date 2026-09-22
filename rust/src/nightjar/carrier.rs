//! Getting the Zcash transaction that carried a Nightjar message, and proving that it did.
//!
//! [`crate::nightjar::zec`] can answer "did this transaction pay this claim?" only once somebody
//! puts the transaction in its hand. This module is that somebody. It is the piece the indexer
//! cut removed: `nightjar-scanner` is handed the block it is scanning, so the carrying
//! transaction is never in doubt for it, whereas this wallet is handed message *bodies* over
//! HTTP and has to go and find the transaction itself.
//!
//! # Where the bytes come from
//!
//! In order, stopping at the first that answers:
//!
//! 1. **This wallet's own database.** It scans every block, so a transaction it was a party to
//!    is already in `transactions.raw` and costs one SQLite read and no network at all. On a
//!    channel this wallet trades on, this is the common case.
//! 2. **`GetTransaction` over the existing lightwalletd gRPC**, for the transactions it does not
//!    hold — which is most of them, because a channel is a public place and most of its traffic
//!    belongs to other people.
//!
//! The indexer is deliberately **not** a third source here. It could be one — the bytes are
//! self-authenticating under [`bind`] below, so using it would not be asking it for a verdict —
//! but it is not needed: lightwalletd serves any transaction on the chain to anybody, so there
//! is no availability the indexer would add. Keeping it out means there is no code path on which
//! the thing that supplied the message also supplied the evidence about the message.
//!
//! # Why the bytes cannot lie
//!
//! The fetch is keyed by a `txid` that came from the indexer, and a `txid` is **not** bound to a
//! `msg_id` by anything in the protocol — so a hostile source could name a transaction that pays
//! a claim the real one did not. [`bind`] closes that, and closes it without trusting the txid at
//! all:
//!
//! * the transaction's Ironwood actions are trial-decrypted with **the channel's own incoming
//!   viewing key**, derived here from the channel UIVK the user configured;
//! * the Nightjar fragments that come out must cover slots `0..count-1` of *this* `msg_id`, with
//!   payloads equal to the slices of *this* body;
//! * and the body hashes to `msg_id` ([`crate::nightjar::replay::check_binding`], already run).
//!
//! A transaction that satisfies that **is** a transaction that carried the message: it contains
//! the whole message, under the channel key, in the sender's own framing. Substituting a
//! different transaction would mean building one that carries the same message — which is to say,
//! carrying the message.
//!
//! What remains outside the binding is the *location*: the indexer says the message completed at
//! `(height, tx_index, action_index)`, and a source that replayed somebody's fragments into a
//! later transaction of its own could name that copy instead. That is the same residual the rest
//! of this cut has — an indexer can withhold, and comparing `state_root` against a second
//! verifier is what catches it — and it is narrower here than it looks, because the copy would
//! have to have been mined, and `Delivered`'s completion rules give the *first* complete framing
//! the message.
//!
//! # Cost
//!
//! One round trip per distinct claim-carrying transaction, never one per message
//! ([`crate::nightjar::zec::claim_carrying`] selects them and [`resolve`] dedupes on txid), and
//! none at all for a channel that has never carried a claim. The whole pass is bounded by
//! [`MAX_FETCHES`] and by [`FETCH_BUDGET`]: the replay is called from Dart through FRB and runs
//! on a phone, so "a channel with a thousand claims" must not turn into a thousand serial round
//! trips, and a lightwalletd that has gone away must not hang the Nightjar screen.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use nightjar_codec::transport::{parse, Location, MsgId, FRAGMENT_PAYLOAD};
use orchard::keys::PreparedIncomingViewingKey;
use orchard::note_encryption::IronwoodDomain;
use zcash_keys::keys::UnifiedIncomingViewingKey;
use zcash_primitives::transaction::Transaction;
use zcash_protocol::consensus::{BlockHeight, BranchId};


use crate::nightjar::replay::Message;
use crate::nightjar::zec::CarryingTxs;
use crate::wallet::network::WalletNetwork;

/// Hard ceiling on carrying-transaction fetches in one replay.
///
/// Not a performance tuning knob — a bound on unbounded work reached from a UI thread's future.
/// A channel with more claim-carrying transactions than this replays with the rest refused for
/// want of evidence, which is the fail-closed answer and is visible in the outcome list, rather
/// than the wallet sitting on a spinner proportional to somebody else's traffic.
pub const MAX_FETCHES: usize = 256;

/// Wall-clock budget for the whole fetch pass. Each individual gRPC call already has
/// lightwalletd's own 20 s unary timeout; this bounds the *sequence* of them.
pub const FETCH_BUDGET: Duration = Duration::from_secs(30);

/// Where this wallet may look for a carrying transaction. Empty strings mean "not available",
/// which is an ordinary state: a locked wallet has no database path to give, and a wallet that
/// has never synced has no lightwalletd URL.
#[derive(Clone, Debug, Default)]
pub struct TxSources {
    /// Path to this wallet's `zakura-client-sqlite` database.
    pub db_path: String,
    /// The lightwalletd the wallet syncs against. Never the indexer.
    pub lightwalletd_url: String,
}

impl TxSources {
    pub fn is_empty(&self) -> bool {
        self.db_path.trim().is_empty() && self.lightwalletd_url.trim().is_empty()
    }
}

/// One message's carrying transaction, proven to be that message's.
#[derive(Clone, Debug)]
pub struct Carrier {
    /// Raw transaction bytes, as some source handed them over.
    pub raw: Arc<Vec<u8>>,
    /// Where each of the message's `count` fragments sits inside this transaction, in slot order.
    ///
    /// This is what `Delivered::fragments` has to be for `single_transaction()` to mean anything.
    /// Before this module the replay filled it with one copy of the completion location, which
    /// made `single_transaction()` unconditionally true — harmless only because `NoZec` refused
    /// every claim anyway, and a live landmine the moment it stopped doing so.
    pub fragments: Vec<Location>,
    /// Which source answered, for diagnostics.
    pub source: &'static str,
}

/// What [`resolve`] made of each claim-carrying message.
#[derive(Clone, Debug, Default)]
pub struct Carriers {
    pub found: BTreeMap<MsgId, Carrier>,
    /// `msg_id` → why its carrying transaction is not in hand. Every one of these becomes a
    /// refused claim with a reason distinguishable from "checked and unpaid".
    pub failed: BTreeMap<MsgId, String>,
}

impl Carriers {
    /// The view [`crate::nightjar::zec::PaidClaims`] wants: bytes and reasons per
    /// `(height, tx_index)`.
    pub fn carrying_txs(&self, messages: &[Message]) -> CarryingTxs {
        let mut out = CarryingTxs::default();
        for m in messages {
            let key = (m.completion.0, m.completion.1);
            if let Some(c) = self.found.get(&m.msg_id) {
                out.have.insert(key, c.raw.clone());
            } else if let Some(why) = self.failed.get(&m.msg_id) {
                out.missing.entry(key).or_insert_with(|| why.clone());
            }
        }
        out
    }
}

/// Prove that `raw` is the transaction that carried `msg`, and say where its fragments are.
///
/// See the module comment for why this, and not the txid, is the binding. The check is
/// deliberately stated in terms of the *body the caller already has*: each slot's expected
/// payload is a slice of `msg.body`, so a transaction carrying a different framing of a different
/// message cannot satisfy it, and the lowest action index carrying each expected payload is
/// exactly the location `Delivered::fragments` rule 1 reports for a message the completing
/// transaction carried in full.
///
/// Returns the per-slot locations on success. Failure is a sentence for the outcome list, not an
/// error for the replay: a claim whose carrier cannot be proven is refused, and the channel keeps
/// replaying.
pub fn bind(
    params: &WalletNetwork,
    channel_ivk: &PreparedIncomingViewingKey,
    raw: &[u8],
    msg: &Message,
) -> Result<Vec<Location>, String> {
    let (height, tx_index, _) = msg.completion;
    let tx = Transaction::read(raw, BranchId::for_height(params, BlockHeight::from_u32(height)))
        .map_err(|e| format!("the fetched transaction does not parse: {e}"))?;
    let Some(bundle) = tx.ironwood_bundle() else {
        return Err("the fetched transaction has no Ironwood bundle, so it carried no Nightjar \
                    memo"
            .to_string());
    };

    // The framing the sender used, reconstructed from the body the caller holds. `frame` splits
    // on `FRAGMENT_PAYLOAD` and pins every non-final fragment to a full payload, so this is the
    // only split that can hash to `msg_id`.
    let count = msg.count as usize;
    if count == 0 || msg.body.is_empty() {
        return Err("a message with no fragments cannot be bound to a transaction".to_string());
    }
    let expected: Vec<&[u8]> = msg.body.chunks(FRAGMENT_PAYLOAD).collect();
    if expected.len() != count {
        return Err(format!(
            "the body splits into {} fragments, not the {count} the message claims",
            expected.len()
        ));
    }

    // Lowest action index carrying each slot's expected payload. Lowest, not first found: rule 1
    // on `Delivered::fragments` reports the lowest index the winning payload appears at inside
    // the completing transaction, and two verifiers only agree because that is a total order.
    let mut at: Vec<Option<u32>> = vec![None; count];
    for (i, action) in bundle.actions().iter().enumerate() {
        let domain = IronwoodDomain::for_action(action);
        let Some((_note, _addr, memo)) =
            zcash_note_encryption::try_note_decryption(&domain, channel_ivk, action)
        else {
            continue;
        };
        let Ok(header) = parse(&memo) else { continue };
        if header.msg_id != msg.msg_id || header.kind != msg.kind || header.count != msg.count {
            continue;
        }
        let slot = header.index as usize;
        if slot >= count || header.payload != expected[slot] {
            continue;
        }
        let i = i as u32;
        at[slot] = Some(at[slot].map_or(i, |seen| seen.min(i)));
    }

    let missing: Vec<usize> = at
        .iter()
        .enumerate()
        .filter(|(_, a)| a.is_none())
        .map(|(k, _)| k)
        .collect();
    if !missing.is_empty() {
        return Err(format!(
            "the transaction at ({height}, {tx_index}) carries {} of this message's {count} \
             fragments (missing {missing:?}), so this wallet cannot show that one transaction \
             carried the whole message",
            count - missing.len(),
        ));
    }
    Ok(at.into_iter().map(|a| (height, tx_index, a.unwrap())).collect())
}

/// Fetch and bind the carrying transaction of every message in `wanted`.
///
/// `wanted` is [`crate::nightjar::zec::claim_carrying`]'s output: the messages that actually make
/// a ZEC claim. Everything else in the channel needs no transaction and gets none.
pub fn resolve(
    network: WalletNetwork,
    channel_uivk: &str,
    sources: &TxSources,
    wanted: &[&Message],
) -> Carriers {
    let mut out = Carriers::default();
    if wanted.is_empty() {
        return out;
    }

    // The channel key, which is what makes a fetched transaction provably this message's. A
    // channel UIVK that does not parse is not a per-message failure — nothing on the channel can
    // be bound — but it is still reported per message so the outcome list says it.
    let channel_ivk = match UnifiedIncomingViewingKey::decode(&network, channel_uivk.trim())
        .map_err(|e| format!("the channel UIVK does not decode: {e}"))
        .and_then(|k| {
            k.orchard()
                .clone()
                .ok_or_else(|| "the channel UIVK has no Ironwood component".to_string())
        }) {
        Ok(ivk) => PreparedIncomingViewingKey::new(&ivk),
        Err(why) => {
            for m in wanted {
                out.failed.insert(m.msg_id, why.clone());
            }
            return out;
        }
    };

    if sources.is_empty() {
        for m in wanted {
            out.failed.insert(
                m.msg_id,
                "this wallet has no Zcash transaction source configured (no wallet database and \
                 no lightwalletd), so the carrying transaction could not be fetched"
                    .to_string(),
            );
        }
        return out;
    }

    // One fetch per distinct transaction, however many messages that transaction carried.
    let mut fetched: BTreeMap<[u8; 32], Result<Arc<Vec<u8>>, String>> = BTreeMap::new();
    let mut lwd = LwdFetcher::new(&sources.lightwalletd_url);
    let started = Instant::now();

    for m in wanted {
        let Some(txid) = m.txid else {
            out.failed.insert(
                m.msg_id,
                "the message was served without the txid of the transaction that carried it, so \
                 there is nothing to fetch"
                    .to_string(),
            );
            continue;
        };
        let entry = match fetched.get(&txid) {
            Some(hit) => hit.clone(),
            None => {
                if fetched.len() >= MAX_FETCHES {
                    Err(format!(
                        "this replay has already fetched {MAX_FETCHES} carrying transactions, \
                         which is the per-replay ceiling"
                    ))
                } else if started.elapsed() >= FETCH_BUDGET {
                    Err(format!(
                        "the {}s budget for fetching carrying transactions ran out",
                        FETCH_BUDGET.as_secs()
                    ))
                } else {
                    let got = fetch_one(&sources.db_path, &mut lwd, &txid);
                    fetched.insert(txid, got.clone());
                    got
                }
            }
        };
        match entry {
            Ok(raw) => match bind(&network, &channel_ivk, &raw, m) {
                Ok(fragments) => {
                    out.found.insert(
                        m.msg_id,
                        Carrier {
                            raw,
                            fragments,
                            source: "fetched",
                        },
                    );
                }
                Err(why) => {
                    out.failed.insert(m.msg_id, why);
                }
            },
            Err(why) => {
                out.failed.insert(m.msg_id, why);
            }
        }
    }
    out
}

/// Source 1: this wallet's own database. `transactions.txid` holds the 32 bytes in internal
/// order, which is the reverse of the hex a block explorer or the indexer prints.
fn from_wallet_db(db_path: &str, txid: &[u8; 32]) -> Option<Arc<Vec<u8>>> {
    if db_path.trim().is_empty() {
        return None;
    }
    let conn = crate::wallet::sync::open_readonly_conn(db_path).ok()?;
    let raw: Vec<u8> = conn
        .query_row(
            "SELECT raw FROM transactions WHERE txid = ?1 AND raw IS NOT NULL",
            [&txid[..]],
            |row| row.get(0),
        )
        .ok()?;
    (!raw.is_empty()).then(|| Arc::new(raw))
}

/// A lightwalletd connection opened at most once per replay, and only if source 1 misses.
struct LwdFetcher<'a> {
    url: &'a str,
    /// `None` until first use; `Some(Err)` once connecting has failed, so a dead server costs one
    /// connect attempt for the whole replay rather than one per transaction.
    runtime: Option<Result<tokio::runtime::Runtime, String>>,
}

impl<'a> LwdFetcher<'a> {
    fn new(url: &'a str) -> Self {
        LwdFetcher {
            url: url.trim(),
            runtime: None,
        }
    }

    /// Source 2: `GetTransaction`. Blocking, on a current-thread runtime, which is what the rest
    /// of this crate's synchronous FFI entry points do (`ffi.rs`); the FRB worker thread this
    /// runs on is already spending seconds in Groth16 verification.
    fn get(&mut self, txid: &[u8; 32]) -> Result<Arc<Vec<u8>>, String> {
        if self.url.is_empty() {
            return Err("no lightwalletd URL".to_string());
        }
        if self.runtime.is_none() {
            self.runtime = Some(
                tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .map_err(|e| format!("could not start a lightwalletd runtime: {e}")),
            );
        }
        let runtime = match self.runtime.as_ref().unwrap() {
            Ok(rt) => rt,
            Err(e) => return Err(e.clone()),
        };
        let url = self.url.to_string();
        let hash = txid.to_vec();
        runtime.block_on(async move {
            let mut client =
                crate::wallet::sync_engine::open_background_direct_lwd_channel(&url)
                    .await
                    .map_err(|e| format!("could not reach lightwalletd at {url}: {e}"))?;
            let tx = crate::wallet::sync_engine::get_transaction(&mut client, hash)
                .await
                .map_err(|e| format!("lightwalletd GetTransaction failed: {e}"))?;
            if tx.data.is_empty() {
                return Err("lightwalletd returned an empty transaction".to_string());
            }
            Ok(Arc::new(tx.data))
        })
    }
}

fn fetch_one(
    db_path: &str,
    lwd: &mut LwdFetcher<'_>,
    txid: &[u8; 32],
) -> Result<Arc<Vec<u8>>, String> {
    if let Some(raw) = from_wallet_db(db_path, txid) {
        return Ok(raw);
    }
    lwd.get(txid).map_err(|e| {
        format!(
            "the carrying Zcash transaction could not be fetched, so the claim could not be \
             checked (this wallet's database does not hold it and {e})"
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nightjar::testdata::claims as testdata;

    fn channel_ivk() -> PreparedIncomingViewingKey {
        let key =
            UnifiedIncomingViewingKey::decode(&WalletNetwork::Regtest, testdata::CHANNEL_UIVK)
                .expect("the devnet channel UIVK decodes");
        PreparedIncomingViewingKey::new(&key.orchard().clone().expect("Ironwood component"))
    }

    /// The recorded carrying transaction really does carry the message the indexer filed under
    /// it, and `bind` finds every one of its fragments inside that one transaction — which is
    /// what makes `single_transaction()` true by evidence rather than by assumption.
    #[test]
    fn the_recorded_transaction_carries_the_whole_claim_message() {
        let ivk = channel_ivk();
        for m in testdata::messages() {
            let Some(raw) = testdata::raw_tx_for(&m.msg_id) else {
                continue;
            };
            let fragments =
                bind(&WalletNetwork::Regtest, &ivk, &raw, &m).expect("the recorded carrier binds");
            assert_eq!(fragments.len(), m.count as usize);
            for f in &fragments {
                assert_eq!(
                    (f.0, f.1),
                    (m.completion.0, m.completion.1),
                    "every fragment is inside the completing transaction"
                );
            }
            // Slot order, and distinct action indices: two slots resolving to one action would
            // mean the same memo was counted twice.
            let mut seen: Vec<u32> = fragments.iter().map(|f| f.2).collect();
            seen.sort_unstable();
            seen.dedup();
            assert_eq!(seen.len(), fragments.len());
        }
    }

    /// The binding is against *this* message: the other claim message's transaction must not
    /// bind, even though both are on the same channel, carry the same kind and make a claim to
    /// the same account.
    #[test]
    fn a_transaction_does_not_bind_to_another_messages_body() {
        let ivk = channel_ivk();
        let carriers: Vec<(Message, Vec<u8>)> = testdata::messages()
            .into_iter()
            .filter_map(|m| testdata::raw_tx_for(&m.msg_id).map(|raw| (m, raw)))
            .collect();
        assert!(
            carriers.len() >= 2,
            "the recording must keep both claim-carrying transactions"
        );
        let err = bind(&WalletNetwork::Regtest, &ivk, &carriers[1].1, &carriers[0].0)
            .expect_err("another message's transaction must not bind");
        assert!(err.contains("fragments"), "{err}");
    }

    /// Bytes that are not a transaction at all are a refusal with a reason, never a panic and
    /// never a pass.
    #[test]
    fn rubbish_bytes_do_not_bind() {
        let ivk = channel_ivk();
        let m = testdata::messages()
            .into_iter()
            .find(|m| testdata::raw_tx_for(&m.msg_id).is_some())
            .expect("a claim message");
        let err = bind(&WalletNetwork::Regtest, &ivk, &[0u8; 64], &m).unwrap_err();
        assert!(err.contains("does not parse"), "{err}");
    }

    /// With nowhere to look, every claim-carrying message fails with a reason that names the
    /// missing configuration rather than accusing the transaction of not paying.
    #[test]
    fn no_sources_fails_every_message_closed() {
        let messages = testdata::messages();
        let wanted: Vec<&Message> = messages
            .iter()
            .filter(|m| testdata::raw_tx_for(&m.msg_id).is_some())
            .collect();
        assert!(!wanted.is_empty());
        let out = resolve(
            WalletNetwork::Regtest,
            testdata::CHANNEL_UIVK,
            &TxSources::default(),
            &wanted,
        );
        assert!(out.found.is_empty());
        assert_eq!(out.failed.len(), wanted.len());
        for why in out.failed.values() {
            assert!(why.contains("no Zcash transaction source"), "{why}");
        }
    }
}
