//! The recorded regtest devnet channel the Nightjar tests replay against.
//!
//! A recording rather than a synthesised fixture, because the property worth testing is not "this
//! code agrees with itself" — it is "this code reaches the same state root as the reference
//! implementation, from bytes the reference implementation produced". Every proof in here was
//! made by the Nightjar CLI against the devnet's own verifying key, which is checked in beside
//! it, and the roots asserted against are the ones the devnet indexer published at the canonical
//! height recorded in the header.
//!
//! # Why this recording was remade on 22 September 2026
//!
//! The recording this one replaces was taken against circuit `0x03`. When `CIRCUIT_VERSION`
//! reached `0x04` it did not merely go stale: it became **unverifiable**. The circuit version is
//! a field of every transition body (`body[1]`), the codec states plainly that versions are never
//! reused and that there is no overlap window, and no verifier holds a `0x03` key any more. So
//! the proofs inside that recording could not be re-checked under any key that exists, and the
//! fix could not be a header edit — swapping in the current fingerprint and verifying key would
//! only have turned `parse: invalid:circuit_version` into `proof rejected` while leaving the
//! version guard below green over dead proofs, which is the exact failure that guard exists to
//! catch. The only repair for a recording whose circuit died is to record the channel again.
//!
//! # What this recording covers that the old one could not
//!
//! The old recording predated public asset metadata, NFT collections and ZEC claims, and carried
//! a single asset. This one is taken from the devnet built by `devnet-e2e.sh`, `devnet-assets.sh`,
//! `devnet-programs.sh` and `devnet-testassets.sh` against one channel, so it carries all of it:
//!
//! * **Every outcome kind**, which is what makes it a conformance recording: 42 `applied`,
//!   12 `named`, 5 `published` and 6 `ignored`, and the ignored six are the ones whose *reasons*
//!   are worth pinning — a stale circuit version, three rejected proofs, a supply cap, and a ZEC
//!   claim whose carrying transaction never paid.
//! * **Public assets with real metadata**: "Devnet Mint" (DMT, 2 decimals, capped) as before, and
//!   now "NightCash" (NC, 8 decimals, capped at 10^16) with a resolvable metadata URI.
//! * **An NFT collection**: ten single-supply "Phases of One Night" pieces under one
//!   `collection_id`, each named by its own `ASSET` message.
//! * **Two ZEC claims of 50 000 000 zatoshi to the same account, one paid and one not** — the
//!   pair the claim oracle is held to. Both carrying transactions are recorded under `raw_txs`,
//!   so [`replay_fixture`] exercises the *verified* path rather than skipping it. This is why
//!   this module now binds carriers at all; see [`recorded_carriers`].
//!
//! The recording is **not pruned**. The old one kept 12 of 350 messages and needed an argument
//! about why dropping ignored messages was sound for the state root; this channel carries 65
//! messages in 155 KiB, so it is recorded whole and needs no such argument.
//!
//! # Regenerating
//!
//! With the devnet up (`infra/README.md` in the Nightjar repo), and all four devnet scripts
//! pointed at **one** channel directory — `devnet-programs.sh` documents the
//! `NIGHTJAR_PROGRAMS_DIR` override that exists for exactly this, because a conformance recording
//! needs one channel carrying every outcome kind:
//!
//! * `/api/messages?body=1&limit=200` paged with `before=` — keep each message's `fragments`, it
//!   is hashed into `msg_id` and the replay refuses a message whose id its own body does not
//!   produce.
//! * `/api/tx/{txid}` for each message whose `detail.zec_claims` is non-empty, stored under
//!   `raw_txs` keyed by `msg_id`. Without those the claims cannot be checked and the recording
//!   asserts the *unverifiable* path instead of the verified one.
//! * `/api/vk` for `devnet-vk.bin` (the endpoint returns JSON with the key as hex under `vk`, not
//!   raw bytes). Record `circuit` **without** the `;vk_hash=` suffix the indexer appends:
//!   [`Keys::FINGERPRINT`](nightjar_zk::prover::Keys::FINGERPRINT) carries no vk_hash, and the
//!   guard below compares the two directly.
//! * `/api/status` for the `chain_tip`/`canonical_height`/roots block, and
//!   `/api/notes?as_of=`, `/api/nullifiers?as_of=`, `/api/anchors?as_of=&live=1` for the counts
//!   **at the canonical height** — the un-`as_of` lists serve the preview state, which is a
//!   different and unpublishable answer.
//!
//! The header's roots and the messages must come from the same poll or the fixture asserts a root
//! the messages cannot produce.

#![cfg(test)]

use serde_json::Value;

use crate::nightjar::carrier::{Carrier, Carriers, TxSources};
use crate::nightjar::replay::{replay, replay_using, ChannelView, Message};
use crate::wallet::network::WalletNetwork;
use std::sync::Arc;

const FIXTURE: &str = include_str!("../../tests/fixtures/nightjar/devnet-channel.json");
const VK: &[u8] = include_bytes!("../../tests/fixtures/nightjar/devnet-vk.bin");

pub const CHANNEL_UIVK: &str = "uivkregtest1dvlwf76lznrp8pqpdt5mzfewm3znm5mvr4f87s4xffp8r5575vevcyrmdjf2mk6h0prkrlphrtzrs00gdzv856aa04lk9g0nazrca9v7fhkdv525kvrv2m28yjac92fmvcxpuzadm82zhfkzgl82mzlcfpww249nfk5wmalneptxu7xk7p89ah26lhudne2sc872yejv4s2pt57erwgu078saevaug897e334uqrf0xhgdqgwsy";
pub const CHANNEL_ID: &str = "3d209fc7f081aef07b1aad9b2d1addfcac940afe6aab0c1dc98a8fd818e623f3";
pub const BIRTHDAY: u32 = 2;

/// `/api/status` at the poll the recording was taken from.
pub const CHAIN_TIP: u32 = 842;
pub const CANONICAL_HEIGHT: u32 = 832;
pub const STATE_ROOT: &str = "c67b838d82e6ee12724b5a868373f53029058a5cc62fa5e9e49d73d76d368054";
pub const TREE_ROOT: &str = "28693d9f2f54117b7ee90f82bdec52d7b83289bb2d6483fe0e9b619b2ffc080f";
pub const NOTE_COUNT: u64 = 51;
pub const NULLIFIER_COUNT: usize = 25;
/// One. Every anchor but the newest is more than `ANCHOR_WINDOW` behind [`CANONICAL_HEIGHT`], so
/// the set has collapsed — see [`LAST_MESSAGE_HEIGHT`].
pub const ANCHOR_COUNT: usize = 1;

/// The height of the last message on the channel, and **the reason this recording was taken at a
/// tip 211 blocks past it**.
///
/// The channel has been silent since this block, and the gap to [`CANONICAL_HEIGHT`] is more than
/// `ANCHOR_WINDOW` (200). That gap is the only shape in which the anchor prune is observable:
/// past the window the anchor set collapses to one and the state root moves with **no message
/// having landed**, so an implementation that folds the anchor set at the last message's height
/// instead of at the canonical height reports a root nobody else computes, with every proof
/// verified and no error raised.
///
/// The devnet was mined 210 empty blocks specifically to create it. Recorded where the channel
/// stood — canonical 622, one block past the last message — the two tips were indistinguishable:
/// `/api/state_root/621` and `/api/state_root/622` returned the *same* root, and the channel's
/// longest quiet stretch anywhere in its 507 blocks of message history is 25, so no earlier
/// `as_of` height reproduced it either. This is the whole value of the tip this recording carries,
/// and it is what `replay::tests::a_quiet_channel_prunes_its_anchors_at_the_canonical_height`
/// rests on.
pub const LAST_MESSAGE_HEIGHT: u32 = 621;
/// The root the same messages produce at a canonical height equal to [`LAST_MESSAGE_HEIGHT`] —
/// every anchor still live, none yet stale. It differs from [`STATE_ROOT`], and that difference
/// *is* the prune: same messages, same tree, a smaller anchor set.
pub const STATE_ROOT_AT_LAST_MESSAGE: &str =
    "d90117d6c299eca93496a75e0fb276fe2330952b7a3997f3f21c28e2c6c9f3ce";

/// What the indexer counted for this channel at [`CANONICAL_HEIGHT`]: 42 `applied`, 12 `named`
/// and 5 `published` make [`ACCEPTED`], against 6 `ignored`. `ChannelView::accepted` must equal
/// the first and `ignored` the second, message for message.
pub const MESSAGE_COUNT: usize = 65;
pub const ACCEPTED: u32 = 59;
pub const IGNORED: u32 = 6;

/// The `vk_hash` the indexer advertises for the key checked in beside this recording. What a
/// caller pins; `NjView::vk_hash` reports it. This is also the key set `.devnet/keys` holds, which
/// is what lets `pay`'s tests prove against the live keys and be accepted by this channel.
pub const VK_HASH: &str = "1fb71c4d52a8e324c34e868ae7e510c5b0751d19c35ffd9c746b2955d0f58df3";

/// The counterparty: `.devnet/assets/bob`, the wallet the issuer paid twice.
///
/// **This role changed shape in the `0x04` re-record and the tests say so.** On the old devnet the
/// demo wallet was a pure recipient — one note, never spent — so a test could assert "the demo
/// seed owns *the* note" and another could use `spent_by.is_none()` across all of its notes as a
/// stand-in for "this wallet authored no input of this message". On this channel bob receives
/// twice and *sends both back*, so neither global shortcut holds. The per-message invariants they
/// were standing in for are asserted directly instead; see `owned::tests::the_two_sides_of_one_payment_agree`.
pub const DEMO_SEED_HEX: &str = "1aa3a384b2c6a821af33f4d58691b9d03cc57976bc77aae6eff39ec41b5980d0";
pub const DEMO_AK: &str = "4c6d8eeb0b677ce1df25581e5362168a7b30db9cb5bcc2cf5a17fb669fb91005";

/// The other end of the recording: `.devnet/assets/alice`, the wallet that **issued** DMT and then
/// spent it — and, on this channel, the only wallet holding spendable DMT, which is why `pay`'s
/// tests build their payments from this seed rather than the demo one.
pub const ISSUER_SEED_HEX: &str = "74bd6b35475318718b5afde99b099e16e8861208c74ca79a1c6d3bd695e179cc";

/// The issuance that created the issuer's first note: 600 units, no inputs, one output.
pub const ISSUANCE_MSG: &str = "4ef6106e5dd16d850650a38642a51430625ffd0e224cf7b3fe47d2bc65f1a04f";
pub const ISSUANCE_HEIGHT: u32 = 152;
/// The issuer's first payment: it consumed that 600-unit note and returned 450 as change, so 150
/// left. One input, two outputs.
pub const FIRST_SEND_MSG: &str = "854049e3589e6dca5be82a931dc8dc143e5361b840f6f2dc010cc97043cedb8b";
pub const FIRST_SEND_HEIGHT: u32 = 174;
pub const FIRST_SEND_AMOUNT: u64 = 150;
/// The payment whose two halves are both in the recording: the issuer spent 450 and kept 440, and
/// the 10 that left is the demo wallet's second note — the one carrying a `before()` clause.
pub const SEND_TO_DEMO_MSG: &str = "ed3771b193dd500aab98e2bbcf7490809ecd513971485347244dbce33def17e9";
pub const SEND_TO_DEMO_HEIGHT: u32 = 196;
/// The message the demo wallet spent that note with, which is what makes it a *spent* receipt —
/// coverage the old recording, whose demo note was never spent, could not offer.
pub const DEMO_SPENDS_IT_MSG: &str =
    "3be73a49c8f9ed9fedbcc4daaf5c9753f5cc3733663ebfa69b11a2b0aaf9a31d";
pub const DEMO_SPENDS_IT_HEIGHT: u32 = 218;
/// The demo wallet's note from [`SEND_TO_DEMO_MSG`], and its policy. The `before()` clause is new
/// coverage: every note on the old recording was under a plain `pk()`.
pub const DEMO_NOTE_AMOUNT: u64 = 10;
pub const DEMO_NOTE_DEADLINE: u32 = 250;

pub fn issuer_seed() -> Vec<u8> {
    hex::decode(ISSUER_SEED_HEX).expect("issuer seed is hex")
}

/// "Devnet Mint" (DMT, 2 decimals), as `/api/assets` reports it. `issued` is below `max_supply`
/// because one further issuance was refused for exceeding the cap — that refusal is one of the
/// six ignored messages in the recording.
pub const ASSET_ID: &str = "86d7bc9a039aeaa46b2ce8315542e3b0b53ad0f8f070db2c874bd19f82f10c09";
pub const ASSET_ISSUED: u64 = 600;
pub const ASSET_MAX_SUPPLY: u64 = 1_000;
pub const ASSET_COLLECTION_ID: &str =
    "3742da53e1b1dfa4376356b985c8c8eb310d56072ba306aa4e6aa0657deff203";
pub const ASSET_URI: &str = "https://example.invalid/dmt/";

/// What the **fail-closed** replay produces: the path a wallet with no Zcash transaction source
/// is on, and the only one reachable across the FRB boundary, whose `NjZecSources` can name a
/// wallet database or a lightwalletd but cannot be handed a recording.
///
/// The divergence is not small, and that is the point. Refusing the paid claim at
/// [`PAID_CLAIM_HEIGHT`] orphans every anchor after it, so 11 of the 65 messages apply instead of
/// 59 and both roots move. A wallet that cannot check a claim does not quietly get a slightly
/// different answer — it gets a visibly crippled channel, which is the correct and loud failure.
pub const STATE_ROOT_BLIND: &str =
    "47928be0133551cd67a4957be492c796a19279883d330ba1935e9b11084694ef";
pub const TREE_ROOT_BLIND: &str =
    "07a9a3cf7576b11cdf3324e0fdf6b23bdf374e2ea222d9efc923936ea2731110";
pub const ACCEPTED_BLIND: u32 = 11;
pub const IGNORED_BLIND: u32 = 54;

/// How many assets `owned::asset_summaries` lists for this channel: the 12 the channel has
/// publicly issued (DMT, NightCash and the ten NFT pieces). The two further ids `/api/assets`
/// reports are known only from their orders, never publicly issued, so they are not in
/// `State::issued()` and appear only for a wallet holding a note of them.
pub const CHANNEL_ASSETS: usize = 12;

/// "NightCash" (NC, 8 decimals), the asset the old recording had no analogue for: a public
/// fungible token with a resolvable metadata URI.
pub const NC_ASSET_ID: &str = "1c9339156f2a6402a51a423f95a4afcfb54335c8505b08bb5c3c970e47cdee05";
pub const NC_ISSUED: u64 = 100_000_000_000_000;
pub const NC_MAX_SUPPLY: u64 = 10_000_000_000_000_000;
pub const NC_URI: &str = "https://raw.githubusercontent.com/micovi/nightjar-assets/main/nc.json";

/// The "Phases of One Night" NFT collection: ten pieces, each `issued = max_supply = 1`.
pub const PON_COLLECTION_ID: &str =
    "c3d9066bfe739238bdf9aa2b3b325eaf9bbd7e16e8a767aac9f0cac0697b5004";
pub const PON_PIECES: usize = 10;

/// Every piece of that collection as `(index, asset_id)`, in index order.
///
/// Recorded from the devnet indexer's `/api/assets` at tip 842 — the same source the fixture
/// beside it was recorded from, and deliberately a *second* reading of it. `index` is hashed
/// into `asset_id` through `terms` (`spec/note-format-v0.md` section 8) and the replay verifies
/// the Groth16 proof that says so, so a pairing here that disagreed with the one the replay
/// derives would mean the wire field and the proven field had come apart. The pairing is what
/// resolves `{index}` in a collection document's `item.image`, so it is the one table in this
/// file whose rows decide which picture is drawn for which asset.
pub const PON_MEMBERS: [(u32, &str); PON_PIECES] = [
    (0, "85544f0793d86b23bebafbd382cc255a4815e512b3b8110721a80a1620eebd0f"),
    (1, "884c02bccca7d5349d90573b27987015abea06d57dc4b80f10ab70612859da01"),
    (2, "7b6bcea338b3cd48e57892049b72288fc98ddcdde6e333110f7d6c714e2c0c00"),
    (3, "f114349ee3b5d5054e99e17f4a1c2bccfa417e9d31edbdd1eeec24f12e00340e"),
    (4, "ee76f4ade2a79cae1f0ad661082d410163f31dadef5d7fe0c03d0538cfebb811"),
    (5, "112e167da6935691dae8bb21b57ffcf50e148e9051c269764c01210258700404"),
    (6, "9abad2a736aeba75ab8e09e83b412b602840ed0b57c95830c3338c613fa17f03"),
    (7, "d96a1518235237504fc30f8ba49949efeec00e29c072126e9546f683a8550c00"),
    (8, "0d0c434c003ae2915c8bffb4cda172eff17dae3c7444e46b4b59b177fbbec200"),
    (9, "03a5321feb32503f8e7a4922650cd1fa16888c6f3d769852e86d6d1eade0750a"),
];

/// The `uri` all ten pieces carry — one shared collection document
/// (`spec/asset-collection-v0.md` section 2), not ten per-asset ones.
pub const PON_URI: &str = "https://raw.githubusercontent.com/micovi/nightjar-assets/main/pon/c.json";

/// The paid ZEC claim and the unpaid one, both 50 000 000 zatoshi to the same account. Same
/// amount, same payee, eleven blocks apart; the only difference is whether the Zcash transaction
/// carrying the message actually sent the money.
pub const PAID_CLAIM_HEIGHT: u32 = 275;
pub const UNPAID_CLAIM_HEIGHT: u32 = 264;
pub const CLAIM_ZATOSHI: u64 = 50_000_000;

pub fn demo_seed() -> Vec<u8> {
    hex::decode(DEMO_SEED_HEX).expect("demo seed is hex")
}

pub fn vk() -> &'static [u8] {
    VK
}

fn fixture() -> Value {
    serde_json::from_str(FIXTURE).expect("the recorded channel is valid JSON")
}

/// The recorded messages, in the shape the FRB layer hands to `replay`.
pub fn messages() -> Vec<Message> {
    messages_of(&fixture())
}

/// Shared by this recording and the `claims` one below: both are the same JSON shape.
fn messages_of(f: &Value) -> Vec<Message> {
    f["messages"]
        .as_array()
        .expect("messages")
        .iter()
        .map(|m| {
            let id: [u8; 32] = hex::decode(m["msg_id"].as_str().unwrap())
                .unwrap()
                .try_into()
                .unwrap();
            Message {
                msg_id: id,
                kind: m["kind"].as_u64().unwrap() as u8,
                // The indexer's `fragments`, recorded verbatim. It is hashed into `msg_id`, so a
                // fixture that guessed it from the body length would be testing the guess.
                count: m["fragments"].as_u64().unwrap() as u16,
                completion: (
                    m["height"].as_u64().unwrap() as u32,
                    m["tx_index"].as_u64().unwrap() as u32,
                    m["action_index"].as_u64().unwrap() as u32,
                ),
                txid: txid_of(m),
                body: hex::decode(m["body"].as_str().unwrap()).unwrap(),
            }
        })
        .collect()
}

/// The outcome the devnet indexer recorded for each message, so a test can assert that this
/// wallet agreed with it message for message rather than only on the final root.
pub fn recorded_outcomes() -> Vec<(String, Option<String>)> {
    outcomes_of(&fixture())
}

fn outcomes_of(f: &Value) -> Vec<(String, Option<String>)> {
    f["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| {
            (
                m["outcome"].as_str().unwrap().to_string(),
                m["reason"].as_str().map(str::to_string),
            )
        })
        .collect()
}

/// The recorded carrying transaction of a claim-carrying message, or `None` for the messages that
/// make no claim and need none.
pub fn raw_tx_for(msg_id: &[u8; 32]) -> Option<Vec<u8>> {
    raw_tx_in(&fixture(), msg_id)
}

fn raw_tx_in(f: &Value, msg_id: &[u8; 32]) -> Option<Vec<u8>> {
    hex::decode(f["raw_txs"].get(hex::encode(msg_id))?.as_str()?).ok()
}

/// A carrying-transaction lookup that answers out of a recording instead of off the network,
/// through **the same [`crate::nightjar::carrier::bind`]** the live path uses.
///
/// Binding here rather than trusting the recording is the point: if `bind` ever stopped proving
/// that a transaction carried its message, the recorded pairs would stop binding, the claims
/// would go unchecked, and the state root would move.
///
/// Shared by both recordings — this one needs it now that it carries claims of its own.
fn carriers_from(f: &Value, uivk: &str, wanted: &[&Message]) -> Carriers {
    let network = WalletNetwork::Regtest;
    let key = zcash_keys::keys::UnifiedIncomingViewingKey::decode(&network, uivk)
        .expect("the recorded channel UIVK decodes");
    let ivk = orchard::keys::PreparedIncomingViewingKey::new(
        &key.orchard().clone().expect("Ironwood component"),
    );
    let mut out = Carriers::default();
    for m in wanted {
        match raw_tx_in(f, &m.msg_id) {
            Some(raw) => match crate::nightjar::carrier::bind(&network, &ivk, &raw, m) {
                Ok(fragments) => {
                    out.found.insert(
                        m.msg_id,
                        Carrier {
                            raw: Arc::new(raw),
                            fragments,
                            source: "recording",
                        },
                    );
                }
                Err(why) => {
                    out.failed.insert(m.msg_id, why);
                }
            },
            None => {
                out.failed
                    .insert(m.msg_id, "not in the recording".to_string());
            }
        }
    }
    out
}

pub fn recorded_carriers(wanted: &[&Message]) -> Carriers {
    carriers_from(&fixture(), CHANNEL_UIVK, wanted)
}

/// Replay the recording with the real Poseidon hasher and a real Groth16 verifier, at the tip it
/// was recorded at, **with the recorded carrying transactions in hand**.
///
/// The old recording carried no ZEC claim and so passed `TxSources::default()`. This one carries
/// two, and the paid one only applies if its carrying transaction is there to prove the payment —
/// so replaying blind would miss an `applied` message and land on a different state root. See
/// [`replay_blind`] for that path, which is a real one but a different test.
pub fn replay_fixture() -> ChannelView {
    replay_using(
        WalletNetwork::Regtest,
        CHANNEL_UIVK,
        BIRTHDAY,
        CHAIN_TIP,
        VK,
        messages(),
        &recorded_carriers,
    )
    .expect("the recorded channel replays")
}

/// Replay the same channel with **nothing** to look at — the fail-closed path a wallet with no
/// lightwalletd and no synced database is on. The paid claim is refused for want of evidence, so
/// this lands on a different root by construction.
pub fn replay_blind() -> ChannelView {
    replay(
        WalletNetwork::Regtest,
        CHANNEL_UIVK,
        BIRTHDAY,
        CHAIN_TIP,
        VK,
        messages(),
        &TxSources::default(),
    )
    .expect("a channel whose claims cannot be checked still replays")
}

/// The txid a recorded message names, in **internal** byte order, or `None` when the recording
/// predates the field. Display-order hex on the wire, reversed here, exactly as
/// `api::nightjar::decode_message` does it.
fn txid_of(m: &Value) -> Option<[u8; 32]> {
    let hex_txid = m["txid"].as_str()?;
    let mut raw: [u8; 32] = hex::decode(hex_txid).ok()?.try_into().ok()?;
    raw.reverse();
    Some(raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The fixture's own header must agree with the constants the tests assert against; a
    /// regenerated recording that silently changed channel, birthday or tip would otherwise make
    /// every other test in this module assert against a state nobody published.
    #[test]
    fn the_recording_describes_the_channel_the_constants_name() {
        let f = fixture();
        assert_eq!(f["network"].as_str().unwrap(), "regtest");
        assert_eq!(f["channel_uivk"].as_str().unwrap(), CHANNEL_UIVK);
        assert_eq!(f["channel_id"].as_str().unwrap(), CHANNEL_ID);
        assert_eq!(f["birthday"].as_u64().unwrap() as u32, BIRTHDAY);
        assert_eq!(f["chain_tip"].as_u64().unwrap() as u32, CHAIN_TIP);
        assert_eq!(
            f["canonical_height"].as_u64().unwrap() as u32,
            CANONICAL_HEIGHT
        );
        assert_eq!(f["state_root"].as_str().unwrap(), STATE_ROOT);
        assert_eq!(f["tree_root"].as_str().unwrap(), TREE_ROOT);
        assert_eq!(f["notes"].as_u64().unwrap(), NOTE_COUNT);
        assert_eq!(f["nullifiers"].as_u64().unwrap() as usize, NULLIFIER_COUNT);
        assert_eq!(f["anchors"].as_u64().unwrap() as usize, ANCHOR_COUNT);
        assert_eq!(f["vk_hash"].as_str().unwrap(), VK_HASH);
        let last = f["messages"].as_array().unwrap().last().unwrap();
        assert_eq!(last["height"].as_u64().unwrap() as u32, LAST_MESSAGE_HEIGHT);
    }

    /// Every recorded message must carry the `fragments` the indexer served, and its `msg_id`
    /// must be the hash of its own body under that count. Without this the recording could drift
    /// into a shape the live channel never produced, and every binding test would then be
    /// asserting against a fixture the protocol would have refused.
    #[test]
    fn every_recorded_message_id_is_the_hash_of_its_own_body() {
        let cid: [u8; 32] = hex::decode(CHANNEL_ID).unwrap().try_into().unwrap();
        let messages = messages();
        assert_eq!(messages.len(), MESSAGE_COUNT);
        for m in &messages {
            assert!(m.count >= 1, "fragments must be present and non-zero");
            assert_eq!(
                hex::encode(m.expected_id(&cid)),
                hex::encode(m.msg_id),
                "message {} does not hash to its own id",
                hex::encode(m.msg_id)
            );
        }
    }

    /// The verifying key beside the recording must be the one the indexer advertised, or the
    /// proofs in the recording are being checked against a key from another ceremony and the
    /// replay proves nothing. `vk_hash` is what identifies a key; the circuit fingerprint only
    /// says which circuit shape it was made for.
    ///
    /// **This is the guard that caught the `0x03` recording**, and it is why that recording was
    /// remade rather than re-headed: it compares the fixture's own `circuit` string against the
    /// fingerprint the linked circuit actually has, so a recording whose proofs belong to a dead
    /// circuit cannot be made to look current by editing its header.
    #[test]
    fn the_verifying_key_is_the_one_the_indexer_published() {
        let f = fixture();
        assert_eq!(
            hex::encode(nightjar_zk::prover::vk_hash_bytes(VK)),
            f["vk_hash"].as_str().unwrap()
        );
        assert_eq!(
            f["circuit"].as_str().unwrap(),
            nightjar_zk::prover::Keys::FINGERPRINT
        );
    }

    /// Message for message, not just at the end: this wallet must reach the same verdict on
    /// every recorded message as the reference verifier did, with the same reason string. An
    /// agreement on the final root alone would not catch a message accepted here and rejected
    /// there whose effects happened to cancel.
    #[test]
    fn every_message_gets_the_verdict_the_reference_verifier_gave_it() {
        let view = replay_fixture();
        let recorded = recorded_outcomes();
        assert_eq!(view.outcomes.len(), recorded.len());
        for (got, (outcome, reason)) in view.outcomes.iter().zip(recorded) {
            let want_accepted = outcome != "ignored";
            assert_eq!(
                got.accepted,
                want_accepted,
                "{} recorded as {outcome}, got {:?}",
                hex::encode(got.msg_id),
                got.reason
            );
            if let Some(reason) = reason {
                assert_eq!(got.reason, reason, "message {}", hex::encode(got.msg_id));
            }
        }
        assert_eq!(view.accepted(), ACCEPTED);
        assert_eq!(view.ignored(), IGNORED);
    }

    /// The recording carries both halves of the claim pair, and the *only* difference between
    /// them is whether the carrying transaction paid. Recorded here so that a regenerated
    /// fixture that lost one of them fails loudly instead of quietly testing half the oracle.
    #[test]
    fn the_recording_carries_both_halves_of_the_claim_pair() {
        let f = fixture();
        let claims: Vec<(u32, &str)> = f["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|m| f["raw_txs"].get(m["msg_id"].as_str().unwrap()).is_some())
            .map(|m| {
                (
                    m["height"].as_u64().unwrap() as u32,
                    m["outcome"].as_str().unwrap(),
                )
            })
            .collect();
        assert_eq!(
            claims,
            vec![(UNPAID_CLAIM_HEIGHT, "ignored"), (PAID_CLAIM_HEIGHT, "applied")],
            "one paid claim and one unpaid, each with its carrying transaction recorded"
        );
        assert_eq!(
            f["claim_zatoshi"].as_str().unwrap().parse::<u64>().unwrap(),
            CLAIM_ZATOSHI
        );
    }
}
/// The **earlier** recording of the *same* channel, taken at tip 433 — before
/// `devnet-testassets.sh` added NightCash and the NFT collection, and 199 blocks before the
/// recording above.
///
/// Since the `0x04` re-record these two are the same channel at two different heights, which they
/// were not before: the recording above used to be a different devnet entirely. This one is kept
/// because it pins things the later one cannot restate for itself — the *divergence* between the
/// blind and the verified replay at a height where the claim pair is the newest thing on the
/// channel, and a second, independent state root for the same message prefix.
///
/// **This is the acceptance test for `nightjar::zec` being a faithful port of the scanner's
/// `PaidClaims`.** The port cannot be checked by construction — `nightjar-scanner` is not
/// linkable here — so it is checked by outcome: every one of these 31 messages must get the
/// verdict the indexer recorded for it, and the replay must land on the `state_root` and
/// `tree_root` the indexer published. Before the oracle existed the wallet accepted 11 of them
/// against the indexer's 25, and diverged on both roots.
///
/// Regenerate exactly as the recording above, including `/api/tx/{txid}` for each message whose
/// `detail.zec_claims` is non-empty, stored under `raw_txs` keyed by `msg_id`.
pub mod claims {
    use super::*;

    const FIXTURE: &str =
        include_str!("../../tests/fixtures/nightjar/devnet-claims-channel.json");
    const VK: &[u8] = include_bytes!("../../tests/fixtures/nightjar/devnet-claims-vk.bin");

    pub const CHANNEL_UIVK: &str = "uivkregtest1dvlwf76lznrp8pqpdt5mzfewm3znm5mvr4f87s4xffp8r5575vevcyrmdjf2mk6h0prkrlphrtzrs00gdzv856aa04lk9g0nazrca9v7fhkdv525kvrv2m28yjac92fmvcxpuzadm82zhfkzgl82mzlcfpww249nfk5wmalneptxu7xk7p89ah26lhudne2sc872yejv4s2pt57erwgu078saevaug897e334uqrf0xhgdqgwsy";
    pub const CHANNEL_ID: &str =
        "3d209fc7f081aef07b1aad9b2d1addfcac940afe6aab0c1dc98a8fd818e623f3";
    pub const BIRTHDAY: u32 = 2;
    pub const CHAIN_TIP: u32 = 433;
    pub const CANONICAL_HEIGHT: u32 = 423;

    /// The two numbers the indexer publishes for this channel at [`CANONICAL_HEIGHT`], and the
    /// two this wallet has to reach. They are the acceptance test and nothing weaker stands in
    /// for them: agreeing on the message count while disagreeing on the root would mean the
    /// wallet applied the same messages to a different tree.
    pub const STATE_ROOT: &str =
        "3dca033cc05a7b3b4c55d7be0246312937e60c474065c5fed065f0d2f7e20bd8";
    pub const TREE_ROOT: &str = "47c89db7e8477c48a317339c7f5341c3f7cf5d8793abfc3ac21c34377dce9a07";

    /// `applied + published + named` as the indexer counts them: what `ChannelView::accepted`
    /// must equal.
    pub const ACCEPTED: u32 = 25;
    pub const IGNORED: u32 = 6;
    pub const MESSAGE_COUNT: usize = 31;

    /// The paid claim and the unpaid one, both 50 000 000 zatoshi to the same account.
    ///
    /// Same amount, same payee, eleven blocks apart, and the *only* difference is whether the
    /// Zcash transaction carrying the message actually sent the money — which is the one thing a
    /// wallet without an oracle cannot see, and the reason both used to be refused.
    pub const PAID_CLAIM_HEIGHT: u32 = 275;
    pub const UNPAID_CLAIM_HEIGHT: u32 = 264;
    pub const CLAIM_ZATOSHI: u64 = 50_000_000;

    pub fn vk() -> &'static [u8] {
        VK
    }

    fn fixture() -> Value {
        serde_json::from_str(FIXTURE).expect("the claims recording is valid JSON")
    }

    /// The ZIP 316 payload the claims name, as the indexer decoded it out of the transition body.
    pub fn claim_uivk_payload() -> Vec<u8> {
        hex::decode(fixture()["claim_uivk_hex"].as_str().expect("claim_uivk_hex"))
            .expect("claim uivk is hex")
    }

    pub fn messages() -> Vec<Message> {
        fixture()["messages"]
            .as_array()
            .expect("messages")
            .iter()
            .map(|m| {
                let id: [u8; 32] = hex::decode(m["msg_id"].as_str().unwrap())
                    .unwrap()
                    .try_into()
                    .unwrap();
                Message {
                    msg_id: id,
                    kind: m["kind"].as_u64().unwrap() as u8,
                    count: m["fragments"].as_u64().unwrap() as u16,
                    completion: (
                        m["height"].as_u64().unwrap() as u32,
                        m["tx_index"].as_u64().unwrap() as u32,
                        m["action_index"].as_u64().unwrap() as u32,
                    ),
                    txid: txid_of(m),
                    body: hex::decode(m["body"].as_str().unwrap()).unwrap(),
                }
            })
            .collect()
    }

    pub fn recorded_outcomes() -> Vec<(String, Option<String>)> {
        fixture()["messages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| {
                (
                    m["outcome"].as_str().unwrap().to_string(),
                    m["reason"].as_str().map(str::to_string),
                )
            })
            .collect()
    }

    /// The recorded carrying transaction of a claim-carrying message, or `None` for the 29
    /// messages that make no claim and need none.
    pub fn raw_tx_for(msg_id: &[u8; 32]) -> Option<Vec<u8>> {
        let f = fixture();
        let raw = f["raw_txs"].get(hex::encode(msg_id))?.as_str()?;
        hex::decode(raw).ok()
    }

    /// A carrying-transaction lookup that answers out of the recording instead of off the
    /// network, through **the same [`crate::nightjar::carrier::bind`]** the live path uses.
    ///
    /// Binding here rather than trusting the recording is the point: if `bind` ever stopped
    /// proving that a transaction carried its message, this fixture would notice, because the
    /// recorded pairs would stop binding and the claims would go unchecked — and the state root
    /// would move.
    pub fn recorded_carriers(wanted: &[&Message]) -> Carriers {
        carriers_from(&fixture(), CHANNEL_UIVK, wanted)
    }

    /// Replay the busy channel with the recorded transactions in hand — the verified path.
    pub fn replay_fixture() -> ChannelView {
        replay_using(
            WalletNetwork::Regtest,
            CHANNEL_UIVK,
            BIRTHDAY,
            CHAIN_TIP,
            VK,
            messages(),
            &recorded_carriers,
        )
        .expect("the claims recording replays")
    }

    /// Replay the same channel with **nothing** to look at — the fail-closed path a wallet with
    /// no lightwalletd and no synced database is on.
    pub fn replay_blind() -> ChannelView {
        replay(
            WalletNetwork::Regtest,
            CHANNEL_UIVK,
            BIRTHDAY,
            CHAIN_TIP,
            VK,
            messages(),
            &TxSources::default(),
        )
        .expect("a channel whose claims cannot be checked still replays")
    }
}
