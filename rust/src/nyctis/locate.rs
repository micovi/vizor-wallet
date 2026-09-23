//! Checking **where** the indexer says each message landed, against the chain itself.
//!
//! [`crate::nyctis::replay::check_binding`] turns a message's `msg_id`, `kind`, `count` and
//! `body` back into facts. The fifth thing the indexer hands over is not covered by it: the
//! completion location `(height, tx_index, action_index)`. That location is not decoration. The
//! replay sorts on it, the finality cut-off (`tip − 10`) is applied to its height, and a note's
//! tree position — which is bound into its nullifier — is its rank in that order. Taken on the
//! indexer's word, the location let a hostile indexer, **without withholding anything**:
//!
//! * report a message from a block that can still reorganise as final, so a receipt shows as
//!   settled balance before it is (F18 bypassed);
//! * move a final message above the cut-off, so it shows as benign "settling" rather than as a
//!   missing message;
//! * swap two messages, which swaps note positions, so this wallet's nullifiers come out wrong —
//!   a spent note reads as unspent, and a payment built on that view names a path the channel
//!   does not have and is ignored after its ZEC is spent.
//!
//! # What is checked
//!
//! For every message that can change the state (see [`needs_location`]), against this wallet's
//! own lightwalletd — never the indexer:
//!
//! 1. **The transaction.** `GetTransaction(txid)` returns the bytes and the height lightwalletd
//!    says it was mined at. A final claim (`height <= canonical`) must name exactly that height;
//!    a preview claim must not name a transaction that is in fact final.
//! 2. **Its position in the block.** The compact block at the claimed height must list the txid
//!    at the claimed `tx_index` (`CompactTx.index`, the index in the full block, which is what
//!    `nyctis-scanner` records).
//! 3. **That it carried the message, and where it completed.** The transaction's Ironwood actions
//!    are trial-decrypted with the *channel's* incoming viewing key, and the memos framing this
//!    message's `(msg_id, kind, count)` are found. `action_index` must be the highest action index
//!    among them — the reassembler's own completion rule (`nyctis-codec`'s `OpenTx::last`: a
//!    message completes at the end of the transaction that completes it, at the last action of
//!    that transaction that carried one of its fragments).
//!
//! A mismatch on any of these is proof that the location was not the chain's, and **fails the
//! whole call** — exactly as a bad `msg_id` does, and for the same reason: skipping the message
//! would hand the indexer the suppression and hide it in a count. A check this wallet could not
//! *make* — lightwalletd unreachable, Tor still starting, a server that does not know the txid —
//! is not a mismatch. It is recorded in [`Locations::unverified`] with the reason, the replay goes
//! on, and the caller is expected to say the view is unverified rather than show its balance.
//!
//! # Privacy: the request set does not depend on what this wallet owns
//!
//! The set of transactions fetched is every message on the channel whose proof verifies (plus
//! the proof-less `NOTE`, `ASSET` and `ENTER` messages), whoever it belongs to. Nothing here
//! consults this wallet's database, so there is no "fetch remotely only what I do not already
//! hold" gap for a lightwalletd operator to read the wallet's trades out of, and the replay that
//! chooses the set is not even handed the seed. And an unproven message cannot trigger a fetch:
//! a hostile indexer that injects a message whose `txid` names a transaction it wants to test
//! gets no request for it — see [`needs_location`].
//!
//! # What is still not checked
//!
//! That the location is the *first* complete framing of the message. Anyone can copy a message's
//! memos into a later transaction of their own, and a source that names the copy has named a real
//! transaction that really carries the message. It can only ever move a message *later* — the
//! copy has to have been mined after the original — and it is the same class of attack as
//! withholding the original, which comparing `state_root` against a second verifier catches.
//! Detecting it locally would mean trial-decrypting every block since the channel's birthday,
//! which is the scanner's job and the one this cut hands to the indexer.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nyctis_codec::transition::Transition;
use nyctis_codec::transport::{
    parse, MsgId, KIND_ASSET, KIND_ENTER, KIND_NOTE, KIND_TRANSITION,
};
use nyctis_state::ProofVerifier;
use orchard::keys::PreparedIncomingViewingKey;
use orchard::note_encryption::IronwoodDomain;
use zcash_primitives::transaction::Transaction;
use zcash_protocol::consensus::{BlockHeight, BranchId};

use crate::nyctis::replay::Message;
use crate::wallet::network::WalletNetwork;

/// Ceiling on chain requests (transactions plus blocks) one replay may make.
///
/// A bound on unbounded work reached from a UI future, not a tuning knob. Anything past it is
/// reported unverified rather than fetched, and the process-wide cache below means the next
/// replay picks up where this one stopped instead of starting again.
pub const MAX_CHAIN_REQUESTS: usize = 4096;

/// Wall-clock budget for the whole location pass. Each gRPC call already carries lightwalletd's
/// own timeout; this bounds the sequence of them.
pub const LOCATION_BUDGET: Duration = Duration::from_secs(90);

/// A transaction as the chain source handed it over.
#[derive(Clone, Debug)]
pub struct ChainTx {
    pub raw: Arc<Vec<u8>>,
    /// The main-chain height lightwalletd reports, or `None` when it says the transaction is in
    /// the mempool or on a fork (`RawTransaction.height` 0 or `u64::MAX`).
    pub mined_height: Option<u32>,
}

/// Where chain facts come from: this wallet's own lightwalletd in the app, a recording in tests.
///
/// **Never the indexer.** It supplied the location; it does not also get to confirm it.
pub trait ChainSource {
    /// `GetTransaction`. `Ok(None)` when the server does not know the txid.
    fn transaction(&mut self, txid: &[u8; 32]) -> Result<Option<ChainTx>, String>;
    /// Every transaction the block at `height` lists, with its index in the full block
    /// (`CompactTx.index`). Internal byte order, like every txid on this side of the FFI.
    fn block(&mut self, height: u32) -> Result<BlockTxs, String>;
}

/// A block's transactions: txid (internal byte order) → index in the full block.
pub type BlockTxs = HashMap<[u8; 32], u32>;

/// A chain source that has nothing to look at: every question is answered with `why`.
///
/// What a wallet with no lightwalletd configured gets. Not an error for the replay — every
/// location is reported unverified with this reason, and the caller says so.
pub struct NoChain(pub String);

impl ChainSource for NoChain {
    fn transaction(&mut self, _: &[u8; 32]) -> Result<Option<ChainTx>, String> {
        Err(self.0.clone())
    }
    fn block(&mut self, _: u32) -> Result<BlockTxs, String> {
        Err(self.0.clone())
    }
}

/// What the location pass established.
#[derive(Clone, Debug, Default)]
pub struct Locations {
    /// Messages whose location the chain confirmed, with the carrying transaction's bytes (which
    /// the ZEC-claim oracle then reads instead of fetching them a second time).
    pub verified: BTreeMap<MsgId, Arc<Vec<u8>>>,
    /// Messages whose location could not be checked, and why. Never a mismatch: a mismatch fails
    /// the call.
    pub unverified: BTreeMap<MsgId, String>,
}

/// Does this message's location matter to the state? Only then is it worth a request.
///
/// A transition matters only if its proof verifies: `State::apply` rejects a message whose body
/// does not decode, whose shape is wrong or whose proof fails **whatever its position** — none of
/// those checks reads the state — so where such a message sits changes nothing a verifier
/// computes. Filtering on it is what keeps an injected message from triggering a fetch at all
/// (the C10 membership oracle), and what keeps channel spam from costing a request each.
///
/// `NOTE`, `ASSET` and `ENTER` messages carry no Groth16 proof; they are checked against the
/// state, so their order can matter and they are always located. Any other kind is ignored by
/// `State::apply` as "unknown message kind" wherever it sits.
pub fn needs_location(proven: &BTreeMap<MsgId, bool>, m: &Message) -> bool {
    match m.kind {
        KIND_TRANSITION => proven.get(&m.msg_id).copied().unwrap_or(false),
        KIND_NOTE | KIND_ASSET | KIND_ENTER => true,
        _ => false,
    }
}

/// Whether each transition's proof verifies, computed once, before the replay.
///
/// Exactly the checks `State::apply` makes before it would call the verifier — decode, shape —
/// then the verifier itself, with the same `channel_id` and the same `ct_digest`. [`Prechecked`]
/// hands the answer back to `State::apply` so the proof is still only verified once.
pub fn prove_all<V: ProofVerifier>(
    verifier: &V,
    cid: &[u8; 32],
    messages: &[Message],
) -> BTreeMap<MsgId, bool> {
    let mut out = BTreeMap::new();
    for m in messages.iter().filter(|m| m.kind == KIND_TRANSITION) {
        let ok = match Transition::decode(&m.body) {
            Ok(tx) => tx.check_shape().is_ok() && verifier.verify(&tx, cid, &tx.ct_digest()),
            Err(_) => false,
        };
        out.insert(m.msg_id, ok);
    }
    out
}

/// A verifier that answers the next question from [`prove_all`]'s table.
///
/// `State::apply` verifies a transition's proof against the transition decoded from the very
/// body [`prove_all`] decoded, under the same `channel_id` and `ct_digest`, so the answer is the
/// same pure function of the same inputs. `answer` is armed per message by the replay loop and
/// taken on use; with nothing armed it verifies for real.
pub struct Prechecked<'a, V: ProofVerifier> {
    pub inner: &'a V,
    pub answer: std::cell::Cell<Option<bool>>,
}

impl<V: ProofVerifier> ProofVerifier for Prechecked<'_, V> {
    fn verify(
        &self,
        tx: &Transition,
        channel_id: &nyctis_codec::transport::ChannelId,
        ct_digest: &[u8; 64],
    ) -> bool {
        match self.answer.take() {
            Some(answer) => answer,
            None => self.inner.verify(tx, channel_id, ct_digest),
        }
    }
}

/// The action index at which `raw` completes `m`: the highest Ironwood action of the transaction
/// that carries a memo framing `(m.msg_id, m.kind, m.count)` under the channel key. `Ok(None)`
/// when it carries none.
///
/// Every such memo counts, not only the ones whose payload wins — the reassembler records every
/// memo of the transaction for the key before it decides (`OpenTx::last`), so a rival payload in
/// the same transaction moves the completion location too.
pub fn completing_action(
    params: &WalletNetwork,
    channel_ivk: &PreparedIncomingViewingKey,
    raw: &[u8],
    height: u32,
    m: &Message,
) -> Result<Option<u32>, String> {
    let tx = Transaction::read(raw, BranchId::for_height(params, BlockHeight::from_u32(height)))
        .map_err(|e| format!("the fetched transaction does not parse: {e}"))?;
    let Some(bundle) = tx.ironwood_bundle() else {
        return Ok(None);
    };
    let mut last = None;
    for (i, action) in bundle.actions().iter().enumerate() {
        let domain = IronwoodDomain::for_action(action);
        let Some((_note, _addr, memo)) =
            zcash_note_encryption::try_note_decryption(&domain, channel_ivk, action)
        else {
            continue;
        };
        let Ok(h) = parse(&memo) else { continue };
        if h.msg_id == m.msg_id && h.kind == m.kind && h.count == m.count {
            last = Some(i as u32);
        }
    }
    Ok(last)
}

fn display_txid(txid: &[u8; 32]) -> String {
    let mut d = *txid;
    d.reverse();
    hex::encode(d)
}

/// Check the location of every message in `wanted` against `chain`.
///
/// `canonical` is the height the replay closes at: a message at or below it is final and its
/// location is checked exactly; one above it is preview, and the only thing checked about it is
/// that it is not a final message in disguise.
///
/// `Err` is a proven mismatch and fails the replay. Everything the chain could not answer lands
/// in [`Locations::unverified`].
pub fn verify_locations(
    params: &WalletNetwork,
    channel_ivk: Option<&PreparedIncomingViewingKey>,
    chain: &mut dyn ChainSource,
    wanted: &[&Message],
    canonical: u32,
) -> Result<Locations, String> {
    let mut out = Locations::default();
    let Some(channel_ivk) = channel_ivk else {
        for m in wanted {
            out.unverified.insert(
                m.msg_id,
                "the channel UIVK has no Ironwood component this wallet can decrypt with, so no \
                 message location can be checked"
                    .to_string(),
            );
        }
        return Ok(out);
    };

    let started = Instant::now();
    let mut requests = 0usize;
    let mut over_budget = || -> Option<String> {
        if requests >= MAX_CHAIN_REQUESTS {
            return Some(format!(
                "this replay has already made {MAX_CHAIN_REQUESTS} chain requests, which is the \
                 per-replay ceiling"
            ));
        }
        if started.elapsed() >= LOCATION_BUDGET {
            return Some(format!(
                "the {}s budget for checking message locations ran out",
                LOCATION_BUDGET.as_secs()
            ));
        }
        requests += 1;
        None
    };
    // One request per distinct transaction and per distinct block, however many messages they
    // carried.
    let mut txs: HashMap<[u8; 32], Result<Option<ChainTx>, String>> = HashMap::new();
    let mut blocks: HashMap<u32, Result<BlockTxs, String>> = HashMap::new();

    for m in wanted {
        let (height, tx_index, action_index) = m.completion;
        let is_final = height <= canonical;
        let Some(txid) = m.txid else {
            out.unverified.insert(
                m.msg_id,
                "the message was served without the txid of the transaction that carried it, so \
                 there is nothing to check its location against"
                    .to_string(),
            );
            continue;
        };
        let got = match txs.get(&txid) {
            Some(hit) => hit.clone(),
            None => {
                let got = match over_budget() {
                    Some(why) => Err(why),
                    None => chain.transaction(&txid),
                };
                txs.insert(txid, got.clone());
                got
            }
        };
        let tx = match got {
            Ok(Some(tx)) => tx,
            Ok(None) => {
                out.unverified.insert(
                    m.msg_id,
                    format!(
                        "lightwalletd does not know transaction {}, so where this message landed \
                         could not be checked",
                        display_txid(&txid)
                    ),
                );
                continue;
            }
            Err(why) => {
                out.unverified.insert(
                    m.msg_id,
                    format!("where this message landed could not be checked: {why}"),
                );
                continue;
            }
        };

        // 1. The height.
        match (tx.mined_height, is_final) {
            (Some(mined), true) if mined != height => {
                return Err(format!(
                    "message {} is served as completing at height {height}, but its transaction \
                     {} was mined at {mined}; the source is not reporting the chain",
                    hex::encode(m.msg_id),
                    display_txid(&txid)
                ));
            }
            (None, true) => {
                return Err(format!(
                    "message {} is served as final at height {height}, but its transaction {} is \
                     not in the main chain; the source is not reporting the chain",
                    hex::encode(m.msg_id),
                    display_txid(&txid)
                ));
            }
            (Some(mined), false) if mined <= canonical => {
                return Err(format!(
                    "message {} is served as not yet final (height {height}), but its transaction \
                     {} was mined at {mined}, at or below the final height {canonical}; the \
                     source is hiding a final message",
                    hex::encode(m.msg_id),
                    display_txid(&txid)
                ));
            }
            _ => {}
        }

        // 3. That it carried the message, and at which action it completed.
        let last = match completing_action(
            params,
            channel_ivk,
            &tx.raw,
            tx.mined_height.unwrap_or(height),
            m,
        ) {
            Ok(last) => last,
            Err(why) => {
                // Bytes from lightwalletd that do not parse say nothing about the indexer.
                out.unverified.insert(m.msg_id, why);
                continue;
            }
        };
        let Some(last) = last else {
            return Err(format!(
                "message {} is served as carried by transaction {}, which carries no fragment of \
                 it under the channel key; the source is not reporting the chain",
                hex::encode(m.msg_id),
                display_txid(&txid)
            ));
        };
        if !is_final {
            // Preview: dropped by the replay whatever its exact position; the one lie that
            // matters about it — a final message passed off as preview — is refused above.
            out.verified.insert(m.msg_id, tx.raw.clone());
            continue;
        }
        if last != action_index {
            return Err(format!(
                "message {} is served as completing at action {action_index} of its transaction, \
                 but the transaction's last fragment of it is at action {last}; the source is \
                 not reporting the chain",
                hex::encode(m.msg_id)
            ));
        }

        // 2. The position in the block.
        let block = match blocks.get(&height) {
            Some(hit) => hit.clone(),
            None => {
                let got = match over_budget() {
                    Some(why) => Err(why),
                    None => chain.block(height),
                };
                blocks.insert(height, got.clone());
                got
            }
        };
        let index = block.map(|b| b.get(&txid).copied());
        match index {
            Ok(Some(i)) if i == tx_index => {}
            Ok(Some(i)) => {
                return Err(format!(
                    "message {} is served as carried by transaction {tx_index} of block {height}, \
                     but that block lists its transaction {} at index {i}; the source is not \
                     reporting the chain",
                    hex::encode(m.msg_id),
                    display_txid(&txid)
                ));
            }
            Ok(None) => {
                // lightwalletd said the transaction was mined at this height and then did not
                // list it there. That is lightwalletd disagreeing with itself, not evidence
                // about the indexer, so it is reported rather than blamed.
                out.unverified.insert(
                    m.msg_id,
                    format!(
                        "lightwalletd reports transaction {} at height {height} but its block \
                         does not list it",
                        display_txid(&txid)
                    ),
                );
                continue;
            }
            Err(why) => {
                out.unverified.insert(
                    m.msg_id,
                    format!("where this message landed could not be checked: {why}"),
                );
                continue;
            }
        }
        out.verified.insert(m.msg_id, tx.raw.clone());
    }
    Ok(out)
}

/// Chain facts that cannot change any more, shared by every replay in the process.
///
/// A transaction mined at or below the canonical height, and the transaction list of a block at
/// or below it, are final by the same rule the replay itself relies on, so asking again on the
/// next refresh would buy nothing. Keyed on the network's wire byte as well as the txid or
/// height, so a wallet that switches networks never reads one chain's facts as another's.
///
/// **What goes in is a function of the channel alone** — the same proven messages every wallet
/// replaying the channel asks about — so what the cache saves a later replay from requesting is
/// no more telling than the requests it replaces.
#[derive(Default)]
struct ChainCache {
    txs: HashMap<(u8, [u8; 32]), ChainTx>,
    tx_bytes: usize,
    blocks: HashMap<(u8, u32), BlockTxs>,
}

/// Raw bytes the cache may hold before it stops adding transactions. A replay past it still
/// works; it simply asks again next time.
const CACHE_MAX_TX_BYTES: usize = 64 * 1024 * 1024;

static CHAIN_CACHE: Mutex<Option<ChainCache>> = Mutex::new(None);

/// A [`ChainSource`] in front of another that remembers final answers across replays.
pub struct Cached<'a> {
    pub inner: &'a mut dyn ChainSource,
    pub network: u8,
    pub canonical: u32,
}

impl ChainSource for Cached<'_> {
    fn transaction(&mut self, txid: &[u8; 32]) -> Result<Option<ChainTx>, String> {
        let key = (self.network, *txid);
        if let Some(hit) = CHAIN_CACHE
            .lock()
            .ok()
            .and_then(|c| c.as_ref().and_then(|c| c.txs.get(&key).cloned()))
        {
            return Ok(Some(hit));
        }
        let got = self.inner.transaction(txid)?;
        if let Some(tx) = &got {
            if tx.mined_height.is_some_and(|h| h <= self.canonical) {
                if let Ok(mut guard) = CHAIN_CACHE.lock() {
                    let cache = guard.get_or_insert_with(ChainCache::default);
                    if cache.tx_bytes + tx.raw.len() <= CACHE_MAX_TX_BYTES {
                        cache.tx_bytes += tx.raw.len();
                        cache.txs.insert(key, tx.clone());
                    }
                }
            }
        }
        Ok(got)
    }

    fn block(&mut self, height: u32) -> Result<BlockTxs, String> {
        let key = (self.network, height);
        if let Some(hit) = CHAIN_CACHE
            .lock()
            .ok()
            .and_then(|c| c.as_ref().and_then(|c| c.blocks.get(&key).cloned()))
        {
            return Ok(hit);
        }
        let got = self.inner.block(height)?;
        if height <= self.canonical {
            if let Ok(mut guard) = CHAIN_CACHE.lock() {
                guard
                    .get_or_insert_with(ChainCache::default)
                    .blocks
                    .insert(key, got.clone());
            }
        }
        Ok(got)
    }
}
