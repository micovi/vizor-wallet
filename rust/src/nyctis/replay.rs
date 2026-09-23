//! Offline replay of a Nyctis channel from messages somebody else fetched.
//!
//! The reference implementation (`nyctis-scanner`) does two jobs in one pass: it finds the
//! channel's memos by trial-decrypting every Ironwood action with the channel's incoming viewing
//! key, and it replays the messages those memos reassemble into. This wallet cannot link that
//! crate — it depends on upstream librustzcash, which would put a second, incompatible Zcash
//! stack beside the Zakura forks everything else here is built on. So the two jobs are split:
//! finding and reassembling the messages is the Nyctis indexer's, fetched over HTTP from Dart,
//! and replaying them is this module's.
//!
//! **That split moves data availability to the indexer and nothing else.** It hands over message
//! bodies and a verifying key; every Groth16 proof, every signature, every nullifier and the
//! whole commitment tree are recomputed here, so it cannot forge a balance.
//!
//! Nothing it says about a message is taken on its word either, and that took a fix. A message
//! arrives with a `msg_id`, and `msg_id` is not covered by the proof (which commits to the
//! transition's field elements) nor by `tx.sighash` (which commits to `channel_id ‖ body`). It is
//! what `State::apply` uses as its replay-protection key and folds into `applied_hash` inside
//! `state_root`, so an id taken on trust is a free hand on the one number this design asks two
//! verifiers to compare: renaming one applied message's id moves `state_root` with every proof
//! still verifying, and copying one applied message's id onto another suppresses the second
//! message while every message served stays individually valid. [`check_binding`] closes that —
//! `msg_id` is recomputed from the body here and a mismatch fails the whole call.
//!
//! One thing the split does **not** hand over is the evidence behind a ZEC claim. Checking a
//! claim needs the Zcash transaction that carried the message, which for a while meant this
//! module had none and refused every claim ([`nyctis_state::NoZec`]). It no longer does:
//! [`crate::nyctis::carrier`] fetches that transaction from this wallet's own database or its
//! own lightwalletd and proves it carried the message, and [`crate::nyctis::zec`] — a port of
//! the scanner's `PaidClaims` — answers the question. The indexer supplies neither the bytes nor
//! the verdict. See the `ZEC claims` section on [`replay`] for what is checked and what is not.
//!
//! What the indexer *can* still do is withhold a message, and there is nothing in this file that
//! would notice. That is the documented limit of this cut: comparing `state_root` against a
//! second verifier is what catches it, which is exactly why the id binding above has to hold.

use std::collections::BTreeMap;

use nyctis_codec::transport::{
    channel_id, msg_id, ChannelId, Delivered, Location, FINALITY_DEPTH, JOURNAL_DEPTH,
};
use nyctis_state::{AppliedNote, Outcome, State};
use nyctis_zk::tree::PoseidonHasher;
use nyctis_zk::verifier::Groth16Verifier;

use crate::nyctis::carrier::{self, Carriers, TxSources};
use crate::nyctis::network::NyctisNetwork;
use crate::nyctis::zec::{self, PaidClaims};
use crate::wallet::network::WalletNetwork;

/// One reassembled message as the indexer reports it.
///
/// Every field here is a claim by whoever served the message, and [`check_binding`] is what turns
/// three of them back into facts: `msg_id` is a hash of `kind`, `count` and `body` under the
/// channel, so the four agree or the message is not the message it says it is.
#[derive(Clone, Debug)]
pub struct Message {
    pub msg_id: [u8; 32],
    pub kind: u8,
    /// How many memo fragments carried the body — the indexer's `fragments`, and the `count` the
    /// sender wrote into memo bytes 42..44.
    ///
    /// Carried rather than derived. It is recoverable from the body length today
    /// (`count = ceil(len / FRAGMENT_PAYLOAD)`, because `parse` pins every non-final fragment to
    /// a full payload), but deriving it would make the binding below check the id against a
    /// reconstruction of the framing instead of against the framing that was used, and the whole
    /// value of the check is that it is over what the sender actually hashed.
    pub count: u16,
    /// `(height, tx_index, action_index)` of the fragment that completed the message.
    pub completion: Location,
    /// The Zcash transaction the indexer says completed this message, in **internal** byte order
    /// (the reverse of the hex a block explorer prints). `None` when the source did not say.
    ///
    /// A fetch key and nothing more. Nothing in the protocol binds a `txid` to a `msg_id`, so
    /// this is not evidence and is never treated as any: what makes a fetched transaction *this*
    /// message's is [`crate::nyctis::carrier::bind`], which finds the message's own fragments
    /// inside it under the channel key. A wrong txid therefore costs a failed bind and a refused
    /// claim, not a wrong verdict.
    pub txid: Option<[u8; 32]>,
    pub body: Vec<u8>,
}

impl Message {
    /// The `msg_id` this message's own contents produce on `cid`.
    pub fn expected_id(&self, cid: &ChannelId) -> [u8; 32] {
        msg_id(cid, self.kind, self.count, &self.body)
    }
}

/// Refuse a message whose `msg_id` is not the hash of its own body.
///
/// **This is the only thing standing between a hostile message source and `state_root`.** The
/// binding is `msg_id = BLAKE2b-256("nyctis.msg.v0" ‖ channel_id ‖ [VERSION, kind] ‖ count_le ‖
/// body)` (transport-envelope-v0 section 3), and `nyctis_state` leans on it hard: the comment
/// on `State::apply`'s replay check says in as many words that "`msg_id` commits to the whole
/// body (and to `kind` and `count`), so the same id is the same message", and a zero-input
/// issuance has no nullifier, so that set is its *only* replay protection — an uncapped issuance
/// skips the supply-cap check as well. Feed it ids it did not verify and a message re-mints, or
/// is suppressed by being given an id that is already in the set.
///
/// The reassembler computes this hash itself and will not complete a message that fails it, so an
/// honest source cannot produce a mismatch — every message of the recorded fixture channel
/// (`rust/tests/fixtures/nyctis/devnet-channel.json`) recomputes exactly, as did all 67 the devnet
/// indexer served on 23 September 2026. A mismatch is therefore never a message to skip past; it is proof that the thing
/// answering `/api/messages` is not running the protocol, and continuing would produce a root
/// that looks authoritative. Hence an error for the whole replay rather than a per-message
/// ignore: dropping just the bad message would hand the attacker the suppression they were after
/// and hide it in a count the UI treats as ordinary channel spam.
pub fn check_binding(cid: &ChannelId, m: &Message) -> Result<(), String> {
    let want = m.expected_id(cid);
    if want == m.msg_id {
        return Ok(());
    }
    Err(format!(
        "message {} at {:?} is served under an id its own body does not produce (kind {}, {} \
         fragment(s), {}-byte body hash to {} instead); the source is not running the protocol",
        hex::encode(m.msg_id),
        m.completion,
        m.kind,
        m.count,
        m.body.len(),
        hex::encode(want),
    ))
}

/// What the state machine made of each message, in the order they were applied.
#[derive(Clone, Debug)]
pub struct MessageOutcome {
    pub msg_id: [u8; 32],
    /// `false` for `Outcome::Ignored` and nothing else; `Published` and `Named` messages are
    /// accepted even though they append no note.
    pub accepted: bool,
    /// Empty when accepted, the state machine's own reason string otherwise. Kept verbatim: the
    /// difference between "proof rejected", "unknown anchor" and "message already applied" is
    /// the whole diagnostic value of a replay that came out short.
    pub reason: String,
    /// **The message made a ZEC claim this wallet could not check at all**, as distinct from one
    /// it checked and found unpaid.
    ///
    /// The two are the same `false` inside `State::apply` and come back out as the same sentence
    /// — "ZEC claim of N zatoshi not paid by the carrying transaction" — which is a lie when the
    /// carrying transaction was never in hand. [`crate::nyctis::zec::PaidClaims`] keeps the
    /// difference on the side, this flag carries it out, and [`Self::reason`] has the reason
    /// appended to it. A wallet that cannot tell the user which of the two happened is telling
    /// them the network rejected a payment when in fact the wallet could not look at it.
    pub zec_unverifiable: bool,
}

/// Which applied message spent one note, found by the nullifier that message published.
///
/// The spending message is the whole provenance of an outgoing payment: after a send, the only
/// note of it this wallet still owns is the change, and without the id of the message that
/// consumed the input there is nothing to group that change with — it reads as money arriving.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SpentBy {
    pub msg_id: [u8; 32],
    /// The height the spending message completed at, i.e. when the money left.
    pub height: u32,
}

/// A replayed channel, plus what the recovery pass in [`crate::nyctis::owned`] needs to read
/// the notes back out of it.
pub struct ChannelView {
    pub state: State<PoseidonHasher>,
    /// `BLAKE2b-256` of the compressed verifying key every proof in this view was checked
    /// against, as [`Groth16Verifier::from_vk_bytes`] computed it.
    ///
    /// Reported so the caller can pin it. `/api/status` publishes `info.vk_hash`, and a client
    /// that fetches the key from the same server it fetches the hash from has pinned nothing —
    /// the value is only worth anything compared against one obtained elsewhere, or against a
    /// value the user was given out of band. Two indexers advertising the same `circuit` string
    /// while holding disjoint accepted-proof sets are told apart by this and by nothing else
    /// (F8), and up to this fix no caller could read it at all.
    pub vk_hash: [u8; 32],
    /// Every message that was fed to the state machine, in application order. Messages above the
    /// canonical height were dropped before the replay and are not here.
    pub messages: Vec<Message>,
    /// `msg_id` → the notes that message appended, which is where a recovered ciphertext gets
    /// its tree position and creation height from.
    pub applied: BTreeMap<[u8; 32], Vec<AppliedNote>>,
    /// `msg_id` → the nullifiers that message published, the mirror of [`Self::applied`]. It is
    /// the *count* that matters to a reader: a transition consumes up to `MAX_IN` notes, and
    /// "this wallet owned every input" is what separates a payment it authored from one it
    /// merely co-signed. Filled from the same `Outcome::Applied` as `applied` and
    /// [`Self::spent_by`], in the same statement, so the three cannot describe different
    /// messages.
    pub consumed: BTreeMap<[u8; 32], Vec<[u8; 32]>>,
    /// nullifier → the message that published it. The inverted index of [`Self::consumed`], and
    /// the only thing that turns "this note is spent" (a lookup in the nullifier set) into "this
    /// note was spent *by that message, at that height*".
    ///
    /// A nullifier is unique in an applied channel — `State::apply` refuses a transition that
    /// republishes one — so this map loses nothing by keying on it.
    pub spent_by: BTreeMap<[u8; 32], SpentBy>,
    pub outcomes: Vec<MessageOutcome>,
    /// The chain tip this view was built against. Report it; do not build against it.
    pub chain_tip: u32,
    /// How many messages the caller handed over that sat above the canonical height and were
    /// therefore not replayed. Non-zero is normal — it means a payment is on its way — and the
    /// UI is expected to say so rather than to show a balance that is about to change.
    pub preview_messages: u32,
}

impl ChannelView {
    pub fn accepted(&self) -> u32 {
        self.outcomes.iter().filter(|o| o.accepted).count() as u32
    }
    pub fn ignored(&self) -> u32 {
        self.outcomes.iter().filter(|o| !o.accepted).count() as u32
    }
    /// How many messages were refused because a ZEC claim could not be **checked** — not because
    /// it was checked and found unpaid.
    ///
    /// Non-zero means this view is knowingly incomplete and its `state_root` is expected to
    /// differ from a verifier that could see the transactions. That is a different sentence for
    /// the UI than a root mismatch with no explanation, and it is the only one of the two a user
    /// can act on (their lightwalletd is unreachable, or the wallet has not synced).
    pub fn zec_unverifiable(&self) -> u32 {
        self.outcomes.iter().filter(|o| o.zec_unverifiable).count() as u32
    }
    /// The highest block this view contains, i.e. the canonical height it was closed at.
    /// Everything in it — every note position, every nullifier, the state root — is only
    /// meaningful at this height.
    pub fn height(&self) -> u32 {
        self.state.height()
    }
    /// How many blocks of the chain this view deliberately does not contain.
    pub fn preview_blocks(&self) -> u32 {
        self.chain_tip.saturating_sub(self.height())
    }
}

/// **F18** — the highest final height at `chain_tip`: `tip − FINALITY_DEPTH`, never below the
/// block before the channel birthday. Everything above it is preview.
///
/// Restated here rather than imported because `nyctis_scanner::canonical_height` lives in the
/// crate this wallet cannot link. Kept byte-identical to it: the height decides which messages
/// are replayed *and* which anchors survive the prune, so a wallet using a different rule
/// computes a different state root than every other verifier and has nothing to compare against.
pub fn canonical_height(chain_tip: u32, birthday: u32) -> u32 {
    chain_tip
        .saturating_sub(FINALITY_DEPTH)
        .max(birthday.saturating_sub(1))
}

/// The `channel_id` a published UIVK names on `network`.
///
/// **The hash is over the Bech32m *payload*, not the string** (`transport-envelope-v0.md` §1, and
/// `nyctis_scanner::channel_id_for_uivk`). Hashing the string would be the easier mistake and
/// it is unobservable locally: sender and scanner would agree with each other and disagree with
/// every other implementation, so the wallet would replay an empty channel, verify nothing, and
/// report a zero balance with no error to show the user.
pub fn channel_id_for_uivk(network: WalletNetwork, uivk: &str) -> Result<ChannelId, String> {
    let (_hrp, payload) =
        bech32::decode(uivk.trim()).map_err(|e| format!("channel UIVK is not bech32m: {e}"))?;
    Ok(channel_id(network.ny_wire(), 0, &payload))
}

/// Replay `messages` into a verified view of the channel as of the last final block at
/// `chain_tip`.
///
/// `vk` is the compressed Groth16 verifying key, as served on `/api/vk`. It is turned into a real
/// [`Groth16Verifier`] in memory: a light client has no key directory and no `.circuit` sidecar,
/// and a sidecar is written by whoever wrote the key anyway, so writing a temporary file to get
/// through `Groth16Verifier::load` would invent an assurance it does not carry. What identifies a
/// key is its own hash, which `from_vk_bytes` computes and keeps on the verifier — and which is
/// reported back on [`ChannelView::vk_hash`] so the caller can pin it.
///
/// **Every message's `msg_id` is recomputed from its own body first** ([`check_binding`]), and a
/// message whose id its body does not produce fails the whole call. Nothing else rebinds it: the
/// proof commits to the transition's field elements and `tx.sighash` to `channel_id ‖ body`, so
/// an id taken on the source's word is a free hand on the replay-protection set and on
/// `state_root`.
///
/// # ZEC claims
///
/// **ZEC claims — the fill leg of an order — are checked here now.** Checking one means summing
/// the Ironwood outputs of the Zcash transaction that carried the message which decrypt under the
/// claimed key, against a per-`(transaction, account)` budget so one payment cannot fund two
/// claims (spec `transition-v0.md` section 6 step 6b, F24). That is [`crate::nyctis::zec`], a
/// port of `nyctis-scanner`'s `PaidClaims` — the reference implementation cannot be linked into
/// this fork, so agreement with it is established by test rather than by construction.
///
/// This module still has no block. What it has is the ability to go and get the one transaction
/// each claim needs: [`crate::nyctis::carrier`] fetches it from this wallet's own database or
/// over its own lightwalletd gRPC, and **proves it is the transaction that carried the message**
/// by finding that message's own fragments inside it under the channel key. The indexer is not a
/// source of that evidence and is never asked for a verdict.
///
/// What is *still* not checked, and shows in the outcome list rather than being papered over:
///
/// * **A claim whose carrying transaction cannot be fetched is refused** — the old behaviour,
///   deliberately. A wallet that read "I could not look" as "yes" would be the one failure this
///   whole cut exists to prevent. The refusal is marked [`MessageOutcome::zec_unverifiable`] and
///   carries the reason, so "could not be checked" never reads as "checked and unpaid".
/// * **A claim in a message the completing transaction did not carry whole** is refused for the
///   same reason: `single_transaction()` is a statement about where every fragment sat, and this
///   wallet can only make it about fragments it found itself. The spec refuses such a claim
///   anyway (step 6b requires one transaction), so the two agree wherever the evidence exists.
/// * **Withholding.** Unchanged and unchanged by design: comparing `state_root` against a second
///   verifier is what catches an indexer that simply does not serve a message.
pub fn replay(
    network: WalletNetwork,
    channel_uivk: &str,
    birthday: u32,
    chain_tip: u32,
    vk: &[u8],
    messages: Vec<Message>,
    sources: &TxSources,
) -> Result<ChannelView, String> {
    replay_using(
        network,
        channel_uivk,
        birthday,
        chain_tip,
        vk,
        messages,
        &|wanted| carrier::resolve(network, channel_uivk, sources, wanted),
    )
}

/// [`replay`] with the carrying-transaction lookup injected.
///
/// The seam exists so the recorded devnet channel can be replayed offline against transactions
/// recorded beside it — the same bytes, through the same binding, with no network. That test is
/// what stands in for "this port agrees with `PaidClaims`", so it must not be able to drift into
/// exercising a different code path than the live one: everything below this line is shared.
pub fn replay_using(
    network: WalletNetwork,
    channel_uivk: &str,
    birthday: u32,
    chain_tip: u32,
    vk: &[u8],
    messages: Vec<Message>,
    fetch: &dyn Fn(&[&Message]) -> Carriers,
) -> Result<ChannelView, String> {
    let cid = channel_id_for_uivk(network, channel_uivk)?;
    let verifier =
        Groth16Verifier::from_vk_bytes(vk).map_err(|e| format!("loading verifying key: {e}"))?;
    let vk_hash = verifier
        .vk_hash
        .ok_or_else(|| "verifying key has no hash".to_string())?;
    let canonical = canonical_height(chain_tip, birthday);

    // **Every id is rebound to its own body before anything else happens.** See
    // [`check_binding`]: an id is a hash, the proof does not cover it, `tx.sighash` does not
    // cover it, and `State::apply` keys replay protection on it and folds it into `state_root`.
    // Checked here rather than in the FFI layer because the binding needs `channel_id`, which is
    // derived from the UIVK on this side of the seam — and because this is the only door into the
    // state machine, so there is no second path that could forget.
    //
    // Preview messages are checked too, though they are dropped two lines below. They are the
    // same claim from the same source, the check costs one hash, and a caller that re-replays at
    // a higher tip would otherwise meet the failure later, against a balance it had already
    // shown.
    for m in &messages {
        check_binding(&cid, m)?;
    }

    // **F18 — the preview bound is enforced here, not by the caller.** The indexer serves
    // messages from preview blocks too, and the caller is Dart code talking to it over HTTP. If
    // the filter lived up there, one forgotten comparison would silently admit a message from a
    // block that can still reorganise: positions are assigned in application order and a
    // nullifier binds the position, so a reorganisation that merely *reorders* two messages
    // moves a note, changes its nullifier and strands every witness built against it. Putting
    // the bound on this side of the seam makes the wallet's view a function of `chain_tip`
    // alone, which is also the value it can check against its own lightwalletd rather than take
    // from the indexer.
    //
    // The bound has a floor as well as a ceiling. `nyctis-scanner` is handed the block range
    // `[birthday, canonical]` and so never offers the state machine a message below the
    // birthday; `State::new` starts its journal there too. A message completing below it is
    // therefore a location no reference verifier would ever replay, and admitting one silently
    // would be a second way for a message set to differ from the scanner's with the root still
    // looking authoritative. It is refused rather than filtered for the same reason a bad
    // `msg_id` is: a silent drop is indistinguishable from the withholding this cut cannot
    // otherwise detect. Nothing honest produces one — the live devnet's earliest message sits at
    // height 104 against a birthday of 2.
    if let Some(m) = messages.iter().find(|m| m.completion.0 < birthday) {
        return Err(format!(
            "message {} completed at height {}, below the channel birthday {}: no reference \
             verifier replays that block, so this message set is not the channel's",
            hex::encode(m.msg_id),
            m.completion.0,
            birthday,
        ));
    }

    let total = messages.len();
    let mut messages: Vec<Message> = messages
        .into_iter()
        .filter(|m| m.completion.0 <= canonical)
        .collect();
    let preview_messages = (total - messages.len()) as u32;

    // Canonical order, restated locally rather than trusted from the wire. The caller is an HTTP
    // response; if it ever arrives out of order — a paged fetch stitched back together wrongly,
    // say — applying it in that order silently changes the note positions, and a position is
    // bound into the nullifier, so every balance below would be wrong with no error raised.
    // `(height, tx_index, action_index)` is the completion location and is a total order over
    // chain data, which is exactly what makes two verifiers agree.
    messages.sort_by_key(|m| m.completion);

    // **The carrying transactions, fetched once, for the messages that actually claim a payment.**
    //
    // After the sort and after the preview filter, so nothing is fetched for a message that will
    // not be replayed, and before the loop, so the loop stays synchronous and the number of round
    // trips is a function of how many distinct transactions carry claims rather than of how many
    // messages there are. A channel that has never carried a claim — every channel nobody trades
    // on — issues no I/O at all and replays exactly as cheaply as it did before claims were
    // checked.
    let claim_carrying = zec::claim_carrying(&messages);
    let carriers = fetch(&claim_carrying);
    let carrying_txs = carriers.carrying_txs(&messages);
    let mut paid = PaidClaims::new(network, network.ny_wire(), &carrying_txs);

    let mut state = State::new(cid, PoseidonHasher, birthday, JOURNAL_DEPTH as usize);
    let mut applied: BTreeMap<[u8; 32], Vec<AppliedNote>> = BTreeMap::new();
    let mut consumed: BTreeMap<[u8; 32], Vec<[u8; 32]>> = BTreeMap::new();
    let mut spent_by: BTreeMap<[u8; 32], SpentBy> = BTreeMap::new();
    let mut outcomes = Vec::with_capacity(messages.len());
    let mut open_block: Option<u32> = None;

    for msg in &messages {
        let (height, _, _) = msg.completion;
        // The scanner opens and closes a journal entry for *every* block in the range; we only
        // have the blocks that carried a message. Skipping the empty ones in the middle is sound
        // because the two places a block boundary does work are pure functions of heights rather
        // than of how many boundaries went by: `State::apply` bounds `declared_height` and the
        // anchor age against the completion height arithmetically, and `end_block`'s anchor
        // prune keeps exactly the anchors within `ANCHOR_WINDOW` of the height it closes at, so
        // a delayed prune drops the same anchors the skipped one would have. What is *not*
        // optional is the height the last block closes at — see below.
        if open_block != Some(height) {
            state.begin_block(height);
            open_block = Some(height);
        }

        // **Where this message's fragments actually sat.**
        //
        // The indexer reports where a message *completed*, not where each of its fragments
        // landed, and the only consumer of the per-fragment list is
        // `Delivered::single_transaction`, which gates ZEC claims. This used to be
        // `vec![msg.completion]` — one location, equal to the completion, so
        // `single_transaction()` was unconditionally **true**. That was safe only for as long as
        // `NoZec` refused every claim regardless, and it was a landmine underneath the moment
        // this file gained a real oracle: it would have asserted "one transaction carried every
        // fragment" about a message this wallet had seen one fragment location of.
        //
        // So the list is now evidence or it is nothing. When
        // [`crate::nyctis::carrier::bind`] found the message's whole framing inside the
        // completing transaction, these are the per-slot locations it found, every one of them
        // inside that transaction — `single_transaction()` is then true because it was shown,
        // not assumed. Otherwise the list names a location outside the completing transaction,
        // which makes `single_transaction()` false and the claim refused: fail closed. A message
        // with no claim is unaffected either way, because nothing reads the list unless
        // `zec_claims` is non-empty.
        let fragments = match carriers.found.get(&msg.msg_id) {
            Some(c) => c.fragments.clone(),
            None => vec![(msg.completion.0, u32::MAX, u32::MAX)],
        };
        let delivered = Delivered {
            msg_id: msg.msg_id,
            kind: msg.kind,
            completion: msg.completion,
            body: msg.body.clone(),
            fragments,
        };

        let outcome = state.apply(&delivered, &verifier, &mut paid);
        // Why a claim could not be checked, when that is what happened. Two sources: the oracle
        // recorded that it had no transaction to look at, or the carrier never bound. Both are
        // "this wallet could not look", and neither is "the network says unpaid".
        let unverifiable = paid
            .refusal(msg.completion)
            .map(|r| r.why)
            .or_else(|| carriers.failed.get(&msg.msg_id).cloned());
        outcomes.push(match outcome {
            Outcome::Applied {
                msg_id,
                nullifiers,
                notes,
                ..
            } => {
                // Both halves of the provenance, recorded here and nowhere else. The outcome
                // already carries what the message consumed and what it created; dropping the
                // first half is what left the wallet able to say only what it still holds. A
                // spend is not observable anywhere later: the nullifier set the state machine
                // keeps is a set, so after the loop "spent" is knowable and "spent by whom" is
                // not.
                for nf in &nullifiers {
                    spent_by.insert(
                        *nf,
                        SpentBy { msg_id, height },
                    );
                }
                consumed.insert(msg_id, nullifiers);
                applied.insert(msg_id, notes);
                MessageOutcome {
                    msg_id,
                    accepted: true,
                    reason: String::new(),
                    zec_unverifiable: false,
                }
            }
            Outcome::Published { msg_id, .. } | Outcome::Named { msg_id, .. } => MessageOutcome {
                msg_id,
                accepted: true,
                reason: String::new(),
                zec_unverifiable: false,
            },
            // The appended clause is what separates the two refusals a user can do something
            // about. "not paid by the carrying transaction" means the network will not credit
            // this fill either; "could not be checked" means this wallet is blind and the rest
            // of the channel may well have applied the message — which is also why the state
            // root will not match, and the UI has to say so rather than show a balance.
            Outcome::Ignored { msg_id, reason } => match unverifiable {
                Some(why) => MessageOutcome {
                    msg_id,
                    accepted: false,
                    reason: format!("{reason} — could not be checked: {why}"),
                    zec_unverifiable: true,
                },
                None => MessageOutcome {
                    msg_id,
                    accepted: false,
                    reason,
                    zec_unverifiable: false,
                },
            },
        });
    }

    // **The last block must close at the canonical height, not at the last message's.**
    //
    // `end_block` prunes the anchor set, and `prune_anchors` keeps an anchor iff
    // `anchor_height + ANCHOR_WINDOW > height || it is the newest` — a function of the height
    // the block closes at. `state_root` folds `anchor_order`, so closing at the last message's
    // height leaves anchors a full verifier has already dropped, and the two roots diverge the
    // moment the channel has been quiet for more than `ANCHOR_WINDOW` blocks. That is the
    // ordinary state of a channel nobody is trading on, and the divergence is silent: every
    // message verified, every note is in the right place, and the root is simply not the one
    // anyone else computes. Measured on the devnet: 22 anchors and root `3ea7ccf5…` at height
    // 897 where the last message sits, against 1 anchor and `c8d0d8cb…` at canonical height
    // 1108 after 211 empty blocks, which is what the reference scanner and the indexer report
    // (`/api/anchors?as_of=…&live=1` agrees on both counts).
    //
    // Opening a block for a height that carried no message is exactly what the scanner does for
    // every empty block, so this is not a special case bolted on — it is the last iteration of
    // the loop the scanner runs and this function does not.
    if open_block != Some(canonical) {
        state.begin_block(canonical);
    }
    state.end_block();

    Ok(ChannelView {
        state,
        vk_hash,
        messages,
        applied,
        consumed,
        spent_by,
        outcomes,
        chain_tip,
        preview_messages,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nyctis::testdata;
    use crate::nyctis::testdata::claims;

    #[test]
    fn the_devnet_uivk_hashes_to_the_known_channel_id() {
        let id = channel_id_for_uivk(WalletNetwork::Regtest, testdata::CHANNEL_UIVK).unwrap();
        assert_eq!(hex::encode(id), testdata::CHANNEL_ID);
    }

    /// The payload, not the string: hashing the bech32m characters is the plausible mistake and
    /// it produces a different channel with no error anywhere. Pinning the payload hash as the
    /// answer is what makes the vector above test the rule rather than the code.
    #[test]
    fn the_channel_id_is_over_the_bech32m_payload() {
        let (_hrp, payload) = bech32::decode(testdata::CHANNEL_UIVK).unwrap();
        let want = channel_id(WalletNetwork::Regtest.ny_wire(), 0, &payload);
        assert_eq!(hex::encode(want), testdata::CHANNEL_ID);
        let from_string = channel_id(
            WalletNetwork::Regtest.ny_wire(),
            0,
            testdata::CHANNEL_UIVK.as_bytes(),
        );
        assert_ne!(hex::encode(from_string), testdata::CHANNEL_ID);
    }

    /// The same UIVK on another network is another channel. This is the F46 hazard in one
    /// assertion: the wire byte is folded into `channel_id`, which is public input #1 of every
    /// proof, so a wallet that guessed the network would replay a channel nobody is writing to.
    #[test]
    fn the_network_byte_changes_the_channel() {
        let regtest = channel_id_for_uivk(WalletNetwork::Regtest, testdata::CHANNEL_UIVK).unwrap();
        let test = channel_id_for_uivk(WalletNetwork::Test, testdata::CHANNEL_UIVK).unwrap();
        let main = channel_id_for_uivk(WalletNetwork::Main, testdata::CHANNEL_UIVK).unwrap();
        assert_ne!(regtest, test);
        assert_ne!(regtest, main);
        assert_ne!(test, main);
    }

    #[test]
    fn a_uivk_that_is_not_bech32m_is_refused() {
        let e = channel_id_for_uivk(WalletNetwork::Regtest, "not a uivk").unwrap_err();
        assert!(e.contains("bech32m"), "{e}");
    }

    /// F18, restated against the scanner's own definition rather than the arithmetic repeated.
    #[test]
    fn the_canonical_height_is_the_last_final_block() {
        assert_eq!(canonical_height(2000, 1000), 2000 - FINALITY_DEPTH);
        // a channel younger than the finality depth is entirely preview, and the bound floors at
        // the block before the birthday rather than underflowing into a reversed range
        assert_eq!(canonical_height(1003, 1000), 999);
        assert_eq!(canonical_height(0, 0), 0);
    }

    /// End-to-end against the recorded devnet channel: the state root and the tree root this
    /// wallet computes locally must equal the ones the indexer published at the same canonical
    /// height. Nothing about that agreement is taken on trust — the fixture carries message
    /// bodies and a verifying key, and every proof in it is verified here.
    #[test]
    fn the_recorded_devnet_channel_replays_to_the_published_roots() {
        let view = testdata::replay_fixture();
        assert_eq!(view.height(), testdata::CANONICAL_HEIGHT);
        assert_eq!(hex::encode(view.state.state_root()), testdata::STATE_ROOT);
        assert_eq!(hex::encode(view.state.tree_root()), testdata::TREE_ROOT);
        assert_eq!(view.state.note_count(), testdata::NOTE_COUNT);
        assert_eq!(view.state.nullifier_count(), testdata::NULLIFIER_COUNT);
        assert_eq!(view.state.anchor_count(), testdata::ANCHOR_COUNT);
    }

    /// **The regression that made this parameter exist.** Closing the last block at the last
    /// message's height instead of at the canonical height leaves anchors that every full
    /// verifier has already pruned, and `state_root` folds the anchor set — so the wallet
    /// reports a root nobody else computes, with every proof verified and no error raised.
    ///
    /// Same messages, two tips: the anchors must collapse to one and the root must change to the
    /// one the indexer publishes for the later height.
    ///
    /// The recording is taken 211 blocks past its last message for exactly this reason: that gap
    /// exceeds `ANCHOR_WINDOW`, and it is the only shape in which the prune is observable. The
    /// devnet was mined 220 empty blocks to create it — recorded where the channel stood, the two
    /// tips below were one block apart and returned the same root, so this test would have been
    /// comparing a state against itself. See `testdata::LAST_MESSAGE_HEIGHT`.
    #[test]
    fn a_quiet_channel_prunes_its_anchors_at_the_canonical_height() {
        // With the recorded carriers, as `testdata::replay_fixture` does: the recording carries a
        // paid ZEC claim, and a blind replay refuses it and orphans every anchor after it — which
        // would make this test about the claim oracle rather than about the anchor prune.
        let at_last_message = replay_using(
            WalletNetwork::Regtest,
            testdata::CHANNEL_UIVK,
            testdata::BIRTHDAY,
            testdata::LAST_MESSAGE_HEIGHT + FINALITY_DEPTH,
            testdata::vk(),
            testdata::messages(),
            &testdata::recorded_carriers,
        )
        .unwrap();
        assert_eq!(at_last_message.height(), testdata::LAST_MESSAGE_HEIGHT);
        // Every anchor still within `ANCHOR_WINDOW` of height 897, which on this channel means
        // every applied transition from height 697 on. `/api/anchors?as_of=897&live=1` reports
        // the same 22, which is the indexer applying the same rule to its own history.
        assert_eq!(at_last_message.state.anchor_count(), 22);
        assert_eq!(
            hex::encode(at_last_message.state.state_root()),
            testdata::STATE_ROOT_AT_LAST_MESSAGE
        );

        // 211 empty blocks later: no new message, same tree, a pruned anchor set and a different
        // state root. An implementation that ignores the tip cannot tell these two apart.
        let later = testdata::replay_fixture();
        assert_eq!(later.height(), testdata::CANONICAL_HEIGHT);
        assert!(
            later.height() - testdata::LAST_MESSAGE_HEIGHT > 200,
            "the gap must exceed ANCHOR_WINDOW or this proves nothing"
        );
        assert_eq!(later.state.anchor_count(), 1);
        assert_eq!(
            later.state.tree_root(),
            at_last_message.state.tree_root(),
            "no message means no new note"
        );
        assert_ne!(later.state.state_root(), at_last_message.state.state_root());
        assert_eq!(hex::encode(later.state.state_root()), testdata::STATE_ROOT);
    }

    /// The preview bound belongs to this side of the seam. A message from a block that can still
    /// reorganise must not enter the state, however eagerly the caller handed it over, and the
    /// count of what was held back must be reported rather than swallowed.
    #[test]
    fn messages_above_the_canonical_height_are_held_back_and_counted() {
        // a tip one block past the last message leaves every message in preview
        let view = replay(
            WalletNetwork::Regtest,
            testdata::CHANNEL_UIVK,
            testdata::BIRTHDAY,
            testdata::LAST_MESSAGE_HEIGHT + 1,
            testdata::vk(),
            testdata::messages(),
            &TxSources::default(),
        )
        .unwrap();
        assert_eq!(
            view.preview_messages, 1,
            "only the last message is above tip − FINALITY_DEPTH"
        );
        assert!(view
            .messages
            .iter()
            .all(|m| m.completion.0 <= view.height()));
        assert_ne!(
            hex::encode(view.state.state_root()),
            testdata::STATE_ROOT_AT_LAST_MESSAGE
        );

        let all_final = testdata::replay_fixture();
        assert_eq!(all_final.preview_messages, 0);
        assert_eq!(all_final.preview_blocks(), FINALITY_DEPTH);
    }

    /// A replay that rejects proofs must not merely produce a different root; it must produce
    /// *nothing*, and say why per message. The fixture's own verifying key is corrupted here,
    /// which is the shape of an indexer serving a key from a different ceremony.
    #[test]
    fn a_wrong_verifying_key_rejects_every_transition_with_a_reason() {
        let mut vk = testdata::vk().to_vec();
        // flip a bit deep inside the key rather than in the first group element, so that it still
        // deserializes as a well-formed key and the failure lands on `verify` rather than on parse
        let last = vk.len() - 8;
        vk[last] ^= 1;
        let view = match replay(
            WalletNetwork::Regtest,
            testdata::CHANNEL_UIVK,
            testdata::BIRTHDAY,
            testdata::CHAIN_TIP,
            &vk,
            testdata::messages(),
            &TxSources::default(),
        ) {
            Ok(v) => v,
            // a mangled key that fails to decompress is an equally acceptable refusal
            Err(e) => {
                assert!(e.contains("verifying key"), "{e}");
                return;
            }
        };
        assert_eq!(
            view.state.note_count(),
            0,
            "no note may enter the tree on an unverified proof"
        );
        assert_ne!(hex::encode(view.state.state_root()), testdata::STATE_ROOT);
        assert!(
            view.outcomes.iter().any(|o| o.reason == "proof rejected"),
            "the rejection must be reported per message, not silently swallowed: {:?}",
            view.outcomes
                .iter()
                .map(|o| o.reason.as_str())
                .collect::<Vec<_>>()
        );
    }

    /// The indexer is an HTTP source; a page stitched back together in the wrong order must not
    /// change what the wallet believes. `replay` restates the canonical order locally, so a
    /// shuffled input reaches the same roots.
    #[test]
    fn a_shuffled_message_list_replays_to_the_same_roots() {
        let mut shuffled = testdata::messages();
        shuffled.reverse();
        // through `replay_using` with the recorded carriers, like `testdata::replay_fixture`: the
        // recording now carries a paid ZEC claim, and a blind replay of it lands on a different
        // root by design, which would make this test about the claim oracle rather than ordering
        let view = replay_using(
            WalletNetwork::Regtest,
            testdata::CHANNEL_UIVK,
            testdata::BIRTHDAY,
            testdata::CHAIN_TIP,
            testdata::vk(),
            shuffled,
            &testdata::recorded_carriers,
        )
        .unwrap();
        assert_eq!(hex::encode(view.state.state_root()), testdata::STATE_ROOT);
        assert_eq!(hex::encode(view.state.tree_root()), testdata::TREE_ROOT);
    }

    /// `ChannelView` holds a `State` and cannot derive `Debug`, so `expect_err` is unavailable.
    fn must_fail(result: Result<ChannelView, String>, why: &str) -> String {
        match result {
            Ok(view) => panic!(
                "{why} — instead it replayed to state_root {}",
                hex::encode(view.state.state_root())
            ),
            Err(e) => e,
        }
    }

    /// The index of the first applied (kind `0x01`) message in the recording, which is the one
    /// worth attacking: an ignored message leaves no trace, so renaming one proves nothing.
    fn first_applied(messages: &[Message]) -> usize {
        let view = testdata::replay_fixture();
        let applied: Vec<[u8; 32]> = view.applied.keys().copied().collect();
        messages
            .iter()
            .position(|m| applied.contains(&m.msg_id))
            .expect("the recording contains applied messages")
    }

    /// **Attack 1, reproduced and refused: renaming a message moves `state_root`.**
    ///
    /// `msg_id` is not covered by the proof and not covered by `tx.sighash`, but `State::apply`
    /// folds it into `applied_hash` inside `state_root`. Before the binding check, giving one
    /// applied message the id `00…00` moved the root from `2adf95cd…` to `85b0349c…` with every
    /// proof still verifying, `applied` still 7 and the balance still 100 — silently destroying
    /// the one cross-verifier check this design rests on.
    ///
    /// The assertion is in two halves on purpose. The first shows the attack is real: feeding
    /// the renamed message straight to the state machine, bypassing `replay`, still produces a
    /// different root with nothing complaining. The second shows `replay` refuses it.
    #[test]
    fn renaming_an_applied_message_is_refused_rather_than_producing_a_second_root() {
        let mut messages = testdata::messages();
        let target = first_applied(&messages);
        let real_id = messages[target].msg_id;
        messages[target].msg_id = [0u8; 32];

        // half one: the rename really does move the root, so this test is not vacuous
        let cid = channel_id_for_uivk(WalletNetwork::Regtest, testdata::CHANNEL_UIVK).unwrap();
        let verifier = Groth16Verifier::from_vk_bytes(testdata::vk()).unwrap();
        let mut state = State::new(
            cid,
            PoseidonHasher,
            testdata::BIRTHDAY,
            JOURNAL_DEPTH as usize,
        );
        let mut sorted = messages.clone();
        sorted.sort_by_key(|m| m.completion);
        let mut open: Option<u32> = None;
        for m in &sorted {
            if open != Some(m.completion.0) {
                state.begin_block(m.completion.0);
                open = Some(m.completion.0);
            }
            state.apply(
                &Delivered {
                    msg_id: m.msg_id,
                    kind: m.kind,
                    completion: m.completion,
                    body: m.body.clone(),
                    fragments: vec![m.completion],
                },
                &verifier,
                &mut nyctis_state::NoZec,
            );
        }
        state.begin_block(testdata::CANONICAL_HEIGHT);
        state.end_block();
        assert_ne!(
            hex::encode(state.state_root()),
            testdata::STATE_ROOT,
            "if a renamed message did not move the root there would be nothing to defend"
        );

        // half two: `replay` refuses it, and says which message and what its body actually hashes
        // to rather than reporting a plausible-looking balance at a root nobody else computes
        let e = must_fail(
            replay(
                WalletNetwork::Regtest,
                testdata::CHANNEL_UIVK,
                testdata::BIRTHDAY,
                testdata::CHAIN_TIP,
                testdata::vk(),
                messages,
                &TxSources::default(),
            ),
            "a message served under an id its body does not produce must not replay",
        );
        assert!(e.contains(&hex::encode([0u8; 32])), "{e}");
        assert!(e.contains(&hex::encode(real_id)), "{e}");
    }

    /// **Attack 2, reproduced and refused: one applied message suppresses another.**
    ///
    /// Give message B the `msg_id` of message A and the state machine's replay-protection set
    /// swallows B — `applied` drops by one, the root changes, and the only trace is a single line
    /// in `ignored_reasons` reading "message already applied". Every message served is still
    /// individually valid and the *set* is complete, so comparing message lists against a second
    /// indexer does not catch it. Only rebinding the id to the body does.
    #[test]
    fn reusing_one_applied_messages_id_for_another_is_refused_rather_than_suppressing_it() {
        let mut messages = testdata::messages();
        let view = testdata::replay_fixture();
        let applied: Vec<[u8; 32]> = view.applied.keys().copied().collect();
        assert!(applied.len() >= 2, "need two applied messages to collide");
        let victim = messages
            .iter()
            .rposition(|m| applied.contains(&m.msg_id))
            .unwrap();
        let donor = messages
            .iter()
            .position(|m| applied.contains(&m.msg_id) && m.msg_id != messages[victim].msg_id)
            .unwrap();
        messages[victim].msg_id = messages[donor].msg_id;

        let e = must_fail(
            replay(
                WalletNetwork::Regtest,
                testdata::CHANNEL_UIVK,
                testdata::BIRTHDAY,
                testdata::CHAIN_TIP,
                testdata::vk(),
                messages,
                &TxSources::default(),
            ),
            "a duplicated id must fail the call, not be absorbed as 'already applied'",
        );
        assert!(
            !e.contains("already applied"),
            "the failure must name the binding, not the symptom: {e}"
        );
        assert!(e.contains("does not produce"), "{e}");
    }

    /// The other two components the id commits to. `kind` and `count` are hashed into `msg_id`
    /// alongside the body, so neither can be restated by the source either — `count` is the one
    /// the wire format cannot otherwise check, because this wallet never sees the memos.
    #[test]
    fn the_kind_and_the_fragment_count_are_bound_too() {
        for mutate in [
            (|m: &mut Message| m.kind = m.kind.wrapping_add(1)) as fn(&mut Message),
            |m: &mut Message| m.count = m.count.wrapping_add(1),
            |m: &mut Message| m.body[0] ^= 0x01,
        ] {
            let mut messages = testdata::messages();
            let target = first_applied(&messages);
            mutate(&mut messages[target]);
            assert!(
                replay(
                    WalletNetwork::Regtest,
                    testdata::CHANNEL_UIVK,
                    testdata::BIRTHDAY,
                    testdata::CHAIN_TIP,
                    testdata::vk(),
                    messages,
                    &TxSources::default(),
                )
                .is_err(),
                "every component of msg_id must be bound"
            );
        }
    }

    // ---- ZEC claims: the busy devnet recording -------------------------------------------

    /// **The acceptance test.** The live devnet channel, 26 messages, two of them carrying a ZEC
    /// claim — and this wallet must land on the two roots the indexer publishes and accept the
    /// same 20 messages.
    ///
    /// Before the oracle existed this replay accepted **11** of the 25 the indexer accepted on the
    /// recording this one replaced. The arithmetic of the gap is the
    /// whole argument for why a refused claim is not a cosmetic shortfall: one applied
    /// claim-carrying transition creates notes *and an anchor*, so refusing it took out 9 later
    /// messages with "unknown anchor" and 4 more with "note: position N does not exist". 1 + 9 +
    /// 4 = 14, and 25 − 14 = 11 exactly. A wallet that cannot check a claim does not merely miss
    /// the fill; it silently forks from every other verifier at that block.
    #[test]
    fn the_busy_devnet_channel_reaches_the_indexers_roots_and_counts() {
        let view = claims::replay_fixture();
        assert_eq!(view.height(), claims::CANONICAL_HEIGHT);
        assert_eq!(hex::encode(view.state.state_root()), claims::STATE_ROOT);
        assert_eq!(hex::encode(view.state.tree_root()), claims::TREE_ROOT);
        assert_eq!(view.accepted(), claims::ACCEPTED);
        assert_eq!(view.ignored(), claims::IGNORED);
        assert_eq!(
            view.zec_unverifiable(),
            0,
            "with both carrying transactions in hand nothing is left unchecked"
        );
    }

    /// Message for message, not just at the end. An agreement on the final root alone would not
    /// catch a message accepted here and rejected there whose effects happened to cancel — and
    /// since `nyctis::zec` is a *port* of the scanner's `PaidClaims` rather than a call into
    /// it, per-message agreement is the only evidence that the port is faithful.
    #[test]
    fn every_message_of_the_busy_channel_gets_the_reference_verdict() {
        let view = claims::replay_fixture();
        let recorded = claims::recorded_outcomes();
        assert_eq!(view.outcomes.len(), claims::MESSAGE_COUNT);
        assert_eq!(view.outcomes.len(), recorded.len());
        for (got, (outcome, reason)) in view.outcomes.iter().zip(recorded) {
            assert_eq!(
                got.accepted,
                outcome != "ignored",
                "{} recorded as {outcome}, got {:?}",
                hex::encode(got.msg_id),
                got.reason
            );
            if let Some(reason) = reason {
                assert_eq!(got.reason, reason, "message {}", hex::encode(got.msg_id));
            }
        }
    }

    /// The two claims are the same amount to the same account eleven blocks apart, and only one
    /// of them was paid. **Both used to be refused**; a wallet that refuses the paid one cannot
    /// see an order fill, and a wallet that accepted the unpaid one would be crediting money
    /// nobody sent.
    #[test]
    fn the_paid_claim_is_applied_and_the_unpaid_one_is_not() {
        let view = claims::replay_fixture();
        let by_height: BTreeMap<u32, &MessageOutcome> = view
            .messages
            .iter()
            .zip(view.outcomes.iter())
            .map(|(m, o)| (m.completion.0, o))
            .collect();

        let paid = by_height[&claims::PAID_CLAIM_HEIGHT];
        assert!(paid.accepted, "the paid claim: {}", paid.reason);

        let unpaid = by_height[&claims::UNPAID_CLAIM_HEIGHT];
        assert!(!unpaid.accepted);
        assert!(
            unpaid
                .reason
                .contains(&format!("ZEC claim of {} zatoshi", claims::CLAIM_ZATOSHI)),
            "{}",
            unpaid.reason
        );
        assert!(
            !unpaid.zec_unverifiable,
            "this one was checked and found unpaid, not left unchecked: {}",
            unpaid.reason
        );
    }

    /// **The fail-closed test, and the one that pins the failure mode.** With no wallet database
    /// and no lightwalletd there is nothing to check a claim against, so both claims are refused
    /// — the pre-oracle behaviour — but the reason now says *why*, and says it differently from
    /// the message that was genuinely unpaid.
    ///
    /// The distinction is the point. Both refusals reach `State::apply` as the same `false` and
    /// come back as the same sentence; a wallet that stopped there would tell a user the network
    /// rejected their fill when in fact the wallet never looked. And the alternative failure —
    /// reading "I could not look" as "paid" — is the one this whole cut exists to prevent, so the
    /// accepted count must fall, not hold.
    #[test]
    fn a_claim_whose_transaction_cannot_be_fetched_is_refused_with_a_different_reason() {
        let blind = claims::replay_blind();
        let checked = claims::replay_fixture();

        assert!(
            blind.accepted() < checked.accepted(),
            "fail closed: blind must accept fewer, not the same"
        );
        assert_eq!(
            blind.zec_unverifiable(),
            2,
            "both claim-carrying messages are unchecked, not merely unpaid"
        );

        let unverifiable: Vec<&MessageOutcome> =
            blind.outcomes.iter().filter(|o| o.zec_unverifiable).collect();
        for o in &unverifiable {
            assert!(!o.accepted);
            assert!(
                o.reason.contains("could not be checked"),
                "the reason must not read as a verdict: {}",
                o.reason
            );
            assert!(
                o.reason.contains("no Zcash transaction source"),
                "and it must name what is missing: {}",
                o.reason
            );
        }

        // The genuinely unpaid message says the opposite thing when it *is* checked, so the two
        // sentences can never be confused for one another.
        let unpaid = checked
            .messages
            .iter()
            .zip(checked.outcomes.iter())
            .find(|(m, _)| m.completion.0 == claims::UNPAID_CLAIM_HEIGHT)
            .map(|(_, o)| o)
            .unwrap();
        assert!(!unpaid.reason.contains("could not be checked"), "{}", unpaid.reason);
    }

    /// A blind replay must also *diverge* from the published root rather than quietly landing on
    /// it: if it did not, the claim would not have mattered and this whole module would be
    /// unnecessary. This is the state the wallet was in before the fix, stated as a test so
    /// nobody mistakes the fail-closed path for a working one.
    #[test]
    fn a_blind_replay_does_not_reach_the_published_root() {
        let blind = claims::replay_blind();
        assert_ne!(hex::encode(blind.state.state_root()), claims::STATE_ROOT);
        assert_ne!(hex::encode(blind.state.tree_root()), claims::TREE_ROOT);
    }

    /// A preview message is checked too, even though it is dropped: the caller hands it over
    /// from the same source as the rest, and meeting the failure only once the block goes final
    /// would mean meeting it after a balance had already been shown.
    #[test]
    fn a_preview_messages_id_is_bound_as_well() {
        let mut messages = testdata::messages();
        let last = messages.len() - 1;
        messages[last].msg_id = [0xAA; 32];
        let e = must_fail(
            replay(
                WalletNetwork::Regtest,
                testdata::CHANNEL_UIVK,
                testdata::BIRTHDAY,
                // a tip that leaves the last message above the canonical height
                testdata::LAST_MESSAGE_HEIGHT + 1,
                testdata::vk(),
                messages,
                &TxSources::default(),
            ),
            "a preview message is still checked",
        );
        assert!(e.contains(&hex::encode([0xAA; 32])), "{e}");
    }

    /// **The record a wallet reads its own history out of.** The state machine keeps nullifiers
    /// in a set, so after the replay "is this note spent" is answerable and "by which message"
    /// is not — unless it was written down while the outcome that carried both was in hand.
    /// These two maps are that record, and this pins them to the state they were built beside:
    /// every nullifier the channel holds names an applied message, that message agrees it
    /// consumed it, and the height is the one the message completed at.
    #[test]
    fn every_nullifier_names_the_message_that_published_it() {
        let view = testdata::replay_fixture();
        assert_eq!(view.spent_by.len(), testdata::NULLIFIER_COUNT);
        assert_eq!(
            view.spent_by.len(),
            view.state.nullifier_count(),
            "a nullifier without a spender would be a note whose disappearance the wallet can              see and cannot explain"
        );
        assert_eq!(
            view.consumed.values().map(Vec::len).sum::<usize>(),
            view.spent_by.len(),
            "the two maps are one record read two ways, not two records that could disagree"
        );

        for (nf, by) in &view.spent_by {
            assert!(view.state.has_nullifier(nf));
            assert!(
                view.applied.contains_key(&by.msg_id),
                "only an applied message can spend"
            );
            assert!(view.consumed[&by.msg_id].contains(nf));
            let msg = view
                .messages
                .iter()
                .find(|m| m.msg_id == by.msg_id)
                .expect("the spender is one of the replayed messages");
            assert_eq!(by.height, msg.completion.0);
        }

        // an issuance consumes nothing and appends one note; a payment with change consumes one
        // and appends two. Both shapes are in the recording and both are read off these maps.
        let issuance: [u8; 32] = hex::decode(testdata::ISSUANCE_MSG)
            .unwrap()
            .try_into()
            .unwrap();
        let payment: [u8; 32] = hex::decode(testdata::FIRST_SEND_MSG)
            .unwrap()
            .try_into()
            .unwrap();
        assert!(view.consumed[&issuance].is_empty());
        assert_eq!(view.applied[&issuance].len(), 1);
        assert_eq!(view.consumed[&payment].len(), 1);
        assert_eq!(view.applied[&payment].len(), 2);
    }

    /// The recording replays unchanged, so the binding check is not simply refusing everything.
    /// (The roots are asserted by `the_recorded_devnet_channel_replays_to_the_published_roots`;
    /// this pins the `vk_hash` that reaches the caller beside them.)
    #[test]
    fn the_view_reports_the_hash_of_the_key_it_verified_against() {
        let view = testdata::replay_fixture();
        assert_eq!(hex::encode(view.vk_hash), testdata::VK_HASH);
        assert_eq!(
            hex::encode(view.vk_hash),
            hex::encode(nyctis_zk::prover::vk_hash_bytes(testdata::vk())),
        );
    }

    /// The scanner is handed `[birthday, canonical]` and never offers the state machine a block
    /// below the birthday. A message claiming one is a location no reference verifier replays,
    /// so it is refused rather than dropped — a silent drop is exactly the withholding this cut
    /// cannot otherwise detect.
    #[test]
    fn a_message_below_the_channel_birthday_is_refused() {
        let messages = testdata::messages();
        let birthday = messages.iter().map(|m| m.completion.0).min().unwrap() + 1;
        let e = must_fail(
            replay(
                WalletNetwork::Regtest,
                testdata::CHANNEL_UIVK,
                birthday,
                testdata::CHAIN_TIP,
                testdata::vk(),
                messages,
                &TxSources::default(),
            ),
            "a message below the birthday is outside the replayed range",
        );
        assert!(e.contains("below the channel birthday"), "{e}");
    }
}

