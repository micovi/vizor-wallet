//! The recorded regtest devnet channel the Nyctis tests replay against.
//!
//! A recording rather than a synthesised fixture, because the property worth testing is not "this
//! code agrees with itself" — it is "this code reaches the same state root as the reference
//! implementation, from bytes the reference implementation produced". Every proof in here was
//! made by the Nyctis CLI against the devnet's own verifying key, which is checked in beside
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
//! It was remade once more on 23 September 2026, for spec revision 12 (Nightjar → Nyctis). The
//! circuit version did not move, but every domain separator did (`nightjar.*` → `nyctis.*`), so
//! every `msg_id`, `channel_id`, asset id and root recorded under the old names stopped being
//! reproducible, and the devnet itself was reset. The channel was recorded again the same way.
//!
//! # What this recording covers that the old one could not
//!
//! The old recording predated public asset metadata, NFT collections and ZEC claims, and carried
//! a single asset. This one is taken from the devnet built by `devnet-e2e.sh`, `devnet-assets.sh`,
//! `devnet-programs.sh` and `devnet-testassets.sh` against one channel, so it carries all of it:
//!
//! * **Every outcome kind**, which is what makes it a conformance recording: 37 `applied`,
//!   12 `named`, 4 `published` and 6 `ignored`, and the ignored six are the ones whose *reasons*
//!   are worth pinning — a body that does not parse (`parse: invalid:version`), three rejected
//!   proofs, a supply cap, and a ZEC claim whose carrying transaction never paid.
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
//! about why dropping ignored messages was sound for the state root; this channel carries 59
//! messages in 147 KiB, so it is recorded whole and needs no such argument.
//!
//! # Regenerating
//!
//! With the devnet up (`infra/README.md` in the Nyctis repo), and all four devnet scripts
//! pointed at **one** channel directory — `devnet-programs.sh` documents the
//! `NYCTIS_PROGRAMS_DIR` override that exists for exactly this, because a conformance recording
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
//!   [`Keys::FINGERPRINT`](nyctis_zk::prover::Keys::FINGERPRINT) carries no vk_hash, and the
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

use crate::nyctis::carrier::{Carrier, Carriers, TxSources};
use crate::nyctis::replay::{replay, replay_using, ChannelView, Message};
use crate::wallet::network::WalletNetwork;
use std::sync::Arc;

const FIXTURE: &str = include_str!("../../tests/fixtures/nyctis/devnet-channel.json");
const VK: &[u8] = include_bytes!("../../tests/fixtures/nyctis/devnet-vk.bin");

pub const CHANNEL_UIVK: &str = "uivkregtest12vmc8wdh0dnsmek0nn4u52zg2tn6k68ez5pcamfm2lnldmzq8f6p5468ayun5p60l696h2hjvdyy268ur6z785m8x6s2y9y8z9vpaxpwr8wmd8gutrwwd2pndq7klueeyr03x6dcj7qx52kuttj647c3tq5zjrase2thjtwvshld2zameshgv34p6w7vhvg8janrytj5rz26hh72tacg7gqf64s5s5sety36vzt5ecjsygk3vgh";
pub const CHANNEL_ID: &str = "708443a86074a4c8afaa9faffb684b30fb7d7724df144474160c86198eaea427";
pub const BIRTHDAY: u32 = 2;

/// `/api/status` at the poll the recording was taken from.
pub const CHAIN_TIP: u32 = 1118;
pub const CANONICAL_HEIGHT: u32 = 1108;
pub const STATE_ROOT: &str = "c8d0d8cb2e7ec00c16c64ddcc0d6fc68bb9a1a18115b474b4ba4c0b31ccc612c";
pub const TREE_ROOT: &str = "21c30f5ecf87400e54cdc81c1b33c9c7a7e1f1cb87a41b1f71e808279fbcaf01";
pub const NOTE_COUNT: u64 = 45;
pub const NULLIFIER_COUNT: usize = 24;
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
/// The devnet was mined 220 empty blocks specifically to create it. Recorded where the channel
/// stood — canonical 898, one block past the last message — the two tips were indistinguishable:
/// `/api/state_root/897` and `/api/state_root/898` returned the *same* root, and the channel's
/// longest quiet stretch anywhere in its 443 blocks of message history is 21, so no earlier
/// `as_of` height reproduced it either. This is the whole value of the tip this recording carries,
/// and it is what `replay::tests::a_quiet_channel_prunes_its_anchors_at_the_canonical_height`
/// rests on.
pub const LAST_MESSAGE_HEIGHT: u32 = 897;
/// The root the same messages produce at a canonical height equal to [`LAST_MESSAGE_HEIGHT`] —
/// every anchor still live, none yet stale. It differs from [`STATE_ROOT`], and that difference
/// *is* the prune: same messages, same tree, a smaller anchor set.
pub const STATE_ROOT_AT_LAST_MESSAGE: &str =
    "3ea7ccf517a50d8d7fb371d289057a0ff185f402c0fdc3b7fc6dd6f88de3eb62";

/// What the indexer counted for this channel at [`CANONICAL_HEIGHT`]: 37 `applied`, 12 `named`
/// and 4 `published` make [`ACCEPTED`], against 6 `ignored`. `ChannelView::accepted` must equal
/// the first and `ignored` the second, message for message.
pub const MESSAGE_COUNT: usize = 59;
pub const ACCEPTED: u32 = 53;
pub const IGNORED: u32 = 6;

/// The `vk_hash` the indexer advertises for the key checked in beside this recording. What a
/// caller pins; `NyView::vk_hash` reports it. This is also the key set `.devnet/keys` holds, which
/// is what lets `pay`'s tests prove against the live keys and be accepted by this channel.
pub const VK_HASH: &str = "a8600f3032389c0ea927b88b2814631b0880619ce38ec13f590495526373a51a";

/// The counterparty: `.devnet/assets/bob`, the wallet the issuer paid twice.
///
/// **This role changed shape in the `0x04` re-record and the tests say so.** On the old devnet the
/// demo wallet was a pure recipient — one note, never spent — so a test could assert "the demo
/// seed owns *the* note" and another could use `spent_by.is_none()` across all of its notes as a
/// stand-in for "this wallet authored no input of this message". On this channel bob receives
/// twice and *sends both back*, so neither global shortcut holds. The per-message invariants they
/// were standing in for are asserted directly instead; see `owned::tests::the_two_sides_of_one_payment_agree`.
pub const DEMO_SEED_HEX: &str = "639c62265ef4db03d55afc97051aa0549448fc901477f4be8be2e54c18d82bf1";
pub const DEMO_AK: &str = "56e1e6702ee6af43a7114d2345aa9d63347a5c0db4ee06fdd0e5c53a5f68d010";

/// The other end of the recording: `.devnet/assets/alice`, the wallet that **issued** DMT and then
/// spent it — and, on this channel, the only wallet holding spendable DMT, which is why `pay`'s
/// tests build their payments from this seed rather than the demo one.
pub const ISSUER_SEED_HEX: &str = "802949e780d296692825878bec21da6de53d7838ef60b8cadb2c8817c2503497";

/// The issuance that created the issuer's first note: 600 units, no inputs, one output.
pub const ISSUANCE_MSG: &str = "2d4302ee8c18e5bc6a0533d801cf98fd1cd88f58603fce91d2c4f40bf0aef427";
pub const ISSUANCE_HEIGHT: u32 = 469;
/// The issuer's first payment: it consumed that 600-unit note and returned 450 as change, so 150
/// left. One input, two outputs.
pub const FIRST_SEND_MSG: &str = "d40a64695fa1e4518e588c32628a33aa3a8ad0da17b075e81a3999f6f212b104";
pub const FIRST_SEND_HEIGHT: u32 = 491;
pub const FIRST_SEND_AMOUNT: u64 = 150;
/// The payment whose two halves are both in the recording: the issuer spent 450 and kept 440, and
/// the 10 that left is the demo wallet's second note — the one carrying a `before()` clause.
pub const SEND_TO_DEMO_MSG: &str = "dcd272dc461e06e6c5d246820bc169102dfba3ebba011da8620e66c596961f6c";
pub const SEND_TO_DEMO_HEIGHT: u32 = 513;
/// The message the demo wallet spent that note with, which is what makes it a *spent* receipt —
/// coverage the old recording, whose demo note was never spent, could not offer.
pub const DEMO_SPENDS_IT_MSG: &str =
    "feca078f0aa5f30e242ccb56c68763e3699cae5576aae063812a437b538a26f2";
pub const DEMO_SPENDS_IT_HEIGHT: u32 = 535;
/// The demo wallet's note from [`SEND_TO_DEMO_MSG`], and its policy. The `before()` clause is new
/// coverage: every note on the old recording was under a plain `pk()`.
pub const DEMO_NOTE_AMOUNT: u64 = 10;
pub const DEMO_NOTE_DEADLINE: u32 = 567;

pub fn issuer_seed() -> Vec<u8> {
    hex::decode(ISSUER_SEED_HEX).expect("issuer seed is hex")
}

/// "Devnet Mint" (DMT, 2 decimals), as `/api/assets` reports it. `issued` is below `max_supply`
/// because one further issuance was refused for exceeding the cap — that refusal is one of the
/// six ignored messages in the recording.
pub const ASSET_ID: &str = "e2d2e12f28360688a6e3126144d3fae23b4e0836c6df82a4321fb45da5e7c501";
pub const ASSET_ISSUED: u64 = 600;
pub const ASSET_MAX_SUPPLY: u64 = 1_000;
pub const ASSET_COLLECTION_ID: &str =
    "de62c001233f6e3512ff99667a3ddf7536fd40d23b9828cce6381978c7de5810";
pub const ASSET_URI: &str = "https://example.invalid/dmt/";

/// What the **fail-closed** replay produces: the path a wallet with no Zcash transaction source
/// is on, and the only one reachable across the FRB boundary, whose `NyZecSources` can name a
/// wallet database or a lightwalletd but cannot be handed a recording.
///
/// The divergence is not small, and that is the point. Refusing the paid claim at
/// [`PAID_CLAIM_HEIGHT`] orphans every anchor after it, so 9 of the 59 messages apply instead of
/// 53 and both roots move. A wallet that cannot check a claim does not quietly get a slightly
/// different answer — it gets a visibly crippled channel, which is the correct and loud failure.
pub const STATE_ROOT_BLIND: &str =
    "d034d4f882995b33c2cbfff38eca1b072d5129a4e41ba5dea75461ee8e034242";
pub const TREE_ROOT_BLIND: &str =
    "eed7c9897e113ed15e387abe90861fe225aa399453030b0c884c91cac3d2ab01";
pub const ACCEPTED_BLIND: u32 = 9;
pub const IGNORED_BLIND: u32 = 50;

/// How many assets `owned::asset_summaries` lists for this channel: the 12 the channel has
/// publicly issued (DMT, NightCash and the ten NFT pieces). The two further ids `/api/assets`
/// reports are known only from their orders, never publicly issued, so they are not in
/// `State::issued()` and appear only for a wallet holding a note of them.
pub const CHANNEL_ASSETS: usize = 12;

/// "NightCash" (NC, 8 decimals), the asset the old recording had no analogue for: a public
/// fungible token with a resolvable metadata URI.
pub const NC_ASSET_ID: &str = "9251cdfc656f225594c9ba9a5ccb2cf20fa9ce0ed11ac4545fd7dfa2cfc6af0b";
pub const NC_ISSUED: u64 = 100_000_000_000_000;
pub const NC_MAX_SUPPLY: u64 = 10_000_000_000_000_000;
pub const NC_URI: &str = "https://raw.githubusercontent.com/micovi/nyctis-assets/main/nc/a.json";

/// The "Phases of One Night" NFT collection: ten pieces, each `issued = max_supply = 1`.
pub const PON_COLLECTION_ID: &str =
    "f48d439c3b9406edecd728efec22fd5c51475de252dc22b3bfec72daafb87500";
pub const PON_PIECES: usize = 10;

/// Every piece of that collection as `(index, asset_id)`, in index order.
///
/// Recorded from the devnet indexer's `/api/assets` at tip 1118 — the same source the fixture
/// beside it was recorded from, and deliberately a *second* reading of it. `index` is hashed
/// into `asset_id` through `terms` (`spec/note-format-v0.md` section 8) and the replay verifies
/// the Groth16 proof that says so, so a pairing here that disagreed with the one the replay
/// derives would mean the wire field and the proven field had come apart. The pairing is what
/// resolves `{index}` in a collection document's `item.image`, so it is the one table in this
/// file whose rows decide which picture is drawn for which asset.
pub const PON_MEMBERS: [(u32, &str); PON_PIECES] = [
    (0, "7341336c8ca6cbfa39a3004a529a50edcd6a084b42bef3bf3874a024ca7bc009"),
    (1, "4075791a91dc23f1e54fb8cd1df0df3d5514f6263f162cff597ea2f80dffab06"),
    (2, "f29a872d99ea9a197a7e3c7d7347cefa54897cdf3b5a4bddd8a8e235fbb8ad0f"),
    (3, "7ccc5f82c7ed57f843c557f85ea3cd93f0e6712195bfcd4aa87d1e7bb8477e10"),
    (4, "81e5bc95a829ea75dd7d2344f6025ebb86e22c7f532e250f8e9dd5162a8a2006"),
    (5, "1a5d5ef5c5bb10c7b2e4f319f608e19acf6856600a3dfbbe3979d7f01eda0d11"),
    (6, "4a3c0f862af1a7717c0ffbf541a18c05b5e72447689e8c37dc17c8daa084d302"),
    (7, "c099ac9b797233513849126d99e62600c01a7fd1e279b00386c23cda065cf80e"),
    (8, "17db45cbd5bfc00bdaf605c18dbf44da389117db6cdc8e4ce7755eed7729e80a"),
    (9, "28bd1ffc75e348e4c7b428a17fde60501225b7b2b466f0bf6617d652a34ba108"),
];

/// The `uri` all ten pieces carry — one shared collection document
/// (`spec/asset-collection-v0.md` section 2), not ten per-asset ones.
pub const PON_URI: &str = "https://raw.githubusercontent.com/micovi/nyctis-assets/main/pon/c.json";

/// The paid ZEC claim and the unpaid one, both 50 000 000 zatoshi to the same account. Same
/// amount, same payee, eleven blocks apart; the only difference is whether the Zcash transaction
/// carrying the message actually sent the money.
pub const PAID_CLAIM_HEIGHT: u32 = 592;
pub const UNPAID_CLAIM_HEIGHT: u32 = 581;
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
/// through **the same [`crate::nyctis::carrier::bind`]** the live path uses.
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
            Some(raw) => match crate::nyctis::carrier::bind(&network, &ivk, &raw, m) {
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
/// `api::nyctis::decode_message` does it.
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
            hex::encode(nyctis_zk::prover::vk_hash_bytes(VK)),
            f["vk_hash"].as_str().unwrap()
        );
        assert_eq!(
            f["circuit"].as_str().unwrap(),
            nyctis_zk::prover::Keys::FINGERPRINT
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
/// The **earlier** recording of the *same* channel, taken at tip 712 — before
/// `devnet-testassets.sh` added NightCash and the NFT collection, and 406 blocks before the
/// recording above.
///
/// Since the `0x04` re-record these two are the same channel at two different heights, which they
/// were not before: the recording above used to be a different devnet entirely. This one is kept
/// because it pins things the later one cannot restate for itself — the *divergence* between the
/// blind and the verified replay at a height where the claim pair is the newest thing on the
/// channel, and a second, independent state root for the same message prefix.
///
/// **This is the acceptance test for `nyctis::zec` being a faithful port of the scanner's
/// `PaidClaims`.** The port cannot be checked by construction — `nyctis-scanner` is not
/// linkable here — so it is checked by outcome: every one of these 26 messages must get the
/// verdict the indexer recorded for it, and the replay must land on the `state_root` and
/// `tree_root` the indexer published. Before the oracle existed the wallet accepted 11 of the
/// 31 messages of the recording this one replaced, against the indexer's 25, and diverged on both
/// roots.
///
/// Regenerate exactly as the recording above, including `/api/tx/{txid}` for each message whose
/// `detail.zec_claims` is non-empty, stored under `raw_txs` keyed by `msg_id`.
pub mod claims {
    use super::*;

    const FIXTURE: &str =
        include_str!("../../tests/fixtures/nyctis/devnet-claims-channel.json");
    const VK: &[u8] = include_bytes!("../../tests/fixtures/nyctis/devnet-claims-vk.bin");

    pub const CHANNEL_UIVK: &str = "uivkregtest12vmc8wdh0dnsmek0nn4u52zg2tn6k68ez5pcamfm2lnldmzq8f6p5468ayun5p60l696h2hjvdyy268ur6z785m8x6s2y9y8z9vpaxpwr8wmd8gutrwwd2pndq7klueeyr03x6dcj7qx52kuttj647c3tq5zjrase2thjtwvshld2zameshgv34p6w7vhvg8janrytj5rz26hh72tacg7gqf64s5s5sety36vzt5ecjsygk3vgh";
    pub const CHANNEL_ID: &str =
        "708443a86074a4c8afaa9faffb684b30fb7d7724df144474160c86198eaea427";
    pub const BIRTHDAY: u32 = 2;
    pub const CHAIN_TIP: u32 = 712;
    pub const CANONICAL_HEIGHT: u32 = 702;

    /// The two numbers the indexer publishes for this channel at [`CANONICAL_HEIGHT`], and the
    /// two this wallet has to reach. They are the acceptance test and nothing weaker stands in
    /// for them: agreeing on the message count while disagreeing on the root would mean the
    /// wallet applied the same messages to a different tree.
    pub const STATE_ROOT: &str =
        "fd35d116d0fb4b740fc71b453a473fd623c2bff5c370cdcb3456f45366b5e175";
    pub const TREE_ROOT: &str = "7f04eb924d1d17b9caf73d94c49308b0cd5ebd01fbf8ca5a1abb190e6ca99005";

    /// `applied + published + named` as the indexer counts them: what `ChannelView::accepted`
    /// must equal.
    pub const ACCEPTED: u32 = 20;
    pub const IGNORED: u32 = 6;
    pub const MESSAGE_COUNT: usize = 26;

    /// The paid claim and the unpaid one, both 50 000 000 zatoshi to the same account.
    ///
    /// Same amount, same payee, eleven blocks apart, and the *only* difference is whether the
    /// Zcash transaction carrying the message actually sent the money — which is the one thing a
    /// wallet without an oracle cannot see, and the reason both used to be refused.
    pub const PAID_CLAIM_HEIGHT: u32 = 592;
    pub const UNPAID_CLAIM_HEIGHT: u32 = 581;
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

    /// The recorded carrying transaction of a claim-carrying message, or `None` for the 24
    /// messages that make no claim and need none.
    pub fn raw_tx_for(msg_id: &[u8; 32]) -> Option<Vec<u8>> {
        let f = fixture();
        let raw = f["raw_txs"].get(hex::encode(msg_id))?.as_str()?;
        hex::decode(raw).ok()
    }

    /// A carrying-transaction lookup that answers out of the recording instead of off the
    /// network, through **the same [`crate::nyctis::carrier::bind`]** the live path uses.
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
