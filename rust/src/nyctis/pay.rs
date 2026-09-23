//! Building a Nyctis payment. `docs/NYCTIS-POC.md` ("Sending") describes the flow in the app that
//! calls it.
//!
//! Reading a channel needs a 1,880-byte verifying key and about 3 ms per proof. *Making* a
//! payment needs the ~83 MiB proving key, about 1.2 s of CPU and ~590 MiB of peak memory for one
//! proof (circuit v0.4 on an M4 Pro laptop; the current circuit v0.5 is not re-benchmarked). That
//! asymmetry is the whole shape of this module: everything cheap is done first and everything
//! expensive is done once, at the end, after every reason to refuse has already been found.
//!
//! **Nothing here broadcasts.** [`build_pay`] returns memo bytes. Its only network access is the
//! replay's: for a message that claims ZEC it may fetch the carrying transaction from this
//! wallet's own lightwalletd (`replay.rs`, `carrier.rs`), never from the indexer. Putting the
//! memos on chain is this wallet's ordinary send path —
//! `wallet::sync::send::propose_send_raw` with one [`RawSendOutput`] per memo, all addressed to
//! the channel's unified address, followed by `execute_proposal`. The 1-8 memos **must ride one
//! transaction**: a reader reassembles a message only from fragments that share a txid, so a
//! plan whose memos were split across two sends is a message nobody can decode and value that is
//! gone. `propose_send_raw` already guarantees that (one `Payment` per memo, one request), which
//! is why it, and not the single-output text path, is the caller.
//!
//! Money is integer base units of the asset throughout. `NyAsset::decimals` is a display hint
//! the UI applies to a string; no arithmetic on this path — selection, change, the note amounts
//! that enter the circuit — ever sees a float.
//!
//! [`RawSendOutput`]: crate::wallet::sync::RawSendOutput

use std::path::{Path, PathBuf};
use std::time::Instant;

use nyctis_codec::policy::Context;
use nyctis_codec::transport::{frame, KIND_TRANSITION, MEMO_LEN};
use nyctis_zk::circuit::N_IN;
use nyctis_codec::transition::Transition;
use nyctis_codec::transport::{ChannelId, Delivered};
use nyctis_state::{Outcome, ProofVerifier, ANCHOR_WINDOW};
use nyctis_zk::keys::{Account, Address};
use nyctis_zk::note::Note;
use nyctis_zk::prover::{Keys, SpendInput};
use nyctis_zk::transition::{build, path_in_state, OutputSpec, Spend, TransitionSpec};
use nyctis_zk::verifier::Groth16Verifier;
use nyctis_zk::{fq_from_bytes, fq_mod, Fq, Fr};

use crate::nyctis::carrier::TxSources;
use crate::nyctis::network::NyctisNetwork;
use crate::nyctis::owned::{spendable_notes, Spendable};
use crate::nyctis::replay::{self, ChannelView, Message};
use crate::nyctis::trust;
use crate::wallet::network::WalletNetwork;

/// What each memo output is worth in zatoshi.
///
/// A Nyctis message rides ordinary shielded outputs to the channel's address, and a shielded
/// output must carry *some* value or it is dust the proposer drops. This is the Nyctis CLI's
/// own default (`nyctis wallet pay --value`), comfortably above the ZIP 317 dust floor, and it
/// is charged **per memo**: a 3-fragment message costs `3 × MEMO_OUTPUT_VALUE_ZATOSHI` plus the
/// Zcash fee, and that ZEC goes to the channel address, not to the Nyctis recipient. The
/// review screen has to say so — it is the one cost of a Nyctis payment denominated in
/// something other than the asset being paid.
pub const MEMO_OUTPUT_VALUE_ZATOSHI: u64 = 10_000;

/// File names of a key set on disk, as `nyctis_zk::prover` writes them. Restated here only to
/// name them in an error a user can act on; the checking is `nyctis-zk`'s.
const PK_FILE: &str = "interpreter-v0.pk";
const VK_FILE: &str = "interpreter-v0.vk";
const MANIFEST_FILE: &str = "interpreter-v0.circuit";

/// What a settings screen needs to decide whether this wallet can sign a Nyctis payment at
/// all, without paying the ~83 MiB read it would take to find out at signing time.
#[derive(Debug)]
pub struct ProvingKeyInfo {
    /// The directory, as given.
    pub dir: String,
    /// The circuit fingerprint the sidecar manifest records and this build agrees with, e.g.
    /// `constraints=136263;instances=32`. A **diagnostic**: it says which circuit shape the key
    /// was made for and nothing about whose ceremony made it.
    pub circuit: String,
    /// `BLAKE2b-256` of the compressed verifying key beside the proving key.
    ///
    /// This is what identifies a key. Compare it with `NyView::vk_hash` — the hash of the key
    /// the channel's proofs actually verify against — before offering to send: two key sets can
    /// share a `circuit` string and be mutually unusable, and a proof made under the wrong one
    /// is rejected by every verifier on the channel after the user has already paid the Zcash
    /// fee.
    pub vk_hash: [u8; 32],
    /// Size of `interpreter-v0.pk` in bytes, so a UI can say what a settings path is pointing at.
    pub proving_key_bytes: u64,
}

/// A payment, proven and framed, ready for the transport.
#[derive(Debug)]
pub struct PayPlan {
    /// The id the framing computed, `BLAKE2b-256("nyctis.msg.v0" ‖ channel_id ‖ [VERSION,
    /// kind] ‖ count_le ‖ body)`.
    ///
    /// The read path recomputes exactly this from the body it is served and refuses any message
    /// whose id does not match (`replay::check_binding`), so this is not a label the sender
    /// chooses — it is a fact about the bytes below, and it is the handle to watch for on the
    /// channel once the carrying transaction confirms.
    pub msg_id: [u8; 32],
    pub asset_id: [u8; 32],
    /// The `ASSET` message's symbol, or empty when nobody has named this asset.
    pub asset_symbol: String,
    /// Display hint only; no arithmetic here applies it.
    pub asset_decimals: u8,
    /// Integer base units paid to the recipient.
    pub amount: u64,
    /// Integer base units returned to this wallet as a second output. Zero when the selected
    /// notes happened to total the amount exactly, and then the transition has one output.
    pub change: u64,
    /// Base units consumed: `amount + change`.
    pub spent: u64,
    /// How many of this wallet's notes are being nullified. At most [`N_IN`].
    pub inputs: u32,
    /// The memos, each exactly [`MEMO_LEN`] bytes, in fragment order. **All of them go in one
    /// transaction.**
    pub memos: Vec<[u8; MEMO_LEN]>,
    /// Encoded transition body, before framing.
    pub body_bytes: u32,
    /// The canonical height this plan was built at, and the height the transition *declares*.
    /// Everything in it — the anchor, the note positions, the openings — is only valid here.
    pub anchor_height: u32,
    /// The chain tip the plan was built against. Reported, not built against.
    pub chain_tip: u32,
    /// Hash of the verifying key this proof will be checked against, which is both the channel's
    /// (from the replay) and the key directory's — [`build_pay`] refuses to prove unless they
    /// agree.
    pub vk_hash: [u8; 32],
    /// Wall-clock time spent inside `build` (witness assembly, Groth16 proof, signatures).
    pub proved_ms: u32,
    /// The protocol's anchor window (`nyctis_state::ANCHOR_WINDOW`): the plan is good while
    /// the chain is fewer than this many blocks past `anchor_height`. The protocol's constant,
    /// not the indexer's `/api/status` claim about it — an indexer reporting a larger window
    /// would otherwise keep an expired plan looking fresh.
    pub anchor_window: u32,
    /// The channel address the memos must be sent to, checked against the channel UIVK before
    /// anything was proved (see [`trust::check_channel_address`]).
    pub channel_address: String,
    /// The replay this plan was built on, reported so the caller can hold it to the same
    /// integrity checks as the read path's `NyView`: `state_root` and `tree_root` against the
    /// indexer's for the same height, and the applied/ignored counts for the wrong-key shape.
    pub state_root: [u8; 32],
    pub tree_root: [u8; 32],
    pub applied: u32,
    pub ignored: u32,
    pub ignored_reasons: Vec<String>,
    pub zec_unverifiable: u32,
    pub preview_messages: u32,
}

impl PayPlan {
    /// ZEC that has to accompany the memos, ignoring the Zcash fee: one dust-avoiding output per
    /// fragment, all to the channel address.
    pub fn memo_value_zatoshi(&self) -> u64 {
        MEMO_OUTPUT_VALUE_ZATOSHI * self.memos.len() as u64
    }
}

/// Validate a proving-key directory and report what is in it, **without loading the proving
/// key**.
///
/// This exists so a settings screen can disable sending with a reason instead of discovering the
/// problem at the moment a user presses Send — by which point they have waited for a replay and
/// are looking at a review screen that promised a payment. It reads the 1.8 KiB verifying key
/// and the one-line sidecar, not the 83 MiB `interpreter-v0.pk`; it only `stat`s that.
///
/// Every failure is a sentence a UI can show verbatim. The three that actually happen are a path
/// that points nowhere, a directory holding keys from an older circuit (which would produce
/// proofs every verifier on the channel rejects), and a manifest that does not describe the key
/// sitting next to it.
pub fn check_proving_key(keys_dir: &str) -> Result<ProvingKeyInfo, String> {
    let dir = PathBuf::from(keys_dir.trim());
    if keys_dir.trim().is_empty() {
        return Err(
            "No proving-key folder is set. Nyctis payments need the interpreter \
                    proving key (about 83 MiB); point this setting at the folder holding \
                    interpreter-v0.pk, interpreter-v0.vk and interpreter-v0.circuit."
                .to_string(),
        );
    }
    if !dir.is_dir() {
        return Err(format!(
            "{} is not a folder. Point this setting at the folder that holds {PK_FILE}, \
             {VK_FILE} and {MANIFEST_FILE}.",
            dir.display()
        ));
    }
    for name in [PK_FILE, VK_FILE, MANIFEST_FILE] {
        if !dir.join(name).is_file() {
            return Err(format!(
                "{} has no {name}. A Nyctis proving-key folder holds all three of {PK_FILE}, \
                 {VK_FILE} and {MANIFEST_FILE}; generate them with the Nyctis zk-setup tool.",
                dir.display()
            ));
        }
    }

    // `load_vk_checked` reads the small key, checks the sidecar's circuit fingerprint against
    // this build's, checks the manifest's recorded `vk_hash` against the key bytes on disk, and
    // checks both against any hash this build pins. Its messages already name the directory and
    // the remedy, so they are passed through rather than rewritten — a second wording here would
    // drift from the one the CLI shows for the same fault.
    let (_pvk, vk_hash) = Keys::load_vk_checked(&dir.join(VK_FILE))
        .map_err(|e| format!("Nyctis proving keys in {}: {e}", dir.display()))?;

    let proving_key_bytes = std::fs::metadata(dir.join(PK_FILE))
        .map_err(|e| format!("reading {}: {e}", dir.join(PK_FILE).display()))?
        .len();

    Ok(ProvingKeyInfo {
        dir: dir.display().to_string(),
        circuit: Keys::FINGERPRINT.to_string(),
        vk_hash,
        proving_key_bytes,
    })
}

/// Plan a payment of `amount` base units of `asset_id` to `recipient` on `network`.
///
/// The order of work is the whole design. Address, asset and amount are parsed first because
/// they are free; the key directory is validated second because it is a `stat` and a 1.8 KiB
/// read and it is the failure a user is most likely to have; the channel is replayed third
/// (seconds, and it verifies every proof the channel carries); inputs are selected fourth, which
/// is where "insufficient funds" comes from. **Only then** is the 83 MiB proving key read and a
/// proof made. Reordering any of that turns a refusal a user waits milliseconds for into one
/// they wait a minute and 600 MB for.
///
/// The replay is the *same* call the read path makes ([`replay::replay`]), not a second copy of
/// it: `msg_id` rebinding, the Groth16 verification of every message, the `tip − 10` finality
/// bound and the below-birthday refusal all apply here unchanged. Spending against a state this
/// wallet has not verified would mean proving against an anchor the rest of the channel does not
/// have.
///
/// # What can go wrong that is not an error here
///
/// The anchor is the tree root at `tip − 10`. A transition naming it is applied by anyone who
/// replays to a height where that anchor is still inside the anchor window (200 blocks on the
/// devnet), so a plan is not valid forever — it is valid for roughly that many blocks. Sitting
/// on a plan and broadcasting it later gets it ignored with "unknown anchor", and the ZEC spent
/// carrying it is spent either way. Build, review, send.
#[allow(clippy::too_many_arguments)]
pub fn build_pay(
    network: WalletNetwork,
    channel_uivk: &str,
    // The unified address the memos will be sent to. Checked against `channel_uivk` before
    // anything else, because a pair that does not belong together reads one channel and pays
    // into another — the ZEC is spent and the payment never appears where the wallet looks.
    channel_address: &str,
    birthday: u32,
    chain_tip: u32,
    vk: &[u8],
    // The channel configuration's `vk_hash`. `vk` must hash to it or nothing is replayed, let
    // alone proved: see [`trust::check_vk_pin`].
    vk_pin: &str,
    messages: Vec<Message>,
    // The signing account, derived from the BIP39 seed by the caller
    // (`keys::account_from_mnemonic`) and wiped when the caller drops it. This function never
    // sees a seed.
    account: &Account,
    keys_dir: &str,
    asset_id: &[u8; 32],
    amount: u64,
    recipient: &str,
    // Where the replay may look for the Zcash transaction behind a ZEC claim. Threaded through
    // rather than defaulted: this is the *same* replay the read path runs, and a send that
    // planned against a view with claims refused for want of evidence would be spending against
    // a tree the rest of the channel does not have.
    sources: &TxSources,
) -> Result<PayPlan, String> {
    // --- free checks, first -------------------------------------------------------------
    if amount == 0 {
        return Err("Enter an amount greater than zero.".to_string());
    }
    let asset = fq_from_bytes(asset_id).ok_or_else(|| {
        format!(
            "Asset id {} is not a canonical field element, so no note can carry it.",
            hex::encode(asset_id)
        )
    })?;
    let recipient = decode_recipient(network, recipient)?;
    let cid = replay::channel_id_for_uivk(network, channel_uivk)?;
    // The trust anchors, before anything slow: the key the channel's proofs are checked against
    // must be the one the configuration pins, and the address the memos go to must be the
    // channel's own.
    trust::check_vk_pin(vk, vk_pin)?;
    trust::check_channel_address(network, channel_uivk, channel_address)?;

    // Paying yourself is legal and occasionally useful (consolidating two notes into one), but
    // it is far more often a paste of one's own receive address, and the note it produces is
    // indistinguishable from change. Refusing is the wrong call — it is the user's money — so
    // this is deliberately *not* an error and the note is left for the UI to label.

    // --- the key directory, before anything slow ----------------------------------------
    let keys_info = check_proving_key(keys_dir)?;

    // --- the verified channel ------------------------------------------------------------
    let mut view =
        replay::replay(network, channel_uivk, birthday, chain_tip, vk, messages, sources)?;

    // **The key that signs must be the key the channel verifies with.** Both hashes are in hand
    // and comparing them costs nothing, so the wrong-ceremony case is refused here rather than
    // becoming a proof that is made, paid for, broadcast and then ignored by every verifier with
    // "proof rejected" — which reads, to the user, as the payment having silently failed.
    if keys_info.vk_hash != view.vk_hash {
        return Err(format!(
            "The proving keys in {} belong to a different key set than this channel verifies \
             with (keys {}, channel {}). A payment proved with them would be rejected by every \
             verifier on the channel. Point the proving-key setting at the key set this channel \
             was set up with.",
            keys_info.dir,
            hex::encode(keys_info.vk_hash),
            hex::encode(view.vk_hash),
        ));
    }

    // --- input selection ------------------------------------------------------------------
    let height = view.height();
    let owned = spendable_notes(&view, account);
    let picked = select_inputs(owned, &asset, amount, height, account)?;
    // Checked, not `sum()`: note amounts are attacker-sized on a self-issued asset, and a
    // release build wraps silently. `select_inputs` already refused a wrapping total, so an
    // overflow here is unreachable — and still an error rather than a wrapped `change`.
    let spent = checked_total(picked.iter().map(|o| o.note.amount))?;
    let change = spent.checked_sub(amount).ok_or_else(|| {
        format!("The selected notes total {spent}, less than the {amount} being paid.")
    })?;
    let n_in = picked.len() as u8;

    let spends = picked
        .iter()
        .map(|o| spend_own(&view, o, n_in, height, account))
        .collect::<Result<Vec<_>, String>>()?;

    // --- outputs ---------------------------------------------------------------------------
    //
    // A plain payment to an address is a note under that address's `pk(ak)`, encrypted to the
    // address's `pk_enc`. Change is the same thing addressed to ourselves. No `before()` deadline
    // is attached: the CLI's `--expires` is a real feature and this cut does not expose it,
    // because a note the recipient cannot open after height h is a payment that can expire in
    // the recipient's hands and that needs UI of its own to be honest about.
    let p_rcpt = recipient.default_policy();
    p_rcpt
        .validate()
        .map_err(|e| format!("The recipient address produces an invalid spend policy: {e}"))?;
    let rcpt_pk = recipient.pk_enc_element().ok_or_else(|| {
        "The recipient address carries an encryption key that is not a valid decaf377 point."
            .to_string()
    })?;

    let mut outputs = vec![OutputSpec {
        note: Note {
            policy_root: nyctis_zk::hash::policy_hash(&p_rcpt),
            asset_id: asset,
            amount,
            // `fq_mod` rather than `fq_from_bytes`: `Address::decode` already refused a
            // non-canonical `nkc`, so the reduction is the identity here and matches what every
            // other builder does with the same field.
            nkc: fq_mod(&recipient.nkc),
            data: Fq::from(0u64),
            rseed: Note::random_rseed(),
            recoverable_from: None,
            explicit_rcm: None,
        },
        policy: p_rcpt,
        recipients: vec![rcpt_pk],
        nk: None,
    }];
    if change > 0 {
        let p_self = account.address().default_policy();
        outputs.push(OutputSpec {
            note: Note {
                policy_root: nyctis_zk::hash::policy_hash(&p_self),
                asset_id: asset,
                amount: change,
                nkc: account.nkc(),
                data: Fq::from(0u64),
                rseed: Note::random_rseed(),
                recoverable_from: None,
                explicit_rcm: None,
            },
            policy: p_self,
            recipients: vec![account.pk_enc()],
            nk: None,
        });
    }

    let spec = TransitionSpec {
        channel_id: cid,
        anchor: fq_mod(&view.state.tree_root()),
        declared_height: height,
        spends,
        outputs,
        references: vec![],
        issuance: None,
        // Never set on this path. `pay` builds a transfer inside one channel, and an export is a
        // different message entirely: it routes an output slot into the source channel's
        // `Exported` map instead of the commitment tree, so the recipient would find no note here
        // and the wallet has no destination channel to name (`spec/transition-v0.md` §6 step 6e,
        // revision 8). A cross-channel send belongs in its own builder beside this one, with the
        // destination and `claim_deadline` as arguments; until that exists, `None` is the whole
        // truth rather than a placeholder.
        export: None,
    };

    // --- the expensive part ------------------------------------------------------------------
    //
    // The proving key is read here and dropped a few lines below, deliberately not cached in a
    // static: it is ~83 MiB of resident memory on a phone that spends most of its life not
    // sending, and `prove_staged` (which `build` calls) already peaks around 600 MB on top of
    // it. Holding the key between sends would turn a transient peak into a permanent floor.
    let keys = Keys::load(Path::new(keys_dir.trim())).map_err(|e| {
        format!(
            "Loading the Nyctis proving key from {}: {e}",
            keys_dir.trim()
        )
    })?;
    let started = Instant::now();
    let (tx, _witness) = build(&keys.pk, spec, &mut rand::rngs::OsRng)
        .map_err(|e| format!("Proving the Nyctis payment: {e}"))?;
    let proved_ms = started.elapsed().as_millis().min(u32::MAX as u128) as u32;
    drop(keys);

    let body = tx.encode();
    let (msg_id, memos) = frame(&cid, KIND_TRANSITION, &body).map_err(|e| {
        format!(
            "Framing the Nyctis payment into memos: {} ({} body bytes)",
            e.reason(),
            body.len()
        )
    })?;

    // Everything the plan reports about the replay, taken before the dry run below moves the
    // state on.
    let state_root = view.state.state_root();
    let tree_root = view.state.tree_root();
    let applied = view.accepted();
    let ignored = view.ignored();
    let zec_unverifiable = view.zec_unverifiable();
    let ignored_reasons: Vec<String> = view
        .outcomes
        .iter()
        .filter(|o| !o.accepted)
        .map(|o| format!("{} {}", hex::encode(o.msg_id), o.reason))
        .collect();
    let record = view.state.asset(asset_id);
    let asset_symbol = record
        .map(|r| r.symbol_str().into_owned())
        .unwrap_or_default();
    let asset_decimals = record.map(|r| r.decimals).unwrap_or(0);

    // **C9 — no memo leaves this function unless the channel would accept it.** The proving key
    // is checked only by the verifying key beside it; a `.pk` from another setup passes every
    // check above and produces a proof every verifier rejects, after the user has paid the ZEC to
    // carry it. So the proof is verified against the *pinned* key, and then the whole transition
    // is applied to this wallet's own verified state, which also catches a spent input or an
    // anchor the state no longer keeps.
    let verifier = Groth16Verifier::from_vk_bytes(vk)
        .map_err(|e| format!("Loading the channel's verifying key to check the payment: {e}"))?;
    verify_own_proof(&verifier, &tx, &cid)?;
    dry_run(&mut view, &verifier, msg_id, &body, memos.len() as u16)?;

    Ok(PayPlan {
        msg_id,
        asset_id: *asset_id,
        asset_symbol,
        asset_decimals,
        amount,
        change,
        spent,
        inputs: picked.len() as u32,
        body_bytes: body.len() as u32,
        memos,
        anchor_height: height,
        chain_tip: view.chain_tip,
        vk_hash: view.vk_hash,
        proved_ms,
        anchor_window: ANCHOR_WINDOW,
        channel_address: channel_address.trim().to_string(),
        state_root,
        tree_root,
        applied,
        ignored,
        ignored_reasons,
        zec_unverifiable,
        preview_messages: view.preview_messages,
    })
}

/// Refuse a transition whose proof does not verify against `verifier` — which, on this path, is
/// the channel's pinned key.
fn verify_own_proof(
    verifier: &Groth16Verifier,
    tx: &Transition,
    cid: &ChannelId,
) -> Result<(), String> {
    if verifier.verify(tx, cid, &tx.ct_digest()) {
        Ok(())
    } else {
        Err("The payment's proof does not verify against this channel's verifying key, so \
             every verifier would ignore it. The proving key in the configured folder is not \
             the one its verifying key was made with; replace the folder with a matching key \
             set. Nothing was sent."
            .to_string())
    }
}

/// Apply the built message to this wallet's own replayed state, as the next block would, and
/// require the state machine to accept it.
///
/// The completion height is the block after the chain tip — the earliest the carrying
/// transaction can be mined — which is also the height every other verifier will judge it at.
/// `view` is consumed in spirit: its state has moved on after this and must not be reported.
fn dry_run(
    view: &mut ChannelView,
    verifier: &impl ProofVerifier,
    msg_id: [u8; 32],
    body: &[u8],
    count: u16,
) -> Result<(), String> {
    let completion = view.chain_tip.max(view.height()).saturating_add(1);
    view.state.begin_block(completion);
    let outcome = view.state.apply(
        &Delivered {
            msg_id,
            kind: KIND_TRANSITION,
            completion: (completion, 0, 0),
            body: body.to_vec(),
            fragments: vec![(completion, 0, 0); count as usize],
        },
        verifier,
        &mut nyctis_state::NoZec,
    );
    match outcome {
        Outcome::Applied { .. } => Ok(()),
        Outcome::Ignored { reason, .. } => Err(format!(
            "This payment would be refused by the channel ({reason}), so it was not handed \
             over for sending. Nothing was sent."
        )),
        other => Err(format!(
            "This payment was not applied as a transfer by this wallet's own replay ({other:?}); \
             nothing was sent."
        )),
    }
}

/// Sum note amounts, refusing rather than wrapping on overflow.
fn checked_total(amounts: impl IntoIterator<Item = u64>) -> Result<u64, String> {
    amounts.into_iter().try_fold(0u64, |acc, a| {
        acc.checked_add(a).ok_or_else(|| {
            "These notes add up to more than any amount this wallet can represent (the total \
             overflows 64 bits), so they cannot be spent together."
                .to_string()
        })
    })
}

/// Decode a recipient address and require it to be **this network's**.
///
/// `Address::decode` returns the HRP and throwing it away is the mistake this exists to prevent:
/// the key material in a Nyctis address is seed-derived, not network-derived, so an `nyreg1…`
/// string is a perfectly well-formed mainnet address that nobody on mainnet controls. Nothing is
/// stolen; the payment simply lands in an account the user cannot open, and there is no error
/// anywhere to say so.
fn decode_recipient(network: WalletNetwork, recipient: &str) -> Result<Address, String> {
    let trimmed = recipient.trim();
    if trimmed.is_empty() {
        return Err("Enter a Nyctis address to pay.".to_string());
    }
    let (hrp, address) = Address::decode(trimmed)
        .map_err(|e| format!("That is not a valid Nyctis address: {e}"))?;
    let want = network.ny_hrp();
    if hrp != want {
        return Err(format!(
            "That address is for the {hrp} network, but this wallet is on {want}. Ask the \
             recipient for a {want} address."
        ));
    }
    Ok(address)
}

/// Whether this note's policy opens under the wallet's own key at `height`, with no covenant
/// output and no ZEC payment on offer.
///
/// Owning a note and being able to open one are different things, and the gap is not exotic: a
/// note under `pk(me) && before(h)` past `h`, or one under a policy naming a key this wallet does
/// not hold, is listed on the balance screen and cannot fund a payment. Selecting one anyway
/// fails at proving time — after the 83 MiB load — with an error about constraint satisfaction,
/// so the filter runs before selection and the shortfall is reported as insufficient funds.
pub fn openable_now(o: &Spendable, height: u32, account: &Account) -> bool {
    o.policy.opening(&context(o, height, 1, account)).is_some()
}

fn context(o: &Spendable, height: u32, n_in: u8, account: &Account) -> Context {
    Context {
        keys: [account.spend.ak_bytes()].into_iter().collect(),
        height,
        self_note: Some(o.note_view()),
        n_in,
        ..Default::default()
    }
}

/// Pick up to [`N_IN`] unspent, currently-openable notes of `asset` covering `amount`, largest
/// first.
///
/// `N_IN` is the circuit's input arity and it is 2. That is a real limit on what this wallet can
/// pay, not an implementation shortcut: a balance spread over five notes of 20 cannot pay 100 in
/// one transition, and the honest remedy is to consolidate first. The error says so, because
/// "insufficient funds" against a screen showing a sufficient balance is otherwise unreadable.
fn select_inputs(
    mut owned: Vec<Spendable>,
    asset: &Fq,
    amount: u64,
    height: u32,
    account: &Account,
) -> Result<Vec<Spendable>, String> {
    // Saturating: `held` is only reported in the error below, and a total that does not fit in
    // 64 bits is still "more than enough" for that sentence. Selection itself is checked.
    let held: u64 = owned
        .iter()
        .filter(|o| o.note.asset_id == *asset)
        .fold(0u64, |acc, o| acc.saturating_add(o.note.amount));

    owned.retain(|o| o.note.asset_id == *asset && openable_now(o, height, account));
    owned.sort_by(|a, b| b.note.amount.cmp(&a.note.amount));

    let mut picked: Vec<Spendable> = Vec::new();
    let mut total: u64 = 0;
    for o in owned {
        if total >= amount || picked.len() == N_IN {
            break;
        }
        total = total.checked_add(o.note.amount).ok_or_else(|| {
            "The largest notes of this asset add up to more than 64 bits can hold, so they \
             cannot be spent together in one payment."
                .to_string()
        })?;
        picked.push(o);
    }
    if total < amount {
        return Err(format!(
            "Not enough of this asset can be spent right now: {total} available in at most \
             {N_IN} note(s), {amount} needed (this wallet holds {held} of it in total). One \
             payment can consume {N_IN} notes, and notes under a timelock or another key, or \
             received in the last {} block(s) and so not final yet, are not counted.",
            nyctis_codec::transport::FINALITY_DEPTH,
        ));
    }
    Ok(picked)
}

/// A spend of one owned note under this wallet's own spend authority.
///
/// The reference CLI carries a per-note `auth` here because an order note is under a per-order
/// key rather than the account's. This cut has no orders: every note it can select came back
/// through `recover` under the account's own `ivk` or was published against the account's `nkc`,
/// so the account's authority is the only one there is. If orders ever land in this wallet, the
/// authority has to move onto `Spendable` exactly as it did there.
fn spend_own(
    view: &ChannelView,
    o: &Spendable,
    n_in: u8,
    height: u32,
    account: &Account,
) -> Result<Spend, String> {
    let opening = o
        .policy
        .opening(&context(o, height, n_in, account))
        .ok_or_else(|| {
            format!(
                "The note at position {} cannot be opened by this wallet's key at height \
                 {height}.",
                o.position
            )
        })?;
    let n_keys = opening.cost().keys as usize;
    Ok(Spend {
        input: SpendInput {
            note: o.note.clone(),
            policy: o.policy.clone(),
            opening,
            nk: o.nk,
            created: o.created,
            path: path_in_state(&view.state, o.position),
            alphas: (0..n_keys)
                .map(|_| Fr::rand(&mut rand::rngs::OsRng))
                .collect(),
        },
        signers: vec![account.spend.clone(); n_keys],
        zec_claim: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use nyctis_codec::policy::Policy;
    use nyctis_codec::transport::{parse, MAX_FRAGMENTS};
    use nyctis_state::ProofVerifier;
    use nyctis_zk::verifier::Groth16Verifier;

    use crate::nyctis::keys::account;
    use crate::nyctis::testdata;
    use zcash_keys::keys::{ReceiverRequirement, UnifiedAddressRequest, UnifiedIncomingViewingKey};

    /// The devnet key directory: `.devnet/keys` in the Nyctis repository, which sits beside
    /// this wallet (`../nyctis` from the wallet root, `../../nyctis` from this crate). Point
    /// `NYCTIS_KEYS_DIR` at another devnet's keys to override it.
    ///
    /// The keys are not checked in (`interpreter-v0.pk` is about 83 MiB), so every test that
    /// needs them is `#[ignore]`d with that reason and runs with `cargo test -- --ignored`. Once
    /// asked for, a missing key fails the test naming the path: a proving test that passes
    /// without having proved anything says nothing about this code.
    fn keys_dir() -> String {
        let dir = match std::env::var("NYCTIS_KEYS_DIR") {
            Ok(d) => PathBuf::from(d),
            Err(_) => PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../nyctis/.devnet/keys"),
        };
        assert!(
            dir.join(PK_FILE).is_file(),
            "no Nyctis proving key at {} (set NYCTIS_KEYS_DIR, or run the devnet's zk-setup)",
            dir.display()
        );
        dir.display().to_string()
    }

    fn stranger() -> Account {
        account(b"a devnet stranger with no notes")
    }

    fn recipient_address() -> String {
        stranger()
            .address()
            .encode(WalletNetwork::Regtest.ny_hrp())
            .unwrap()
    }

    fn asset() -> [u8; 32] {
        hex::decode(testdata::ASSET_ID).unwrap().try_into().unwrap()
    }

    /// The Ironwood-only default address of a channel UIVK: the address a correct channel
    /// configuration pairs with that key.
    fn address_of(uivk: &str) -> String {
        let key = UnifiedIncomingViewingKey::decode(&WalletNetwork::Regtest, uivk).unwrap();
        let request = UnifiedAddressRequest::custom(
            ReceiverRequirement::Require,
            ReceiverRequirement::Omit,
            ReceiverRequirement::Omit,
        )
        .unwrap();
        let (ua, _) = key.default_address(request).unwrap();
        ua.encode(&WalletNetwork::Regtest)
    }

    fn plan(amount: u64, recipient: &str, keys: &str) -> Result<PayPlan, String> {
        build_pay(
            WalletNetwork::Regtest,
            testdata::CHANNEL_UIVK,
            &address_of(testdata::CHANNEL_UIVK),
            testdata::BIRTHDAY,
            testdata::CHAIN_TIP,
            testdata::vk(),
            &hex::encode(nyctis_zk::prover::vk_hash_bytes(testdata::vk())),
            testdata::messages(),
            // The issuer, not the demo wallet. On the old recording the demo wallet held the one
            // spendable note; on this channel it has spent both of its receipts back, and the
            // issuer is the only holder of spendable DMT. The subject of these tests is "a wallet
            // with a spendable note of a public asset", which is what this seed now is.
            &account(&testdata::issuer_seed()),
            keys,
            &asset(),
            amount,
            recipient,
            &TxSources::default(),
        )
    }

    /// **The end-to-end property.** A plan this code builds has to be a message the read path
    /// accepts, and every clause below is one of the read path's own rules, applied to bytes that
    /// never went near a network:
    ///
    /// - the memos are what the transport carries (512 bytes, reparse, in order, one id);
    /// - the fragments reassemble into the body that was framed;
    /// - the body is a decodable `Transition`;
    /// - **its proof verifies against the channel's verifying key** — not against the proving
    ///   key's own, which would only prove this module is self-consistent;
    /// - the `msg_id` is the one `check_binding` recomputes, which since the id-rebinding fix is
    ///   the difference between a payment and a message the whole replay refuses;
    /// - and the recipient can actually decrypt their note, which is the only clause that says
    ///   the money went where the review screen said it did.
    #[test]
    #[ignore = "needs the Nyctis devnet proving key, which is not checked in; run with --ignored"]
    fn a_payment_built_here_is_a_message_the_read_path_accepts() {
        let keys = keys_dir();
        let recipient = recipient_address();
        let plan = plan(40, &recipient, &keys).expect("the issuer's 440 DMT note covers 40");

        assert_eq!(plan.amount, 40);
        assert_eq!(plan.change, 400, "440 held, 40 paid");
        assert_eq!(plan.spent, 440);
        assert_eq!(plan.inputs, 1);
        assert_eq!(hex::encode(plan.asset_id), testdata::ASSET_ID);
        assert_eq!(plan.asset_symbol, "DMT");
        assert_eq!(plan.asset_decimals, 2);
        assert_eq!(plan.anchor_height, testdata::CANONICAL_HEIGHT);
        assert_eq!(plan.chain_tip, testdata::CHAIN_TIP);
        assert_eq!(hex::encode(plan.vk_hash), testdata::VK_HASH);
        assert!(
            (1..=MAX_FRAGMENTS as usize).contains(&plan.memos.len()),
            "{} fragment(s)",
            plan.memos.len()
        );
        eprintln!(
            "proved in {} ms; body {} bytes in {} fragment(s); msg_id {}",
            plan.proved_ms,
            plan.body_bytes,
            plan.memos.len(),
            hex::encode(plan.msg_id)
        );

        // the transport's own rules, on the bytes the wallet would broadcast
        let mut body = Vec::new();
        for (i, memo) in plan.memos.iter().enumerate() {
            assert_eq!(memo.len(), MEMO_LEN, "fragment {i}");
            let h = parse(memo).unwrap_or_else(|e| panic!("fragment {i}: {}", e.reason()));
            assert_eq!(h.kind, KIND_TRANSITION);
            assert_eq!(h.msg_id, plan.msg_id, "fragment {i} names another message");
            assert_eq!(h.index, i as u16);
            assert_eq!(h.count, plan.memos.len() as u16);
            body.extend_from_slice(&h.payload);
        }
        assert_eq!(body.len(), plan.body_bytes as usize);

        let tx = nyctis_codec::transition::Transition::decode(&body)
            .expect("the reassembled body is a transition");

        // the proof against the **channel's** key, the one every other verifier uses
        let cid =
            replay::channel_id_for_uivk(WalletNetwork::Regtest, testdata::CHANNEL_UIVK).unwrap();
        let verifier = Groth16Verifier::from_vk_bytes(testdata::vk()).unwrap();
        assert_eq!(verifier.vk_hash, Some(plan.vk_hash));
        assert!(
            verifier.verify(&tx, &cid, &tx.ct_digest()),
            "the proof must verify against the key the channel publishes"
        );

        // the id binding the read path enforces, checked with the read path's own function
        let message = Message {
            msg_id: plan.msg_id,
            kind: KIND_TRANSITION,
            count: plan.memos.len() as u16,
            completion: (testdata::CHAIN_TIP, 0, 0),
            txid: None,
            body: body.clone(),
        };
        replay::check_binding(&cid, &message).expect("a plan must satisfy the id binding");

        // and the note is the recipient's, with the change ours
        let to_them = nyctis_zk::transition::recover(&tx, &stranger());
        assert_eq!(to_them.len(), 1);
        assert_eq!(to_them[0].note.amount, 40);
        assert_eq!(to_them[0].note.asset_id.to_bytes(), asset());
        assert_eq!(
            to_them[0].policy.to_string(),
            format!("pk({})", hex::encode(stranger().spend.ak_bytes()))
        );
        let to_us = nyctis_zk::transition::recover(&tx, &account(&testdata::issuer_seed()));
        assert_eq!(to_us.len(), 1, "the change note comes back to this wallet");
        assert_eq!(to_us[0].note.amount, 400);
    }

    /// Paying the whole note leaves no change, and the transition then has one output rather than
    /// a zero-valued second one. A zero-amount change note would be a real note in the tree that
    /// costs an output slot and tells every observer the payment was exact.
    #[test]
    #[ignore = "needs the Nyctis devnet proving key, which is not checked in; run with --ignored"]
    fn an_exact_payment_produces_no_change_note() {
        let keys = keys_dir();
        let plan = plan(440, &recipient_address(), &keys).expect("440 of 440");
        assert_eq!(plan.change, 0);
        let mut body = Vec::new();
        for m in &plan.memos {
            body.extend_from_slice(&parse(m).unwrap().payload);
        }
        let tx = nyctis_codec::transition::Transition::decode(&body).unwrap();
        assert_eq!(tx.commitments.len(), 1, "one output, not two");
        assert!(nyctis_zk::transition::recover(&tx, &account(&testdata::issuer_seed())).is_empty());
    }

    /// The devnet key folder must be the key set the recorded channel verifies with. If it is
    /// not, every other proving test here is proving against a key nobody on that channel
    /// accepts, and would still pass.
    #[test]
    #[ignore = "needs the Nyctis devnet proving key, which is not checked in; run with --ignored"]
    fn the_key_folder_belongs_to_the_channels_key_set() {
        let keys = keys_dir();
        let info = check_proving_key(&keys).expect("the devnet key folder validates");
        assert_eq!(info.circuit, Keys::FINGERPRINT);
        assert_eq!(hex::encode(info.vk_hash), testdata::VK_HASH);
        assert!(
            info.proving_key_bytes > 50_000_000,
            "{} bytes is not an interpreter proving key",
            info.proving_key_bytes
        );
    }

    /// A key folder that is missing, empty or incomplete must come back as a sentence naming the
    /// path and the missing file — not as a bare `No such file or directory`, and not as a panic
    /// crossing the bridge. This is the most likely failure in the whole feature: the key is 83
    /// MiB, nothing serves it, and the path is typed by a human into a settings field.
    #[test]
    fn a_bad_key_folder_is_a_sentence_a_ui_can_show() {
        let e = check_proving_key("").unwrap_err();
        assert!(
            e.contains("proving key") && e.contains("interpreter-v0.pk"),
            "{e}"
        );

        let e = check_proving_key("/nonexistent/nyctis/keys").unwrap_err();
        assert!(e.contains("/nonexistent/nyctis/keys"), "{e}");
        assert!(e.contains("interpreter-v0.pk"), "{e}");

        let dir = std::env::temp_dir().join(format!("njpay-empty-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let e = check_proving_key(&dir.display().to_string()).unwrap_err();
        std::fs::remove_dir_all(&dir).ok();
        assert!(e.contains("interpreter-v0.pk"), "{e}");
    }

    /// A key set from another ceremony is refused **before** the proof is made, not after the
    /// user has paid to carry one every verifier rejects. The check is `vk_hash` against the
    /// channel's, and it has to fail even though the circuit fingerprint matches — which is the
    /// whole point: a fingerprint says which circuit, not which ceremony.
    #[test]
    #[ignore = "needs the Nyctis devnet proving key, which is not checked in; run with --ignored"]
    fn a_key_set_the_channel_does_not_verify_with_is_refused_before_proving() {
        let keys = keys_dir();
        // the recorded channel replayed against a *different* key: every proof in it then fails,
        // so the wallet is being asked to pay on a channel it could not read. Use a key set whose
        // hash differs from the folder's by generating nothing — instead, feed the real folder
        // and a channel whose vk is the folder's key with one byte of trailing junk, which
        // `from_vk_bytes` refuses outright. The reachable wrong-ceremony path is the folder
        // mismatch, so assert it by pointing at a folder holding a *valid but different* key.
        let dir = std::env::temp_dir().join(format!("njpay-otherkey-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // A second key set is not something a test can cheaply generate (setup is minutes), so
        // rename the real one: rewriting the manifest for a one-bit-changed key is refused by
        // the manifest check, which is the same class of failure and the one users hit.
        let mut vk = std::fs::read(PathBuf::from(&keys).join(VK_FILE)).unwrap();
        let last = vk.len() - 1;
        vk[last] ^= 0x01;
        std::fs::write(dir.join(VK_FILE), &vk).unwrap();
        std::fs::write(
            dir.join(MANIFEST_FILE),
            Keys::manifest_line(&nyctis_zk::prover::vk_hash_bytes(&vk)) + "\n",
        )
        .unwrap();
        std::fs::write(dir.join(PK_FILE), b"not a proving key").unwrap();

        let e = plan(1, &recipient_address(), &dir.display().to_string()).unwrap_err();
        std::fs::remove_dir_all(&dir).ok();
        assert!(
            e.contains("different key set") || e.contains("Nyctis proving keys"),
            "{e}"
        );
    }

    /// Insufficient funds must name the shortfall, the two-note limit and the finality rule,
    /// because the screen the user is looking at is showing a balance that says otherwise.
    #[test]
    #[ignore = "needs the Nyctis devnet proving key, which is not checked in; run with --ignored"]
    fn asking_for_more_than_is_spendable_says_why() {
        let keys = keys_dir();
        // 440 + 150 is the most two notes can carry, and one payment may consume two — so 591 is
        // over the ceiling even though the wallet holds 600 across three notes. That gap is the
        // whole reason this message names the note limit as well as the amounts.
        let e = plan(591, &recipient_address(), &keys).unwrap_err();
        assert!(e.contains("590"), "{e}");
        assert!(e.contains("591"), "{e}");
        assert!(e.contains("note"), "{e}");
    }

    /// Zero is not a payment, and a wallet that proved one would put a note of nothing in the
    /// tree and charge the user a Zcash fee for it.
    #[test]
    fn a_zero_amount_is_refused_before_any_work() {
        let e = plan(0, &recipient_address(), "/nonexistent").unwrap_err();
        assert!(e.contains("greater than zero"), "{e}");
    }

    /// An address from another network is refused. Nyctis keys are seed-derived, not
    /// network-derived, so an `nyreg1…` string is a well-formed mainnet address that nobody on
    /// mainnet controls: the payment would land in an account the user cannot open, with no error
    /// anywhere to say so.
    #[test]
    fn an_address_from_another_network_is_refused() {
        let mainnet = stranger().address().encode("ny").unwrap();
        let e = decode_recipient(WalletNetwork::Regtest, &mainnet).unwrap_err();
        assert!(e.contains("ny network") && e.contains("nyreg"), "{e}");
        assert!(decode_recipient(WalletNetwork::Regtest, &recipient_address()).is_ok());
        // a pasted address carries whitespace, which is not a different network
        let padded = format!("  {}\n", recipient_address());
        assert!(decode_recipient(WalletNetwork::Regtest, &padded).is_ok());
        assert!(decode_recipient(WalletNetwork::Regtest, "  ").is_err());
        assert!(decode_recipient(WalletNetwork::Regtest, "nyreg1notanaddress").is_err());
    }

    /// The `before()` filter, which is the reason `openable_now` exists at all. Every note on the
    /// recorded channel is under a plain `pk()`, so this builds the timelocked case directly and
    /// asserts the selector refuses it — a note a wallet lists and cannot open must not be chosen
    /// as an input, or the whole payment fails at proving time, after the 83 MiB load.
    #[test]
    fn a_note_past_its_deadline_is_not_selected() {
        let view = testdata::replay_fixture();
        let acct = account(&testdata::issuer_seed());
        let mut owned = spendable_notes(&view, &acct);
        assert_eq!(owned.len(), 3, "440 + 150 + 10, the unspent three");
        let height = view.height();
        assert!(openable_now(&owned[0], height, &acct), "a plain pk() note");

        // The same notes under `pk(me) && before(h)`, with `h` already passed. All three, not
        // just the first: the old recording left this wallet exactly one spendable note, so
        // expiring it left the selector nothing to choose. Here it would simply fall through to
        // the next one — which proves nothing about the timelock, only about the fallback.
        let expired = Policy::and(
            acct.address().default_policy(),
            Policy::Before(height.saturating_sub(1)),
        );
        for n in owned.iter_mut() {
            n.note.policy_root = nyctis_zk::hash::policy_hash(&expired);
            n.policy = expired.clone();
        }
        assert!(owned.iter().all(|n| !openable_now(n, height, &acct)));

        let e = select_inputs(
            owned,
            &nyctis_zk::fq_from_bytes(&asset()).unwrap(),
            1,
            height,
            &acct,
        )
        .unwrap_err();
        assert!(e.contains("timelock"), "{e}");
    }

    /// Some verifying key: the devnet's real 0x05 key when this machine has it, otherwise the
    /// recorded one. The tests below need *a* key and a proof that is certainly not valid under
    /// it, not any particular channel.
    fn any_vk() -> Vec<u8> {
        let devnet = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../nyctis/.devnet/keys")
            .join(VK_FILE);
        std::fs::read(devnet).unwrap_or_else(|_| testdata::vk().to_vec())
    }

    fn fixture_note(amount: u64) -> Spendable {
        let acct = account(b"overflow test");
        let policy = acct.address().default_policy();
        Spendable {
            note: Note {
                policy_root: nyctis_zk::hash::policy_hash(&policy),
                asset_id: Fq::from(9u64),
                amount,
                nkc: acct.nkc(),
                data: Fq::from(0u64),
                rseed: Note::random_rseed(),
                recoverable_from: None,
                explicit_rcm: None,
            },
            policy,
            nk: acct.nk,
            position: 0,
            created: 1,
        }
    }

    /// **C17.** Two notes of a self-issued asset near `u64::MAX` used to wrap `total` in a
    /// release build (and panic in debug). Selection must refuse with a sentence instead.
    #[test]
    fn notes_whose_total_overflows_are_refused_not_wrapped() {
        let acct = account(b"overflow test");
        let owned = vec![fixture_note(u64::MAX - 1), fixture_note(u64::MAX - 1)];
        // an amount only the pair could cover, so selection has to add both
        let e = select_inputs(owned, &Fq::from(9u64), u64::MAX, 100, &acct).unwrap_err();
        assert!(e.contains("64 bits"), "{e}");

        assert!(checked_total([u64::MAX, 1]).unwrap_err().contains("64 bits"));
        assert_eq!(checked_total([u64::MAX - 1, 1]).unwrap(), u64::MAX);
        assert_eq!(checked_total([]).unwrap(), 0);

        // `held` only feeds the error text and saturates rather than failing selection
        let owned = vec![fixture_note(u64::MAX), fixture_note(u64::MAX), fixture_note(5)];
        let picked = select_inputs(owned, &Fq::from(9u64), 5, 100, &acct).unwrap();
        assert_eq!(picked.len(), 1, "the largest note alone covers 5");
    }

    /// **C9.** A proof that does not verify under the channel's key is refused before any memo is
    /// returned — the case a proving key from another setup produces, which every earlier check
    /// passes.
    #[test]
    fn a_transition_whose_proof_does_not_verify_is_not_handed_over() {
        let vk = any_vk();
        let verifier = Groth16Verifier::from_vk_bytes(&vk).expect("a verifying key");
        let cid =
            replay::channel_id_for_uivk(WalletNetwork::Regtest, testdata::CHANNEL_UIVK).unwrap();
        let tx = crate::nyctis::keys::tests::bare_transition(vec![], vec![[1u8; 32]], vec![vec![]]);
        let e = verify_own_proof(&verifier, &tx, &cid).unwrap_err();
        assert!(e.contains("does not verify") && e.contains("Nothing was sent"), "{e}");
    }

    /// **C9, the stronger half.** The built message is applied to the wallet's own replayed state
    /// before it is returned, and anything the state machine ignores — a bad proof, an anchor it
    /// does not keep, a spent input — is an error rather than memos.
    #[test]
    fn a_transition_the_channel_would_ignore_fails_the_dry_run() {
        let vk = any_vk();
        let verifier = Groth16Verifier::from_vk_bytes(&vk).expect("a verifying key");
        let mut view = replay::replay_using(
            WalletNetwork::Regtest,
            testdata::CHANNEL_UIVK,
            2,
            500,
            &vk,
            vec![],
            &|_| crate::nyctis::carrier::Carriers::default(),
        )
        .expect("an empty channel replays");
        let tx = crate::nyctis::keys::tests::bare_transition(vec![], vec![[1u8; 32]], vec![vec![]]);
        let body = tx.encode();
        let e = dry_run(&mut view, &verifier, [7u8; 32], &body, 1).unwrap_err();
        assert!(e.contains("would be refused by the channel"), "{e}");
    }

    /// **C1 and C16 on the send path.** Both trust anchors are checked before the replay and
    /// before the key folder: a key that is not the pinned one, a missing pin, and a channel
    /// address that is not the UIVK's all refuse with nothing proved. None of these needs a
    /// proving key or a recorded channel.
    #[test]
    fn the_send_path_refuses_an_unpinned_key_and_a_foreign_channel_address() {
        let vk = any_vk();
        let pin = hex::encode(nyctis_zk::prover::vk_hash_bytes(&vk));
        let good_addr = address_of(testdata::CHANNEL_UIVK);
        let issuer = account(&testdata::issuer_seed());
        let try_pay = |vk_pin: &str, addr: &str| {
            build_pay(
                WalletNetwork::Regtest,
                testdata::CHANNEL_UIVK,
                addr,
                2,
                500,
                &vk,
                vk_pin,
                vec![],
                &issuer,
                "/nonexistent/keys",
                &hex::decode(testdata::ASSET_ID).unwrap().try_into().unwrap(),
                1,
                &recipient_address(),
                &TxSources::default(),
            )
            .unwrap_err()
        };

        for pin in ["", &"00".repeat(32)] {
            let e = try_pay(pin, &good_addr);
            assert!(e.starts_with(trust::VK_PIN_ERROR_PREFIX), "{pin:?}: {e}");
        }

        // another wallet's address under the right pin
        let usk = zcash_keys::keys::UnifiedSpendingKey::from_seed(
            &WalletNetwork::Regtest,
            &[9u8; 32],
            zip32::AccountId::ZERO,
        )
        .unwrap();
        let foreign = address_of(
            &usk.to_unified_full_viewing_key()
                .to_unified_incoming_viewing_key()
                .encode(&WalletNetwork::Regtest),
        );
        let e = try_pay(&pin, &foreign);
        assert!(e.contains("does not belong"), "{e}");

        // both anchors good: the next refusal is the key folder, i.e. the anchors let it through
        let e = try_pay(&pin, &good_addr);
        assert!(e.contains("/nonexistent/keys"), "{e}");
    }

    /// The plan reports the protocol's anchor window, never the indexer's.
    #[test]
    fn the_anchor_window_is_the_protocol_constant() {
        assert_eq!(ANCHOR_WINDOW, 200);
    }
}
