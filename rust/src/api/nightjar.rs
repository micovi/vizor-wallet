//! FRB surface for Nightjar (`docs/NIGHTJAR-POC.md`).
//!
//! Flat structs, primitives and `Vec<u8>` only, per the API design constraint in `AGENTS.md`;
//! every Nightjar type stays on the `crate::nightjar` side of this seam. Money crosses as `u64`
//! zatoshi-style integer units and is never converted to or from a float anywhere on this path —
//! a Nightjar asset's `decimals` is a display hint the UI applies, not an arithmetic one.
//!
//! The Dart caller supplies the raw material: the channel's published UIVK, the channel
//! birthday, the chain tip, the compressed Groth16 verifying key from `/api/vk`, and the
//! messages from `/api/messages?body=1`. **Nothing about that material is trusted beyond
//! availability.** The proofs are verified here, the state is recomputed here, and the finality
//! bound is applied here rather than by the caller.

use std::panic;

use crate::nightjar::carrier::TxSources;
use crate::nightjar::network::parse_network;
use crate::nightjar::owned::{asset_summaries, owned_notes};
use crate::nightjar::pay;
use crate::nightjar::replay::{self, Message};

/// The panic guard every FRB entry point in this crate wraps its body in (the same shape as
/// `api/secret.rs`, `api/sync.rs` and `api/wallet.rs`). A panic unwinding across the FFI boundary
/// is undefined behaviour, and this module calls into upstream code that asserts on inputs — most
/// pointedly `SpendAuthority::from_seed`, which panics rather than returning on a key label it
/// does not recognise.
fn catch<T>(f: impl FnOnce() -> Result<T, String> + panic::UnwindSafe) -> Result<T, String> {
    match panic::catch_unwind(f) {
        Ok(result) => result,
        Err(e) => {
            let msg = if let Some(s) = e.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = e.downcast_ref::<String>() {
                s.clone()
            } else {
                "Unknown panic".to_string()
            };
            Err(format!("Rust panic: {msg}"))
        }
    }
}

/// The Nightjar identity a wallet seed carries: what to show on a receive screen.
pub struct NjIdentity {
    /// Bech32m, prefixed `nj` / `njtest` / `njreg` by network.
    pub address: String,
    pub ak: String,
    pub nkc: String,
}

/// One reassembled message as `/api/messages?body=1` reports it.
///
/// None of it is believed. `msg_id` is recomputed from `kind`, `fragments` and `body` under the
/// channel id and must match, which is what makes the other fields safe to act on.
pub struct NjMessageInput {
    /// Lowercase hex, 32 bytes.
    pub msg_id: String,
    pub kind: u8,
    /// Completion location. A message above `tip − 10` is preview and is dropped by the replay;
    /// the caller may hand it over anyway and read `preview_messages` back. A message *below* the
    /// channel birthday is refused outright — no reference verifier replays that block.
    pub height: u32,
    pub tx_index: u32,
    pub action_index: u32,
    /// The indexer's `fragments`: how many memo fragments carried this body.
    ///
    /// Required, and required to be right, because it is hashed into `msg_id` along with `kind`
    /// and `body`. Pass the field verbatim; do not reconstruct it from `body.length`.
    pub fragments: u16,
    /// The indexer's `txid` for the Zcash transaction that completed this message, lowercase hex
    /// in display order. Empty is allowed and means "not supplied".
    ///
    /// **A fetch key, not evidence.** Nothing in the protocol binds a txid to a `msg_id`, so a
    /// wrong or hostile value cannot make a claim pass: the transaction it names is fetched and
    /// then has to be shown to carry *this* message's own fragments under the channel key before
    /// anything is read out of it. What an absent or wrong txid costs is a ZEC claim refused for
    /// want of evidence — visible in `ignored_reasons`, never silently treated as paid.
    pub txid: String,
    pub body: Vec<u8>,
}

/// Where the replay may look for the Zcash transaction behind a ZEC claim (an order fill).
///
/// Both are optional and an empty string means "not available", which is an ordinary state — a
/// wallet that has not synced has no lightwalletd, and a locked one has no database path. The
/// consequence of handing over neither is not a wrong answer but a *refused* one: claims are
/// reported unchecked and the view says so.
///
/// The Nightjar indexer is deliberately absent from this struct. It is the thing that supplied
/// the message; it is not also allowed to supply the evidence about the message.
pub struct NjZecSources {
    /// Path to this wallet's own `zakura-client-sqlite` database. Tried first: the wallet scans
    /// every block, so a transaction it was a party to costs one local read and no network.
    pub db_path: String,
    /// The lightwalletd this wallet syncs against — `GetTransaction` for the transactions it does
    /// not hold, which on a public channel is most of them.
    pub lightwalletd_url: String,
}

/// A note this wallet owns **or has owned**, with the message that created it and, when it is
/// gone, the message that spent it.
///
/// Spent notes are in this list. They have to be: after a payment the only note of it still in
/// the wallet is the change, and a list of unspent notes alone renders that change as an
/// arrival. The provenance is what a caller groups by to get the payment back —
/// see [`nightjar_replay`] for what is and is not decidable from it.
pub struct NjNote {
    pub position: u64,
    /// The height the note was created at, which is the completion height of `created_by`.
    pub created: u32,
    pub asset_id: String,
    /// Integer units of the asset. Apply `NjAsset::decimals` for display only.
    pub amount: u64,
    /// The spend policy in its text form, e.g. `pk(<ak>)`. Being able to nullify a note is not
    /// the same as being able to open it today: a timelocked note is listed and is not
    /// spendable, which the policy text is what tells the user.
    pub policy: String,
    /// `ciphertext`, `published` or `recovered` — how the note reached its owner.
    pub source: String,
    /// False while the note is still this wallet's to spend. True means the channel holds its
    /// nullifier, and `NjAsset::balance` does not count it. This is the field to branch on: it
    /// is read from the channel's own nullifier set, the same set a spend of this note would be
    /// checked against.
    pub spent: bool,
    /// Lowercase hex `msg_id` of the message that appended this note to the tree. Notes sharing
    /// it were created by one transition.
    ///
    /// For a `published` note this is still the transition that created the note, not the `NOTE`
    /// message that disclosed it — that message moved no money and grouping a receipt under it
    /// would date the receipt wrongly.
    pub created_by: String,
    /// How many notes `created_by` consumed and appended **in total**, this wallet's and other
    /// people's alike. `0` inputs is an issuance. The circuit's arity is `MAX_IN` 2 and
    /// `MAX_OUT` 3, so a message can pay a recipient, return change and still carry a third
    /// output.
    ///
    /// These are what say whether the notes in hand are the whole message. A wallet cannot
    /// decrypt an output addressed to somebody else, so an output it does not hold is not a zero
    /// — it is an amount nobody on this side can name. A caller that owns fewer than `outputs`
    /// of a message's outputs must not present the difference as a number.
    pub created_inputs: u32,
    pub created_outputs: u32,
    /// Lowercase hex `msg_id` of the message that nullified this note, `None` while unspent.
    /// Every note this wallet spent names the message that spent it: the replay records the
    /// nullifiers of each applied message, so "spent" and "spent by whom" arrive together.
    pub spent_by: Option<String>,
    /// The height that message completed at — when the money left.
    pub spent_height: Option<u32>,
    /// The same two counts for `spent_by`. `spent_inputs` is the one an authorship test needs:
    /// the wallet authored the payment only if it owned *every* input, and owning one of two is
    /// a co-signed transition, not a send.
    pub spent_inputs: Option<u32>,
    pub spent_outputs: Option<u32>,
}

/// An asset on the channel, joined with this wallet's balance of it.
pub struct NjAsset {
    pub asset_id: String,
    /// The collection the issuing transition named, or **empty when not disclosed** — same
    /// reason as `max_supply` below. It is never an all-zero hash: that is a collection id like
    /// any other and saying it here would be a claim, not an absence.
    pub collection_id: String,
    /// Position inside `collection_id`, or `None` when no applied *public* issuance disclosed
    /// one — the same absence `collection_id` reports as empty.
    ///
    /// It comes from the issuing transition's `terms`, which is hashed into `asset_id`, so it is
    /// a fact about the chain rather than a label anyone chose. A collection's metadata document
    /// resolves `item.image`'s `{index}` with it (`spec/asset-collection-v0.md` section 3.2), and
    /// that substitution is safe *only* because of that binding — which is why this crosses the
    /// FFI at all instead of the document's own idea of an index being trusted on the Dart side.
    pub index: Option<u32>,
    /// True when an applied *public* issuance put this asset's supply on the channel. False is
    /// the privately issued case: the asset is listed because this wallet holds a note of it,
    /// and `issued`, `collection_id` and `max_supply` are all undisclosed rather than zero.
    pub public: bool,
    /// Empty when no `ASSET` message has named the asset; unnamed is not invalid.
    pub name: String,
    pub symbol: String,
    /// A display hint only. No arithmetic on this path applies it.
    pub decimals: u8,
    pub uri: String,
    /// Outstanding public supply. Meaningless unless `public`: a private issuance publishes no
    /// amount, and `0` there means "the channel does not know", not "none exists".
    pub issued: u64,
    /// The supply cap the issuing transition declared, where `Some(0)` means uncapped, as on the
    /// wire.
    ///
    /// `None` is **not disclosed**, and it is the normal case for a privately issued asset: the
    /// cap lives in the body of the issuing message, and a private issuance publishes no such
    /// body for the channel to read. Reporting `0` there would say "uncapped" about an asset
    /// whose cap nobody on this channel can see.
    pub max_supply: Option<u64>,
    /// What this wallet holds **now**, in integer units: spent notes are not counted, however
    /// much of the history `notes` carries. This number did not change when spent notes joined
    /// that list, and a caller summing `notes` itself must filter on `NjNote::spent` to agree
    /// with it.
    pub balance: u64,
    /// How many **unspent** notes make up `balance`. It is not `notes.length` for this asset.
    pub note_count: u32,
}

/// The whole verified view of a channel at one height.
pub struct NjView {
    /// The canonical height this view was closed at: `tip − 10`, never above it. Every number
    /// below is only meaningful here.
    pub height: u32,
    /// The chain tip the view was built against. Report it; do not build against it.
    pub chain_tip: u32,
    pub state_root: String,
    pub tree_root: String,
    /// `BLAKE2b-256` of the compressed verifying key every proof was checked against, lowercase
    /// hex.
    ///
    /// Compare it with `/api/status`'s `info.vk_hash`. Fetching key and hash from the same server
    /// pins nothing by itself — the value is worth something against a *second* source, or
    /// against one the user holds out of band — but without it on this struct no caller could
    /// pin anything at all, which is what this field exists to fix.
    pub vk_hash: String,
    /// Messages the state machine accepted (applied, published or named).
    pub applied: u32,
    /// Messages it refused, with `ignored_reasons` saying why. Non-zero is normal on a public
    /// channel: anyone may write to it, including with junk.
    pub ignored: u32,
    /// One line per ignored message, `<msg_id> <reason>`, in application order. The reasons are
    /// the state machine's own; they are the only thing that distinguishes "this channel carries
    /// spam" from "this wallet is verifying against the wrong key".
    pub ignored_reasons: Vec<String>,
    /// How many of `ignored` were refused because a ZEC claim could not be **checked** rather
    /// than because it was checked and found unpaid.
    ///
    /// Non-zero says this view is knowingly incomplete: the wallet could not reach a Zcash
    /// transaction it needed (no lightwalletd, an unsynced wallet, a server that does not have
    /// it), so an order fill the rest of the channel applied is missing here — and `state_root`
    /// is *expected* to differ from the indexer's as a result. A UI that shows a root mismatch
    /// without showing this turns a fixable configuration problem into what looks like a
    /// dishonest indexer. The matching `ignored_reasons` line ends in "could not be checked: …".
    pub zec_unverifiable: u32,
    /// Messages held back because they sit in blocks that can still reorganise. Non-zero means a
    /// payment is on its way and the balance below is about to change.
    pub preview_messages: u32,
    /// Every note this wallet has ever owned here, unspent and spent alike, ascending by tree
    /// position. See [`nightjar_replay`] for what a caller can and cannot reconstruct from it.
    pub notes: Vec<NjNote>,
    pub assets: Vec<NjAsset>,
}

/// The Nightjar address, `ak` and `nkc` for `seed` on `network`.
///
/// The Nightjar derivation is not ZIP 32 and takes no account index, so all of this wallet's
/// accounts on one seed share one Nightjar identity.
pub fn nightjar_identity(seed: Vec<u8>, network: String) -> Result<NjIdentity, String> {
    catch(|| {
        let network = parse_network(&network)?;
        let id = crate::nightjar::keys::identity(&seed, network)?;
        Ok(NjIdentity {
            address: id.address,
            ak: hex::encode(id.ak),
            nkc: hex::encode(id.nkc),
        })
    })
}

/// The `channel_id` a published UIVK names on `network`, as lowercase hex.
///
/// Useful on its own: it is what a caller checks the indexer's `/api/status` against before
/// believing a single message it serves, because an indexer pointed at another channel would
/// otherwise answer every query perfectly and about the wrong thing.
pub fn nightjar_channel_id(network: String, channel_uivk: String) -> Result<String, String> {
    catch(|| {
        let network = parse_network(&network)?;
        Ok(hex::encode(replay::channel_id_for_uivk(
            network,
            &channel_uivk,
        )?))
    })
}

/// The canonical (final) height at `chain_tip` for a channel with this birthday: `tip − 10`,
/// floored at the block before the birthday.
///
/// Exposed so the UI can say "n blocks until this is final" with the same arithmetic the replay
/// uses, rather than a second copy of the constant in Dart that could drift from it.
pub fn nightjar_canonical_height(chain_tip: u32, birthday: u32) -> Result<u32, String> {
    catch(|| Ok(replay::canonical_height(chain_tip, birthday)))
}

/// Replay a channel and report what `seed` owns in it.
///
/// Every Groth16 proof in `messages` is verified against `vk`, every signature is checked, and
/// the commitment tree, nullifier set and asset registry are rebuilt from scratch. The resulting
/// `state_root` is directly comparable with the one any other verifier publishes for the same
/// height — comparing them is how a caller detects an indexer that withheld a message, which is
/// the one thing this cut cannot prevent. That comparison is only worth making because every
/// `msg_id` is recomputed from its own body first: `msg_id` is folded into `state_root` and is
/// covered by no proof, so an id taken on the source's word let the source pick the root. A
/// message whose id its body does not produce fails this call outright.
///
/// `vk_hash` on the result is the hash of the key the proofs were checked against, for a caller
/// that wants to pin it against `/api/status` or against a second source.
///
/// `chain_tip` decides the height the view is closed at, so it must be a real chain tip and not
/// the highest message height: the anchor set is pruned as a function of that height and is
/// folded into `state_root`, so a channel that has been quiet for more than 200 blocks produces
/// a different root at its last message than at the tip. Prefer the tip this wallet's own
/// lightwalletd sync reports over the indexer's.
///
/// ZEC-claim messages (order fills) are **not** verified: checking one needs the carrying Zcash
/// transaction, which this path never sees, so they are ignored with a reason rather than
/// treated as having passed. An order fill will not show up in `notes`.
///
/// # Reading the history back out of `notes`
///
/// `notes` is every note this wallet has ever owned on the channel, spent ones included and
/// marked, each naming the message that created it and the message that spent it. Group by
/// `msg_id` and one message's worth of this wallet's side of a transition is in hand. What that
/// supports, and what it does not:
///
/// - **A payment this wallet authored.** Every note with `spent_by == M` is an input it owned.
///   If that count equals `spent_inputs`, this wallet owned *all* of `M`'s inputs and therefore
///   signed it. What left is `sum(inputs) − sum(outputs owned)`, where the outputs owned are the
///   notes with `created_by == M`; the rest of that sum is change and must not be shown as a
///   receipt.
/// - **A receipt.** No note has `spent_by == M`, and some note has `created_by == M`. The amount
///   received is the sum of those notes.
/// - **A transition this wallet only partly funded** — it owns some but not `spent_inputs` of
///   the inputs. A `buy` or a `fill` is exactly this: maker's note and taker's note in one
///   transition, neither party alone the author. `sum(inputs owned) − sum(outputs owned)` is
///   this wallet's net change in that message and is meaningful; calling it "sent" is not.
///   Compare the two counts before choosing a verb.
/// - **What cannot be decided at all**: how much went to whom. When a message owns more outputs
///   than this wallet holds (`created_outputs` exceeds the number of notes naming it), the
///   remainder is addressed to keys this wallet has not got and its amounts are not small or
///   zero — they are unknowable from this data. A recipient address is likewise nowhere in this
///   struct: it is inside a ciphertext only the recipient can open. "Paid *someone* this much"
///   is derivable; "paid this address" is not.
///
/// Four further shapes are worth naming because they read like something they are not:
///
/// - **paying yourself**, which is legal and is what consolidating two notes into one looks
///   like. Every output is this wallet's, so `sum(inputs) − sum(outputs owned)` is zero and the
///   arithmetic above calls it a payment of nothing. It is one; the money did not leave. There
///   is no field that distinguishes it from a payment to a stranger that happened to have no
///   recipient, because there is no such payment — a zero difference *is* the self-payment case.
/// - **a `recovered` note** (a covenant payout or a remainder) arrives in a transition this
///   wallet very likely did not sign, so the rule above files it as a receipt, which it is.
/// - **a `published` note** is dated by its creating transition, not by the `NOTE` message that
///   disclosed it, so it can appear in the history at a height well before this wallet could
///   have learnt of it.
/// - **a payment this wallet has just made is not here at all.** The view is closed at
///   `tip − 10`, so for those ten blocks neither the spend nor its change exists: the input
///   still counts as unspent and the balance is the old one. `preview_messages` is the only
///   signal that this is happening, and a send screen that does not say so will look like it
///   lost the money and then made it reappear.
pub fn nightjar_replay(
    network: String,
    channel_uivk: String,
    birthday: u32,
    chain_tip: u32,
    vk: Vec<u8>,
    messages: Vec<NjMessageInput>,
    seed: Vec<u8>,
    zec_sources: NjZecSources,
) -> Result<NjView, String> {
    catch(move || {
        let network = parse_network(&network)?;
        let messages = messages
            .iter()
            .map(decode_message)
            .collect::<Result<Vec<_>, String>>()?;
        let view = replay::replay(
            network,
            &channel_uivk,
            birthday,
            chain_tip,
            &vk,
            messages,
            &zec_sources.to_sources(),
        )?;

        let account = crate::nightjar::keys::account(&seed);
        let owned = owned_notes(&view, &account);
        let assets = asset_summaries(&view, &owned);

        Ok(NjView {
            height: view.height(),
            chain_tip: view.chain_tip,
            state_root: hex::encode(view.state.state_root()),
            tree_root: hex::encode(view.state.tree_root()),
            vk_hash: hex::encode(view.vk_hash),
            applied: view.accepted(),
            ignored: view.ignored(),
            ignored_reasons: view
                .outcomes
                .iter()
                .filter(|o| !o.accepted)
                .map(|o| format!("{} {}", hex::encode(o.msg_id), o.reason))
                .collect(),
            zec_unverifiable: view.zec_unverifiable(),
            preview_messages: view.preview_messages,
            notes: owned
                .into_iter()
                .map(|n| NjNote {
                    position: n.position,
                    created: n.created,
                    asset_id: hex::encode(n.asset_id),
                    amount: n.amount,
                    policy: n.policy,
                    source: n.source.as_str().to_string(),
                    // `spent` is the channel's own nullifier set and is the field to branch on;
                    // the four below name the message that did it. They agree on every view this
                    // replay produces, and where they could not, `spent` is the one that is
                    // safe to be wrong in only one direction.
                    spent: n.spent,
                    created_by: hex::encode(n.created_by.msg_id),
                    created_inputs: n.created_by.inputs,
                    created_outputs: n.created_by.outputs,
                    spent_by: n.spent_by.map(|s| hex::encode(s.msg_id)),
                    spent_height: n.spent_by.map(|s| s.height),
                    spent_inputs: n.spent_by.map(|s| s.inputs),
                    spent_outputs: n.spent_by.map(|s| s.outputs),
                })
                .collect(),
            assets: assets
                .into_iter()
                .map(|a| NjAsset {
                    asset_id: hex::encode(a.asset_id),
                    collection_id: a.collection_id.map(hex::encode).unwrap_or_default(),
                    index: a.index,
                    public: a.public,
                    name: a.name,
                    symbol: a.symbol,
                    decimals: a.decimals,
                    uri: a.uri,
                    issued: a.issued,
                    max_supply: a.max_supply,
                    balance: a.balance,
                    note_count: a.note_count,
                })
                .collect(),
        })
    })
}

/// What a settings screen needs to know about a proving-key folder.
///
/// Nightjar's verifying key is 1 784 bytes and arrives over HTTP; its **proving** key is ~83 MiB
/// and arrives from nowhere — nothing serves it and nothing should. This PoC therefore takes a
/// folder path from settings, and this struct is what lets that screen say "sending is
/// unavailable, and here is why" instead of failing at the moment a user presses Send.
pub struct NjProvingKey {
    /// The folder, as resolved.
    pub dir: String,
    /// The circuit fingerprint, e.g. `constraints=136119;instances=30`. A diagnostic: it says
    /// which circuit shape the keys were made for, not whose ceremony made them.
    pub circuit: String,
    /// `BLAKE2b-256` of the verifying key beside the proving key, lowercase hex.
    ///
    /// **Compare it with `NjView.vk_hash`.** Two key sets can share a `circuit` string and be
    /// mutually unusable; a payment proved under the wrong one is rejected by every verifier on
    /// the channel *after* the user has paid the Zcash fee to carry it. `nightjar_build_pay`
    /// refuses that case itself, and this field is how a settings screen can refuse it earlier
    /// and more calmly.
    pub vk_hash: String,
    /// Size of `interpreter-v0.pk` in bytes.
    pub proving_key_bytes: u64,
}

/// A payment, proven and framed, waiting for the transport.
///
/// Nothing in it has been broadcast. See [`nightjar_build_pay`].
pub struct NjPayPlan {
    /// Lowercase hex. The id the channel will know this message by, computed from the body — not
    /// chosen. The read path recomputes it and refuses a mismatch, so a plan that did not
    /// satisfy that rule would be unspendable on arrival.
    pub msg_id: String,
    pub asset_id: String,
    /// The `ASSET` message's symbol, empty when nobody has named this asset.
    pub asset_symbol: String,
    /// Display hint only; no arithmetic on this path applies it.
    pub asset_decimals: u8,
    /// Integer base units to the recipient.
    pub amount: u64,
    /// Integer base units back to this wallet. `0` means the selected notes covered the amount
    /// exactly and the transition has a single output.
    pub change: u64,
    /// `amount + change`: what the consumed notes were worth.
    pub spent: u64,
    /// How many of this wallet's notes this payment nullifies. At most 2 — the circuit's input
    /// arity.
    pub inputs: u32,
    /// The memo fragments, **each exactly 512 bytes**, in order. There are 1-8 of them and they
    /// must all ride one transaction: a reader reassembles a message only from fragments sharing
    /// a txid.
    pub memos: Vec<Vec<u8>>,
    /// Zatoshi to attach to **each** memo output. A Nightjar memo rides an ordinary shielded
    /// output to the channel address, and an output with no value is dust the proposer drops.
    /// Total ZEC cost is this times `memos.length`, plus the Zcash fee, and it is paid to the
    /// channel — not to the Nightjar recipient.
    pub memo_value_zatoshi: u64,
    /// Encoded transition body, before framing.
    pub body_bytes: u32,
    /// The canonical height (`tip − 10`) this plan is anchored at. The anchor ages out of the
    /// channel's anchor window, so a plan is good for roughly that window and not forever.
    pub anchor_height: u32,
    pub chain_tip: u32,
    /// Hash of the verifying key this proof will be checked against: the channel's, which the
    /// key folder had to match before anything was proved.
    pub vk_hash: String,
    /// Wall-clock milliseconds spent proving. ~1 300 on a laptop; more on a phone.
    pub proved_ms: u32,
}

/// Validate a Nightjar proving-key folder and report what is in it.
///
/// Reads the 1.8 KiB verifying key and the one-line sidecar manifest and `stat`s the 83 MiB
/// proving key — it does not load it, so this is cheap enough to run whenever a settings screen
/// opens. Every error is a sentence meant to be shown verbatim.
///
/// Call it before offering to send. The alternative is discovering a wrong or missing key after
/// a replay and a review screen, at the one moment the user has already decided to pay.
pub fn nightjar_check_proving_key(keys_dir: String) -> Result<NjProvingKey, String> {
    catch(move || {
        let info = pay::check_proving_key(&keys_dir)?;
        Ok(NjProvingKey {
            dir: info.dir,
            circuit: info.circuit,
            vk_hash: hex::encode(info.vk_hash),
            proving_key_bytes: info.proving_key_bytes,
        })
    })
}

/// Turn "pay `amount` base units of `asset_id` to `recipient`" into the memos that carry it.
///
/// **This function does not broadcast, and it does not touch the network.** It returns memo
/// bytes. Putting them on chain is the caller's next step and it is this wallet's ordinary send
/// path: one `RawSendOutput` per entry of `NjPayPlan.memos`, every one addressed to the
/// *channel's* unified address (not the Nightjar recipient — a Nightjar address has no Zcash
/// receiver), every one carrying `NjPayPlan.memo_value_zatoshi`, all of them in the single call
/// to `proposeSendRaw` so they share one txid, then `executeProposal`. Splitting them across two
/// transactions produces fragments nobody can reassemble and value that is simply gone.
///
/// It replays the channel first, through the same code path as `nightjar_replay` — every
/// `msg_id` rebound to its body, every proof verified, the state closed at `tip − 10` — because
/// a payment is proved against that state's tree root. Pass the same `messages`, `vk`,
/// `birthday` and `chain_tip` the read path was given; a plan built against a state this wallet
/// did not verify would name an anchor the rest of the channel does not have.
///
/// `keys_dir` is the folder holding `interpreter-v0.pk`, `.vk` and `.circuit`. Validate it with
/// [`nightjar_check_proving_key`] when the settings screen loads: here, a missing or
/// wrong-circuit folder is refused before the replay, and a folder whose key set is not the one
/// the channel verifies with is refused after it.
///
/// Costs: the replay is seconds, the proof about 1.3 s and ~600 MB of peak memory. Call it off
/// the UI isolate and show progress. The proving key is read and dropped inside this call and is
/// never cached, so that peak is transient rather than a permanent floor.
///
/// Amounts are integer base units of the asset. `NjAsset.decimals` is applied to a display
/// string by the UI and to nothing here.
pub fn nightjar_build_pay(
    network: String,
    channel_uivk: String,
    birthday: u32,
    chain_tip: u32,
    vk: Vec<u8>,
    messages: Vec<NjMessageInput>,
    seed: Vec<u8>,
    keys_dir: String,
    asset_id: String,
    amount: u64,
    recipient: String,
    zec_sources: NjZecSources,
) -> Result<NjPayPlan, String> {
    catch(move || {
        let network = parse_network(&network)?;
        let asset = decode_asset_id(&asset_id)?;
        let messages = messages
            .iter()
            .map(decode_message)
            .collect::<Result<Vec<_>, String>>()?;
        let plan = pay::build_pay(
            network,
            &channel_uivk,
            birthday,
            chain_tip,
            &vk,
            messages,
            &seed,
            &keys_dir,
            &asset,
            amount,
            &recipient,
            &zec_sources.to_sources(),
        )?;
        Ok(NjPayPlan {
            msg_id: hex::encode(plan.msg_id),
            asset_id: hex::encode(plan.asset_id),
            asset_symbol: plan.asset_symbol,
            asset_decimals: plan.asset_decimals,
            amount: plan.amount,
            change: plan.change,
            spent: plan.spent,
            inputs: plan.inputs,
            memo_value_zatoshi: pay::MEMO_OUTPUT_VALUE_ZATOSHI,
            memos: plan.memos.iter().map(|m| m.to_vec()).collect(),
            body_bytes: plan.body_bytes,
            anchor_height: plan.anchor_height,
            chain_tip: plan.chain_tip,
            vk_hash: hex::encode(plan.vk_hash),
            proved_ms: plan.proved_ms,
        })
    })
}

/// An asset id is 32 bytes of hex. Refused rather than padded or truncated: a mistyped id that
/// happened to parse would select no notes and report insufficient funds against a balance the
/// same screen is showing.
fn decode_asset_id(asset_id: &str) -> Result<[u8; 32], String> {
    let raw = hex::decode(asset_id.trim())
        .map_err(|e| format!("asset id {asset_id:?} is not hex: {e}"))?;
    raw.try_into()
        .map_err(|_| format!("asset id {asset_id:?} is not 32 bytes"))
}

/// A `msg_id` that is not 32 bytes of hex is a malformed response, not a message to skip: it
/// would land in the state machine's replay-protection set as some other message's id, so the
/// whole call fails rather than silently replaying a channel with one entry wrong.
///
/// Shape only. Whether the id is the *right* id — whether it is the hash of the body arriving
/// beside it — is decided by `replay::check_binding`, which needs the channel id and so runs one
/// layer down. This function must not be read as validating anything but the hex.
fn decode_message(m: &NjMessageInput) -> Result<Message, String> {
    let raw = hex::decode(m.msg_id.trim())
        .map_err(|e| format!("message id {:?} is not hex: {e}", m.msg_id))?;
    let msg_id: [u8; 32] = raw
        .try_into()
        .map_err(|_| format!("message id {:?} is not 32 bytes", m.msg_id))?;
    // Display order on the wire, internal order in `Message` — the same reversal
    // `zakura-client-sqlite` stores and lightwalletd's `TxFilter.hash` expects. Getting this
    // backwards costs a fetch that finds nothing and a claim refused for want of evidence, which
    // is the safe direction but is invisible unless the reversal is stated where it happens.
    let txid = match m.txid.trim() {
        "" => None,
        hex_txid => {
            let mut raw: [u8; 32] = hex::decode(hex_txid)
                .map_err(|e| format!("txid {hex_txid:?} is not hex: {e}"))?
                .try_into()
                .map_err(|_| format!("txid {hex_txid:?} is not 32 bytes"))?;
            raw.reverse();
            Some(raw)
        }
    };
    Ok(Message {
        msg_id,
        kind: m.kind,
        count: m.fragments,
        completion: (m.height, m.tx_index, m.action_index),
        txid,
        body: m.body.clone(),
    })
}

impl NjZecSources {
    fn to_sources(&self) -> TxSources {
        TxSources {
            db_path: self.db_path.clone(),
            lightwalletd_url: self.lightwalletd_url.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nightjar::testdata;

    /// No database and no lightwalletd — the **fail-closed** path, and the only one these tests
    /// can exercise: `NjZecSources` names a wallet database or a lightwalletd, so a recording
    /// cannot be handed across this boundary the way `replay::tests` hands one to `replay_using`.
    ///
    /// Since the `0x04` re-record the recording carries two ZEC claims, so this is no longer the
    /// same replay as the verified one: the paid claim is refused for want of evidence and the
    /// anchors after it are orphaned, leaving 11 of 65 messages applied. These tests therefore
    /// assert the blind roots and counts. That the *verified* replay reaches the roots the indexer
    /// published is asserted in `replay::tests`, where a recording can be injected.
    fn no_sources() -> NjZecSources {
        NjZecSources {
            db_path: String::new(),
            lightwalletd_url: String::new(),
        }
    }

    fn devnet_messages() -> Vec<NjMessageInput> {
        testdata::messages()
            .into_iter()
            .map(|m| NjMessageInput {
                msg_id: hex::encode(m.msg_id),
                kind: m.kind,
                height: m.completion.0,
                tx_index: m.completion.1,
                action_index: m.completion.2,
                fragments: m.count,
                // The recording predates the field and carries no claim, so there is nothing to
                // fetch and nothing a txid would buy.
                txid: m.txid.map(|mut t| {
                    t.reverse();
                    hex::encode(t)
                }).unwrap_or_default(),
                body: m.body,
            })
            .collect()
    }

    fn view_for(seed: Vec<u8>) -> NjView {
        nightjar_replay(
            "regtest".into(),
            testdata::CHANNEL_UIVK.into(),
            testdata::BIRTHDAY,
            testdata::CHAIN_TIP,
            testdata::vk().to_vec(),
            devnet_messages(),
            seed,
            no_sources(),
        )
        .expect("the recorded channel replays across the FFI shape")
    }

    fn devnet_view() -> NjView {
        view_for(testdata::demo_seed())
    }

    #[test]
    fn identity_crosses_the_boundary_as_the_strings_the_cli_prints() {
        let id = nightjar_identity(testdata::demo_seed(), "regtest".into()).unwrap();
        assert_eq!(id.address, "njreg1qpxxmrhtpdnhecwly4vpu5mzz698kvxmnj6mesk0tgtlke5lhygq2akfujeyleyqn69t0pd2ry7f7gyarzqymx3tzpxkr0qk3j9qfjgvs2h3m0js6cqj55eap9rzwggym50cjdgzepllqj0rkpspua86t5gqkaznfr");
        assert_eq!(id.ak, testdata::DEMO_AK);
        assert_eq!(id.nkc.len(), 64);
    }

    #[test]
    fn the_devnet_uivk_reports_the_known_channel_id() {
        let id = nightjar_channel_id("regtest".into(), testdata::CHANNEL_UIVK.into()).unwrap();
        assert_eq!(id, testdata::CHANNEL_ID);
    }

    /// Every fallible entry point must return `Err`, never panic and never fall back to a
    /// default network: a panic unwinding into Dart is undefined behaviour, and a silent default
    /// would have the wallet replay a channel the user did not name.
    #[test]
    fn a_bad_network_string_is_an_error_on_every_entry_point() {
        assert!(nightjar_identity(testdata::demo_seed(), "mainnet".into()).is_err());
        assert!(nightjar_channel_id("".into(), testdata::CHANNEL_UIVK.into()).is_err());
        let e = nightjar_replay(
            "Regtest".into(),
            testdata::CHANNEL_UIVK.into(),
            testdata::BIRTHDAY,
            testdata::CHAIN_TIP,
            testdata::vk().to_vec(),
            vec![],
            testdata::demo_seed(),
            no_sources(),
        )
        .err()
        .expect("an unparsed network must not be defaulted");
        assert!(e.contains("unknown network"), "{e}");
    }

    /// A malformed `msg_id` fails the call rather than being skipped: skipping it would replay
    /// the channel with one message missing and report a state root nobody else computes.
    #[test]
    fn a_malformed_message_id_fails_the_whole_replay() {
        let mut messages = devnet_messages();
        messages[0].msg_id = "beef".into();
        let e = nightjar_replay(
            "regtest".into(),
            testdata::CHANNEL_UIVK.into(),
            testdata::BIRTHDAY,
            testdata::CHAIN_TIP,
            testdata::vk().to_vec(),
            messages,
            testdata::demo_seed(),
            no_sources(),
        )
        .err()
        .expect("a malformed message id must fail the call");
        assert!(e.contains("32 bytes"), "{e}");
    }

    #[test]
    fn the_view_reports_the_roots_the_replay_produced_and_the_wallets_own_asset() {
        let v = devnet_view();
        assert_eq!(v.height, testdata::CANONICAL_HEIGHT);
        assert_eq!(v.chain_tip, testdata::CHAIN_TIP);
        // the blind roots: see `no_sources` above for why this boundary cannot reach the
        // published ones, and `replay::tests` for the assertion that the verified path does
        assert_eq!(v.state_root, testdata::STATE_ROOT_BLIND);
        assert_eq!(v.tree_root, testdata::TREE_ROOT_BLIND);
        assert_eq!(v.applied, testdata::ACCEPTED_BLIND);
        assert_eq!(v.ignored, testdata::IGNORED_BLIND);
        assert_eq!(v.ignored_reasons.len(), testdata::IGNORED_BLIND as usize);
        assert!(
            v.ignored_reasons
                .iter()
                .any(|r| r.ends_with("proof rejected")),
            "{:?}",
            v.ignored_reasons
        );
        assert_eq!(v.preview_messages, 0);

        assert_eq!(v.notes.len(), 2, "two receipts on this channel, not one");
        let n = v
            .notes
            .iter()
            .find(|n| n.created_by == testdata::SEND_TO_DEMO_MSG)
            .expect("the receipt whose other half is also recorded");
        assert_eq!(n.amount, testdata::DEMO_NOTE_AMOUNT);
        assert_eq!(n.asset_id, testdata::ASSET_ID);
        assert_eq!(n.source, "ciphertext");
        // spent, and naming its spender: this wallet sent both receipts back
        assert!(n.spent);
        assert_eq!(n.spent_by.as_deref(), Some(testdata::DEMO_SPENDS_IT_MSG));
        assert_eq!(n.spent_height, Some(testdata::DEMO_SPENDS_IT_HEIGHT));

        assert_eq!(v.assets.len(), 1);
        let a = &v.assets[0];
        assert_eq!(a.asset_id, testdata::ASSET_ID);
        assert_eq!(a.name, "Devnet Mint");
        assert_eq!(a.symbol, "DMT");
        assert_eq!(a.decimals, 2);
        // this wallet's two receipts were both spent back, so the registry row it joins to
        // carries the asset's metadata and a zero balance — the join is what is under test
        assert_eq!(a.balance, 0);
        assert_eq!(a.note_count, 0);
        assert_eq!(a.issued, testdata::ASSET_ISSUED);
        assert_eq!(a.max_supply, Some(testdata::ASSET_MAX_SUPPLY));
        assert!(a.public);
    }

    /// **What the wallet sent, across the boundary.** The recorded channel carries one wallet's
    /// whole history — an issuance, two payments with change, two receipts — and every note of it
    /// must cross, spent ones marked and naming the message that spent them. Before this, the
    /// only trace of a payment that reached Dart was its change, which the activity feed had no
    /// choice but to render as an arrival.
    #[test]
    fn a_spent_note_crosses_the_boundary_marked_and_attributed() {
        let v = view_for(testdata::issuer_seed());
        assert_eq!(v.notes.len(), 5);
        assert_eq!(v.notes.iter().filter(|n| n.spent).count(), 2);

        let issued = &v.notes[0];
        assert_eq!((issued.position, issued.amount), (3, 600));
        assert_eq!(issued.created_by, testdata::ISSUANCE_MSG);
        assert_eq!(issued.created_inputs, 0, "an issuance consumes nothing");
        assert_eq!(issued.created_outputs, 1);
        assert!(issued.spent);
        assert_eq!(issued.spent_by.as_deref(), Some(testdata::FIRST_SEND_MSG));
        assert_eq!(issued.spent_height, Some(testdata::FIRST_SEND_HEIGHT));
        assert_eq!(issued.spent_inputs, Some(1));
        assert_eq!(issued.spent_outputs, Some(2));

        // `spent` comes from the channel's nullifier set and the four beside it from the index
        // of which message published each nullifier. On a whole recording they agree note for
        // note, which is what makes a caller free to branch on either — and this is the
        // assertion that would catch a replay that lost half of that record.
        for n in &v.notes {
            assert_eq!(n.spent, n.spent_by.is_some());
            assert_eq!(n.spent, n.spent_height.is_some());
            assert_eq!(n.spent, n.spent_inputs.is_some());
            assert_eq!(n.spent, n.spent_outputs.is_some());
        }
    }

    /// The reconstruction the doc comment on [`nightjar_replay`] promises, performed on the FRB
    /// shape alone: group by `msg_id`, own every input, and what left is the inputs less what
    /// came back. The third output the circuit allows is the case this must not get wrong — the
    /// counts say an output exists that this wallet cannot see, and its amount is not zero.
    #[test]
    fn a_caller_can_tell_a_payment_from_a_receipt_with_nothing_else() {
        let v = view_for(testdata::issuer_seed());
        let m = testdata::FIRST_SEND_MSG;

        let inputs: Vec<&NjNote> = v
            .notes
            .iter()
            .filter(|n| n.spent_by.as_deref() == Some(m))
            .collect();
        let outputs: Vec<&NjNote> = v.notes.iter().filter(|n| n.created_by == m).collect();
        assert_eq!(inputs.len() as u32, inputs[0].spent_inputs.unwrap());
        let left: u64 = inputs.iter().map(|n| n.amount).sum::<u64>()
            - outputs.iter().map(|n| n.amount).sum::<u64>();
        assert_eq!(left, testdata::FIRST_SEND_AMOUNT);
        assert!(
            (outputs.len() as u32) < outputs[0].created_outputs,
            "an output of this message belongs to somebody else; only its existence is visible"
        );

        // the receiving side of the same channel: no input of its message is this wallet's
        let demo = devnet_view();
        let received: Vec<&NjNote> = demo
            .notes
            .iter()
            .filter(|n| n.created_by == testdata::SEND_TO_DEMO_MSG)
            .collect();
        assert_eq!(received.len(), 1);
        // per-message, as in `owned::tests::the_two_sides_of_one_payment_agree`: what makes this a
        // receipt is that no input of *this* message was the demo wallet's, not that the demo
        // wallet never spent anything — on this channel it spends both of its receipts later
        assert!(demo
            .notes
            .iter()
            .all(|n| n.spent_by.as_deref() != Some(testdata::SEND_TO_DEMO_MSG)));
    }

    /// **The balance did not change when the history arrived.** `notes` now carries spent notes;
    /// `balance` must still be what the wallet holds, or every screen showing it is wrong by the
    /// sum of everything the user has ever spent.
    #[test]
    fn the_balance_is_unspent_notes_only_however_long_the_history_is() {
        let v = view_for(testdata::issuer_seed());
        let a = &v.assets[0];
        assert_eq!(a.asset_id, testdata::ASSET_ID);
        assert_eq!(a.balance, 600, "440 + 150 + 10, the unspent three");
        assert_eq!(a.note_count, 3);
        assert_eq!(
            a.balance,
            v.notes
                .iter()
                .filter(|n| !n.spent && n.asset_id == a.asset_id)
                .map(|n| n.amount)
                .sum::<u64>()
        );
        assert!(
            a.balance
                < v.notes
                    .iter()
                    .filter(|n| n.asset_id == a.asset_id)
                    .map(|n| n.amount)
                    .sum::<u64>(),
            "this wallet has spent, so its history must sum to more than its balance"
        );
        // and the counterparty, which spent everything it received, reports nothing held while
        // still carrying the history that says so
        let demo = devnet_view();
        assert_eq!(demo.assets[0].balance, 0);
        assert_eq!(demo.notes.len(), 2);
        assert!(demo.notes.iter().all(|n| n.spent));
    }

    /// The finality arithmetic the UI counts down with must be the one the replay actually
    /// applied, or the wallet promises a balance at a height it will not use.
    #[test]
    fn the_exposed_canonical_height_is_the_one_the_replay_used() {
        let v = devnet_view();
        assert_eq!(
            nightjar_canonical_height(testdata::CHAIN_TIP, testdata::BIRTHDAY).unwrap(),
            v.height
        );
        // a channel younger than the finality depth is entirely preview
        assert_eq!(nightjar_canonical_height(5, 100).unwrap(), 99);
    }

    /// An empty seed is a plausible thing for a locked wallet to pass, and it must come back as
    /// a view with no notes rather than as a panic crossing the bridge.
    #[test]
    fn an_empty_seed_owns_nothing_and_does_not_panic() {
        let v = nightjar_replay(
            "regtest".into(),
            testdata::CHANNEL_UIVK.into(),
            testdata::BIRTHDAY,
            testdata::CHAIN_TIP,
            testdata::vk().to_vec(),
            devnet_messages(),
            vec![],
            no_sources(),
        )
        .unwrap();
        assert!(v.notes.is_empty());
        assert_eq!(
            v.state_root,
            testdata::STATE_ROOT_BLIND,
            "the channel's state does not depend on who is reading it"
        );
        assert_eq!(v.assets[0].balance, 0);
    }
}
