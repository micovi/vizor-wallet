//! What a replayed channel holds *for this wallet*, and what it has held: every note the account
//! has ever owned, each tagged with the message that created it and the message that spent it,
//! plus the per-asset summary the unspent ones roll up into.
//!
//! Reporting only the unspent notes — which is what this module used to do, by `continue`-ing
//! past any note whose nullifier was already in the state — is not merely incomplete. After a
//! send, the change note is the only note of that payment the wallet still owns, and a list that
//! says nothing about the input renders it as an arrival: `+988` where the user spent 12. The
//! provenance below is what lets a caller put the change back together with the input it is the
//! remainder of.
//!
//! Two keys do two different jobs and the PoC keeps them apart. The channel's UIVK is public and
//! says *where to look*; it is not a wallet key and decrypts nothing here. The account's own
//! `ivk` says *what is mine*, and it is used exactly once per ciphertext per message, below.

use std::collections::BTreeMap;

use nightjar_codec::policy::Policy;
use nightjar_codec::transition::Transition;
use nightjar_state::PublishedNote;
use nightjar_zk::keys::Account;
use nightjar_zk::note::Note;
use nightjar_zk::{fq_from_bytes, Fq};

use crate::nightjar::replay::ChannelView;

/// How a note reached its owner. After the channel gained published notes there is more than one
/// way, and they are not equally reassuring, which is why the wallet reports it rather than
/// flattening them all into "you own this".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// The ordinary path: a ciphertext in a transition, decrypted with the account's `ivk`.
    Ciphertext,
    /// A `NOTE` message published the note's six fields on the channel. The state machine checked
    /// them against the note already in the tree before recording it, so this is not a claim to
    /// be trusted — but it did depend on a counterparty choosing to publish.
    Published,
    /// A covenant payout or remainder whose `rcm` derives from the consumed nullifier rather than
    /// from an `rseed`, so the recipient can rebuild it from public data alone.
    Recovered,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Ciphertext => "ciphertext",
            Source::Published => "published",
            Source::Recovered => "recovered",
        }
    }
}

/// One applied message as it touched a note: the id it is known by on the channel, where it
/// landed, and the shape of the transition it carried.
///
/// The two counts are the whole reason this is a struct rather than a bare `msg_id`. A
/// transition consumes up to `MAX_IN` = 2 notes and appends up to `MAX_OUT` = 3 (`N_IN` and
/// `N_OUT` on the circuit side), and a wallet
/// sees only the ones addressed to it: an output paying somebody else is a commitment in the
/// tree and a ciphertext this wallet cannot decrypt, so its amount is not unknown-and-small, it
/// is simply unknown. Comparing how many of these notes a caller is holding against `inputs` and
/// `outputs` is what separates "this is the whole message" from "this is my corner of it", and
/// no other field says so.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Touch {
    pub msg_id: [u8; 32],
    /// The height the message completed at. For a creating message this is also the `created`
    /// the state machine stamped on the note, by construction — the stamp is the completion
    /// height.
    pub height: u32,
    /// How many notes the transition consumed (0 for an issuance).
    pub inputs: u32,
    /// How many notes it appended.
    pub outputs: u32,
}

/// A note this wallet owns or has owned.
///
/// Being able to *nullify* a note is not the same as being able to *open* it: a note under a
/// timelock, or under a policy naming a key this wallet does not hold, still lands here. Listing
/// it is right — it is the user's — but a spend path must filter on the policy before it counts
/// the note as available funds. [`spendable_notes`] is that filter's input and this is its
/// display-shaped twin; both come out of one pass, so the two can never disagree about which
/// notes exist.
pub struct OwnedNote {
    pub position: u64,
    pub created: u32,
    pub asset_id: [u8; 32],
    pub amount: u64,
    /// The policy rendered as its text form (`nightjar-codec`'s `Display`), e.g. `pk(<ak>)`.
    pub policy: String,
    pub source: Source,
    /// The message that appended this note to the tree. For a [`Source::Published`] note this is
    /// still the *creating* transition, not the `NOTE` message that disclosed it: grouping a
    /// receipt under the publication would file it against a message that moved no money.
    pub created_by: Touch,
    /// Whether the channel holds this note's nullifier. This is the field a balance and an input
    /// selector must read: it is the state's own set, which is what a spend of this note would
    /// be checked against.
    pub spent: bool,
    /// The message that nullified it, or `None` while it is still spendable — and, in a case no
    /// view produced by [`crate::nightjar::replay`] contains, `None` on a note that is `spent`
    /// but whose spender this view could not name. A note is spent by exactly one message:
    /// `State::apply` refuses a republished nullifier, so this is never ambiguous when it is
    /// present.
    pub spent_by: Option<Touch>,
}

/// Per-asset rollup: what the channel says about the asset, joined with what this wallet holds
/// of it.
pub struct AssetSummary {
    pub asset_id: [u8; 32],
    /// The collection the issuing transition named, or `None` when no applied *public* issuance
    /// disclosed one. See [`AssetSummary::max_supply`]: the all-zero hash is a collection id like
    /// any other, so it cannot double as "unknown".
    pub collection_id: Option<[u8; 32]>,
    /// Position inside [`AssetSummary::collection_id`], from the issuing transition's `terms`,
    /// or `None` when no applied *public* issuance disclosed one.
    ///
    /// **It has to come from the chain, and this is the only place it can.** `terms` carries the
    /// index and is hashed into `asset_id` (`spec/note-format-v0.md` section 8), so an index read
    /// from here cannot be wrong about which piece it names — change it and the `asset_id` no
    /// longer derives. A collection's metadata document uses it to resolve `item.image`'s
    /// `{index}` token (`spec/asset-collection-v0.md` section 3.2), and that substitution is only
    /// safe because of that binding: an index taken from the document instead would let whoever
    /// holds the host decide which artwork belongs to which piece.
    pub index: Option<u32>,
    /// True for an asset with an applied *public* issuance, i.e. one whose total supply the
    /// channel tracks. A privately issued asset appears here only because the wallet holds a
    /// note of it, and its `issued` is unknown (reported as 0), not zero.
    pub public: bool,
    pub name: String,
    pub symbol: String,
    pub decimals: u8,
    pub uri: String,
    pub issued: u64,
    /// The declared supply cap, where `Some(0)` means uncapped, as on the wire.
    ///
    /// `None` means **not disclosed**, which is what a privately issued asset always is here:
    /// `max_supply` is a field of the issuing transition's body, and a private issuance puts no
    /// such body on the channel. Collapsing that into `0` — as this did — said "uncapped" about
    /// an asset whose cap nobody on this channel can see, in the same breath as reporting its
    /// collection as the all-zero hash. `public` already models the same distinction for
    /// `issued`; this is the other half of it.
    pub max_supply: Option<u64>,
    pub balance: u64,
    pub note_count: u32,
}

/// An unspent note together with everything a *spend* of it needs: the note itself, its policy
/// as a tree rather than as display text, and the nullifier key that opens it.
///
/// [`OwnedNote`] is the flattened, display-shaped view of the same thing and is what crosses the
/// FFI. This is the one the prover wants, and both come out of a single pass ([`recover`]) so
/// that a wallet can never show one set of notes and spend from another — this one narrowed to
/// the unspent by [`spendable_notes`], that one carrying the spent as well and saying so.
#[derive(Clone, Debug)]
pub struct Spendable {
    pub note: Note,
    pub policy: Policy,
    /// The nullifier key that spends this note — the plaintext's, when a custom policy carried
    /// one, otherwise the account's own.
    pub nk: Fq,
    pub position: u64,
    pub created: u32,
}

impl Spendable {
    /// The `SELF` view the policy interpreter reads when evaluating this note's own conditions.
    pub fn note_view(&self) -> nightjar_codec::policy::NoteView {
        nightjar_codec::policy::NoteView {
            policy_root: self.note.policy_root.to_bytes(),
            asset_id: self.note.asset_id.to_bytes(),
            amount: self.note.amount,
            nkc: self.note.nkc.to_bytes(),
            data: self.note.data.to_bytes(),
            rcm: self.note.rcm().to_bytes(),
            created: self.created,
            position: self.position,
        }
    }
}

/// Every note `account` has ever owned in `view`, with its provenance and its fate.
///
/// **One pass, three readers.** The read path ([`owned_notes`]), the balance
/// ([`asset_summaries`]) and the spend path (`crate::nightjar::pay`, through
/// [`spendable_notes`]) are all projections of this list, and the only thing that decides
/// spentness is the `spent_by` set once, here. Recovering the notes twice, once per caller, is
/// how a wallet ends up listing a balance it then cannot select inputs from — the two passes
/// drift on exactly the cases that are hard to reason about (a published note, a recoverable
/// payout, a position claimed by both passes) and the disagreement surfaces as "insufficient
/// funds" against a balance the same screen is showing. The spent flag is now one of those
/// cases, and the more dangerous one: a note counted as unspendable by the balance but offered
/// to the input selector produces a proof against a nullifier the channel already has, which
/// every verifier rejects after the user has paid to carry it.
///
/// Ciphertext recovery runs first and publication second, and a position already claimed by the
/// first pass is never overwritten by the second — a decrypted note carries its `rseed`, a
/// published one only an explicit `rcm`, and the `rseed` form is the one a spend can re-encrypt
/// change against.
struct Recovered {
    note: Note,
    policy: Policy,
    nk: Fq,
    position: u64,
    created: u32,
    created_by: Touch,
    /// Whether the channel already holds this note's nullifier — the authority, read straight
    /// off the state the proofs were replayed into.
    spent: bool,
    /// Which message published that nullifier. Attribution, not authority; see [`recover`].
    spent_by: Option<Touch>,
}

/// The applied message `msg_id` as a [`Touch`], with the input and output counts read off the
/// two halves of the replay's record of it.
///
/// A message the replay never applied has no shape; that is `0/0` rather than an error because
/// the only way to reach here with one is a note whose creating message is missing from
/// `applied`, which the callers below already skip.
fn touch(view: &ChannelView, msg_id: [u8; 32], height: u32) -> Touch {
    Touch {
        msg_id,
        height,
        inputs: view.consumed.get(&msg_id).map_or(0, Vec::len) as u32,
        outputs: view.applied.get(&msg_id).map_or(0, Vec::len) as u32,
    }
}

fn recover(view: &ChannelView, account: &Account) -> Vec<Recovered> {
    let mut out: Vec<Recovered> = Vec::new();
    let mut seen_positions: Vec<u64> = Vec::new();

    // position → the message that appended it, which a published note has no other way to learn.
    // Built from `applied` rather than from `PublishedNote::msg_id`: that field names the `NOTE`
    // message which *disclosed* the note, a message that moved no money and may have been sent
    // long after the note existed. The height is the state machine's own stamp, which is the
    // height of the block the creating message was applied in — the same value the ciphertext
    // pass below reads off the message's completion.
    let mut creator: BTreeMap<u64, ([u8; 32], u32)> = BTreeMap::new();
    for (msg_id, notes) in &view.applied {
        for n in notes {
            creator.insert(n.position, (*msg_id, n.created));
        }
    }

    for msg in &view.messages {
        let Some(notes) = view.applied.get(&msg.msg_id) else {
            continue;
        };
        let Ok(tx) = Transition::decode(&msg.body) else {
            continue;
        };
        for r in nightjar_zk::transition::recover(&tx, account) {
            // `recover` indexes outputs within the transition; the state machine assigned each
            // output a tree position when it applied the message. Without that join a note has
            // no position, and a position is bound into the nullifier, so it could not be spent
            // and could not be checked for having been spent.
            let Some(applied) = notes.get(r.output_index) else {
                continue;
            };
            if seen_positions.contains(&applied.position) {
                continue;
            }
            // **Spent is recorded, not filtered.** This is the same nullifier the discarded
            // `continue` used to be keyed on — same note, same `nk`, same position — and it is
            // still asked of the same set. What is new is the second lookup beside it, which
            // says *which message* published it. Dropping the note here is what left a send
            // visible only as its change.
            //
            // The two are asked separately on purpose. `has_nullifier` is the channel's own set
            // and is what a spend of this note would be checked against, so it decides whether
            // the note may fund a payment; `spent_by` is an index the replay built from the same
            // outcomes and only ever adds a name to that answer. They agree on every view this
            // module can be handed — `replay::tests::every_nullifier_names_the_message_that_
            // published_it` pins it — and if they ever did not, the pessimistic half is the one
            // that must win: an unattributed spend is a display gap, whereas a spent note
            // offered to the prover is a transition the whole channel rejects after the user has
            // paid to carry it.
            let nullifier = r.note.nullifier(&r.nk, applied.position).to_bytes();
            let spent = view.state.has_nullifier(&nullifier);
            let spent_by = view
                .spent_by
                .get(&nullifier)
                .map(|s| touch(view, s.msg_id, s.height));
            seen_positions.push(applied.position);
            out.push(Recovered {
                note: r.note,
                policy: r.policy,
                nk: r.nk,
                position: applied.position,
                created: applied.created,
                created_by: touch(view, msg.msg_id, msg.completion.0),
                spent,
                spent_by,
            });
        }
    }

    // Published notes. A note can reach its owner by publication rather than by encryption, and
    // the remainder a taker leaves under a maker's offer is exactly that case: it carries no
    // ciphertext at all, because the maker's `pk_enc` is nowhere in the published order, so
    // nothing could have been encrypted to them. Skipping this pass would leave such a note
    // visible in the tree, owned, and unspendable.
    //
    // Matching on `nkc` says who can nullify, not who can open, for the same reason the doc
    // comment on [`OwnedNote`] gives.
    let nkc = account.nkc().to_bytes();
    for p in view.state.published() {
        if p.note.nkc != nkc {
            continue;
        }
        let Some((note, policy, nk)) = note_of_published(p) else {
            continue;
        };
        let position = p.note.position;
        let Some(applied) = view.state.notes().get(position as usize) else {
            continue;
        };
        if seen_positions.contains(&position) {
            continue;
        }
        // Unreachable in a self-consistent view — every position in the tree was put there by a
        // message in `applied`, and `published()` holds only notes the state machine matched
        // against the tree — but a note with no creating message has no provenance, and filing
        // it under an invented one would group a receipt into the wrong payment.
        let Some(&(created_by, created_height)) = creator.get(&position) else {
            continue;
        };
        let nullifier = note.nullifier(&nk, position).to_bytes();
        let spent = view.state.has_nullifier(&nullifier);
        let spent_by = view
            .spent_by
            .get(&nullifier)
            .map(|s| touch(view, s.msg_id, s.height));
        seen_positions.push(position);
        out.push(Recovered {
            note,
            policy,
            nk,
            position,
            created: applied.created,
            created_by: touch(view, created_by, created_height),
            spent,
            spent_by,
        });
    }

    out.sort_by_key(|n| n.position);
    out
}

/// Every **unspent** note `account` owns in `view`, in the form a spend needs.
///
/// The filter is `!spent` over [`recover`] and nothing else, so what the balance counts and what
/// the input selector may draw on are the same decision, made once, from the channel's own
/// nullifier set. A note that is spent is already in that set; offering it to the prover would
/// build a transition every verifier refuses.
pub fn spendable_notes(view: &ChannelView, account: &Account) -> Vec<Spendable> {
    recover(view, account)
        .into_iter()
        .filter(|r| !r.spent)
        .map(|r| Spendable {
            note: r.note,
            policy: r.policy,
            nk: r.nk,
            position: r.position,
            created: r.created,
        })
        .collect()
}

/// Every note `account` has **ever** owned in `view`, flattened for display, spent ones included
/// and marked.
///
/// A projection of [`recover`] and nothing else: what a screen shows and what a payment may draw
/// on come from one pass, read two ways.
pub fn owned_notes(view: &ChannelView, account: &Account) -> Vec<OwnedNote> {
    recover(view, account)
        .into_iter()
        .map(|r| OwnedNote {
            position: r.position,
            created: r.created,
            asset_id: r.note.asset_id.to_bytes(),
            amount: r.note.amount,
            policy: r.policy.to_string(),
            source: source_of(&r.note),
            created_by: r.created_by,
            spent: r.spent,
            spent_by: r.spent_by,
        })
        .collect()
}

/// The note of a `NOTE` message as the wallet needs it: `rcm` given outright, `rseed` unused.
/// `None` when any of its field elements is non-canonical, which the state machine's own
/// recommitment check already makes impossible for a recorded publication.
fn note_of_published(p: &PublishedNote) -> Option<(Note, Policy, Fq)> {
    let m = &p.note;
    let note = Note {
        policy_root: fq_from_bytes(&m.policy_root)?,
        asset_id: fq_from_bytes(&m.asset_id)?,
        amount: m.amount,
        nkc: fq_from_bytes(&m.nkc)?,
        data: fq_from_bytes(&m.data)?,
        rseed: [0; 32],
        recoverable_from: None,
        explicit_rcm: Some(fq_from_bytes(&m.rcm)?),
    };
    Some((note, m.policy.clone(), fq_from_bytes(&m.nk)?))
}

/// Which of the three ways this note came back, read off the note's own shape — the same test
/// the reference CLI's `notes` command prints its tag from.
fn source_of(note: &Note) -> Source {
    if note.recoverable_from.is_some() {
        Source::Recovered
    } else if note.explicit_rcm.is_some() {
        Source::Published
    } else {
        Source::Ciphertext
    }
}

/// Fold the channel's asset registry together with this wallet's balance of each asset.
///
/// Three sources, joined on `asset_id`:
///
/// - `Issued` gives every publicly issued asset and its outstanding supply;
/// - the issuing transitions give `collection_id` and `max_supply`, which the registry does not
///   keep (they live in the body of the message that minted, not in the state's `Assets` map);
/// - `Assets` gives the name, symbol, decimals and URI an `ASSET` message declared, which is
///   optional — an asset with no `ASSET` message is unnamed, not invalid.
///
/// An asset the wallet holds a note of but which has no public issuance is included too, with
/// `public: false`. Leaving it out would hide a private asset's balance entirely.
///
/// **`balance` and `note_count` count unspent notes only**, though `notes` now carries the spent
/// ones as well. That is the whole point of the split: what a wallet has is a different number
/// from what it has ever held, and adding a spent note to a balance would say the money is still
/// there. The *asset list* is built from every note ever owned, unspent or not, so that an asset
/// the wallet has spent down to nothing still has a row — without it a private asset's history
/// would reference a symbol and a `decimals` no longer in the view, and the UI would have
/// nothing to render an outgoing payment with.
pub fn asset_summaries(view: &ChannelView, notes: &[OwnedNote]) -> Vec<AssetSummary> {
    // `collection_id` and `max_supply` from the bodies of the applied public issuances.
    let mut minted: BTreeMap<[u8; 32], ([u8; 32], u64, u32)> = BTreeMap::new();
    for msg in &view.messages {
        if view.state.public_issuance(&msg.msg_id).is_none() {
            continue;
        }
        let Ok(tx) = Transition::decode(&msg.body) else {
            continue;
        };
        let (Some(asset), Some(collection)) = (tx.asset_issue, tx.collection_id) else {
            continue;
        };
        // First issuance wins, and it is sound for all **three** of these, not just two.
        // `spec/note-format-v0.md` section 8: `terms = Fq(visibility + 2·max_supply +
        // 2^65·index + 2^97·collection_max_supply)` and `asset_id = Poseidon_3(DS_ASSET,
        // collection_id, label, terms)`, with `collection_id` itself a `Poseidon_4` over the
        // cap. The cap sits in both so that members cannot disagree with each other (through
        // `collection_id`) and the issuer cannot disagree with itself (through `terms`). So
        // the collection, the cap *and the index* are preimage components of the id, and a
        // further issuance that changed any of them would derive a different `asset_id` and
        // land in a different entry of this map. The proof is what enforces it rather than
        // this code trusting the body: `public_inputs_from_transition` rebuilds `terms` from
        // `tx.max_supply` and `tx.index` and `replay` verifies the Groth16 proof over it, so a
        // body whose `index` disagreed with its own `asset_issue` never applies.
        //
        // Taking the first is therefore the same value as taking the last, and is stable under
        // a re-replay; taking the last is stable too, but only by accident of ordering.
        minted.entry(asset).or_insert((collection, tx.max_supply, tx.index));
    }

    // Every asset gets an entry, spent notes included; only the unspent ones add to the totals.
    // The filter is here rather than at the call site so that a caller handing over the full
    // history — which is now the ordinary thing to do, since the history is what the activity
    // feed is built from — cannot inflate a balance by doing so.
    let mut balances: BTreeMap<[u8; 32], (u64, u32)> = BTreeMap::new();
    for n in notes {
        let e = balances.entry(n.asset_id).or_insert((0, 0));
        if n.spent {
            continue;
        }
        e.0 = e.0.saturating_add(n.amount);
        e.1 += 1;
    }

    // `BTreeMap` keys everywhere, so the output is ascending by `asset_id`: two replays of the
    // same channel produce the same list in the same order, which is what a UI diffing against
    // its previous render needs.
    let mut ids: Vec<[u8; 32]> = view.state.issued().keys().copied().collect();
    for id in balances.keys() {
        if !ids.contains(id) {
            ids.push(*id);
        }
    }
    ids.sort_unstable();

    ids.into_iter()
        .map(|asset_id| {
            let (collection_id, max_supply, index) = match minted.get(&asset_id).copied() {
                Some((c, m, i)) => (Some(c), Some(m), Some(i)),
                None => (None, None, None),
            };
            let (balance, note_count) = balances.get(&asset_id).copied().unwrap_or((0, 0));
            let record = view.state.asset(&asset_id);
            AssetSummary {
                asset_id,
                collection_id,
                index,
                public: view.state.issued().contains_key(&asset_id),
                name: record
                    .map(|r| r.name_str().into_owned())
                    .unwrap_or_default(),
                symbol: record
                    .map(|r| r.symbol_str().into_owned())
                    .unwrap_or_default(),
                decimals: record.map(|r| r.decimals).unwrap_or(0),
                uri: record.map(|r| r.uri_str().into_owned()).unwrap_or_default(),
                issued: view.state.issued_of(&asset_id),
                max_supply,
                balance,
                note_count,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nightjar::testdata;

    /// DMT out of the registry, by id.
    ///
    /// The old recording's channel carried exactly one asset, so these tests reached it as
    /// `assets[0]` and asserted `assets.len() == 1`. This channel carries fourteen — DMT,
    /// NightCash, ten NFT pieces and two assets known only from their orders — so the asset under
    /// test is selected by the id the constant names. That is the same assertion about the same
    /// asset; only the way of reaching it changed.
    fn dmt(assets: &[AssetSummary]) -> &AssetSummary {
        assets
            .iter()
            .find(|a| hex::encode(a.asset_id) == testdata::ASSET_ID)
            .expect("the registry carries Devnet Mint")
    }

    #[test]
    fn the_demo_seed_owns_the_known_devnet_note() {
        let view = testdata::replay_fixture();
        let account = crate::nightjar::keys::account(&testdata::demo_seed());
        let notes = owned_notes(&view, &account);

        // two receipts on this channel, not one: the issuer paid this wallet twice
        assert_eq!(
            notes.len(),
            2,
            "{:?}",
            notes
                .iter()
                .map(|n| (n.position, n.amount))
                .collect::<Vec<_>>()
        );
        let note = notes
            .iter()
            .find(|n| hex::encode(n.created_by.msg_id) == testdata::SEND_TO_DEMO_MSG)
            .expect("the receipt from the payment whose other half is also recorded");
        assert_eq!(hex::encode(note.asset_id), testdata::ASSET_ID);
        assert_eq!(note.amount, testdata::DEMO_NOTE_AMOUNT);
        assert_eq!(note.source, Source::Ciphertext);
        // The policy of a plain payment to an address is that address's spend key. This one also
        // carries a `before()` deadline, which the old recording had no example of anywhere: a
        // note the wallet must check the height against before it may open it.
        assert_eq!(
            note.policy,
            format!(
                "pk({}) && before({})",
                testdata::DEMO_AK,
                testdata::DEMO_NOTE_DEADLINE
            )
        );
        // and this wallet later spent it, which the old recording's demo note never was — so the
        // spent side of the provenance is asserted here rather than only on the issuer
        assert!(note.spent);
        let by = note.spent_by.expect("the demo wallet spent this note back");
        assert_eq!(hex::encode(by.msg_id), testdata::DEMO_SPENDS_IT_MSG);
        assert_eq!(by.height, testdata::DEMO_SPENDS_IT_HEIGHT);
        assert_eq!(
            hex::encode(note.created_by.msg_id),
            testdata::SEND_TO_DEMO_MSG
        );
        assert_eq!(note.created_by.height, testdata::SEND_TO_DEMO_HEIGHT);
    }

    /// **The defect this module was changed for.** A note the wallet spent used to be dropped
    /// here, which left a send visible only as its change — a note the activity feed then
    /// rendered as an arrival. It must come back marked, naming the message that spent it and
    /// the height that message landed at.
    #[test]
    fn a_spent_note_names_the_message_that_spent_it() {
        let view = testdata::replay_fixture();
        let account = crate::nightjar::keys::account(&testdata::issuer_seed());
        let notes = owned_notes(&view, &account);

        assert_eq!(
            notes.len(),
            5,
            "the issuer's whole history: an issuance, two payments and two receipts — {:?}",
            notes
                .iter()
                .map(|n| (n.position, n.amount, n.spent))
                .collect::<Vec<_>>()
        );
        assert_eq!(notes.iter().filter(|n| n.spent).count(), 2);

        // the issued note: no input created it, and the first payment consumed it
        let issued = &notes[0];
        assert_eq!((issued.position, issued.amount), (3, 600));
        assert_eq!(hex::encode(issued.created_by.msg_id), testdata::ISSUANCE_MSG);
        assert_eq!(issued.created_by.height, testdata::ISSUANCE_HEIGHT);
        assert_eq!(
            issued.created_by.inputs, 0,
            "an issuance consumes nothing; 0 here is the shape of a mint, not a missing lookup"
        );
        assert_eq!(issued.created_by.outputs, 1);

        assert!(issued.spent);
        let by = issued.spent_by.expect("the issued note was spent");
        assert_eq!(hex::encode(by.msg_id), testdata::FIRST_SEND_MSG);
        assert_eq!(by.height, testdata::FIRST_SEND_HEIGHT);
        assert_eq!(
            (by.inputs, by.outputs),
            (1, 2),
            "one input and two outputs: the recipient's and the change"
        );
    }

    /// What a caller reconstructs, restated as an assertion so that the FRB doc comment promising
    /// it cannot drift from what the data supports. Group by `msg_id`: this wallet owned *every*
    /// input of the message, so it authored it, and what left is the inputs less the outputs it
    /// kept. The output it did not keep is not zero and not visible — only its existence is, as
    /// the gap between `outputs` and the notes in hand.
    #[test]
    fn an_authored_payment_is_derivable_from_the_grouping_alone() {
        let view = testdata::replay_fixture();
        let account = crate::nightjar::keys::account(&testdata::issuer_seed());
        let notes = owned_notes(&view, &account);
        let msg: [u8; 32] = hex::decode(testdata::FIRST_SEND_MSG)
            .unwrap()
            .try_into()
            .unwrap();

        let inputs: Vec<&OwnedNote> = notes
            .iter()
            .filter(|n| n.spent_by.map(|s| s.msg_id) == Some(msg))
            .collect();
        let outputs: Vec<&OwnedNote> = notes
            .iter()
            .filter(|n| n.created_by.msg_id == msg)
            .collect();
        assert_eq!(inputs.len(), 1);
        assert_eq!(outputs.len(), 1);

        let shape = inputs[0].spent_by.unwrap();
        assert_eq!(
            inputs.len() as u32,
            shape.inputs,
            "every input was this wallet's, so this wallet signed the message"
        );
        let spent: u64 = inputs.iter().map(|n| n.amount).sum();
        let kept: u64 = outputs.iter().map(|n| n.amount).sum();
        assert_eq!(spent - kept, testdata::FIRST_SEND_AMOUNT);
        assert_eq!(
            outputs.len() as u32 + 1,
            shape.outputs,
            "one output is somebody else's: the wallet cannot decrypt it and its amount is              knowable only as the difference above"
        );
    }

    /// Both halves of one payment, out of one recording under two keys: 100 left the issuer at
    /// height 6913 and 100 is exactly what the demo wallet found there. The receipt side is the
    /// case with no owned input — which is the whole of the rule a caller applies to tell an
    /// arrival from a remainder.
    #[test]
    fn the_two_sides_of_one_payment_agree() {
        let view = testdata::replay_fixture();
        let msg: [u8; 32] = hex::decode(testdata::SEND_TO_DEMO_MSG)
            .unwrap()
            .try_into()
            .unwrap();

        let issuer = owned_notes(
            &view,
            &crate::nightjar::keys::account(&testdata::issuer_seed()),
        );
        let spent: u64 = issuer
            .iter()
            .filter(|n| n.spent_by.map(|s| s.msg_id) == Some(msg))
            .map(|n| n.amount)
            .sum();
        let change: u64 = issuer
            .iter()
            .filter(|n| n.created_by.msg_id == msg)
            .map(|n| n.amount)
            .sum();
        assert_eq!((spent, change), (450, 440));

        let demo = owned_notes(
            &view,
            &crate::nightjar::keys::account(&testdata::demo_seed()),
        );
        // The invariant is per-message: a receipt is a message none of whose inputs this wallet
        // owned. On the old recording the demo wallet had never spent anything, so `all(spent_by
        // is_none())` across every note happened to say the same thing; here it spends both of its
        // receipts later, so the claim is made about *this message* — which is what the sentence
        // above it always meant.
        assert!(
            demo.iter()
                .all(|n| n.spent_by.map(|s| s.msg_id) != Some(msg)),
            "the receiving wallet owned no input of this message, which is what makes it a              receipt rather than its own change"
        );
        let received: u64 = demo
            .iter()
            .filter(|n| n.created_by.msg_id == msg)
            .map(|n| n.amount)
            .sum();
        assert_eq!(spent - change, received);
    }

    /// A seed that owns nothing on this channel must see the assets and a zero balance, not an
    /// error and not somebody else's note. The channel's UIVK is public, so this is the ordinary
    /// case of replaying a channel one has not yet been paid on.
    #[test]
    fn a_stranger_replaying_the_same_channel_owns_nothing() {
        let view = testdata::replay_fixture();
        let account = crate::nightjar::keys::account(b"not the demo seed");
        assert!(owned_notes(&view, &account).is_empty());

        let assets = asset_summaries(&view, &[]);
        assert_eq!(assets.len(), testdata::CHANNEL_ASSETS);
        // every one of them reads as held-by-nobody for this account, not just DMT
        assert!(assets.iter().all(|a| a.balance == 0 && a.note_count == 0));
        assert_eq!(
            dmt(&assets).issued,
            testdata::ASSET_ISSUED,
            "the public supply is a channel fact, not a wallet one"
        );
    }

    #[test]
    fn the_asset_registry_is_joined_with_the_wallets_own_balance() {
        let view = testdata::replay_fixture();
        // the issuer rather than the demo wallet: `note_count` and `balance` count *unspent*
        // notes, and on this channel the demo wallet has spent both of its receipts back, so a
        // join against it would be zero on both sides and would assert nothing about joining
        let account = crate::nightjar::keys::account(&testdata::issuer_seed());
        let notes = owned_notes(&view, &account);
        let assets = asset_summaries(&view, &notes);

        assert_eq!(assets.len(), testdata::CHANNEL_ASSETS);
        let a = dmt(&assets);
        assert_eq!(hex::encode(a.asset_id), testdata::ASSET_ID);
        assert!(a.public);
        assert_eq!(a.name, "Devnet Mint");
        assert_eq!(a.symbol, "DMT");
        assert_eq!(a.decimals, 2);
        assert_eq!(a.issued, testdata::ASSET_ISSUED);
        assert_eq!(a.max_supply, Some(testdata::ASSET_MAX_SUPPLY));
        assert_eq!(a.uri, testdata::ASSET_URI);
        assert_eq!(
            a.collection_id.map(hex::encode).as_deref(),
            Some(testdata::ASSET_COLLECTION_ID)
        );
        assert_eq!(a.note_count, 3, "440 + 150 + 10, the unspent three");
        assert_eq!(a.balance, 600);

        // the metadata the old recording had no example of: a second public asset with a
        // resolvable URI, and an NFT collection whose pieces are single-supply
        let nc = assets
            .iter()
            .find(|x| hex::encode(x.asset_id) == testdata::NC_ASSET_ID)
            .expect("the registry carries NightCash");
        assert_eq!((nc.name.as_str(), nc.symbol.as_str(), nc.decimals), ("NightCash", "NC", 8));
        assert_eq!(nc.uri, testdata::NC_URI);
        assert_eq!(nc.issued, testdata::NC_ISSUED);
        assert_eq!(nc.max_supply, Some(testdata::NC_MAX_SUPPLY));
        let pieces: Vec<&AssetSummary> = assets
            .iter()
            .filter(|x| x.collection_id.map(hex::encode).as_deref() == Some(testdata::PON_COLLECTION_ID))
            .collect();
        assert_eq!(pieces.len(), testdata::PON_PIECES);
        assert!(pieces.iter().all(|x| x.issued == 1 && x.max_supply == Some(1)));
    }

    /// **The index is the whole of what makes one shared document safe for a hundred pieces**,
    /// so it is asserted against the chain rather than assumed.
    ///
    /// `spec/note-format-v0.md` section 8 puts `index` in `terms` and `terms` in `asset_id`, and
    /// `replay` verifies the Groth16 proof that rebuilds `terms = Fq(1 + 2·max_supply +
    /// 2^65·index + 2^97·collection_max_supply)` from the very field this reads. So the ten
    /// numbers below are not the body's
    /// word for the ten numbers — they are the ten the circuit proved, and the pairing with
    /// `asset_id` is what decides which of `pon/0.png` … `pon/9.png` is drawn for which piece.
    /// Getting it wrong is not a cosmetic fault: it is the wrong picture under the right id.
    #[test]
    fn every_piece_carries_the_index_the_chain_bound_into_its_asset_id() {
        let view = testdata::replay_fixture();
        let account = crate::nightjar::keys::account(&testdata::issuer_seed());
        let notes = owned_notes(&view, &account);
        let assets = asset_summaries(&view, &notes);

        let mut pieces: Vec<(u32, String)> = assets
            .iter()
            .filter(|x| x.collection_id.map(hex::encode).as_deref() == Some(testdata::PON_COLLECTION_ID))
            .map(|x| {
                (
                    x.index.expect("a public issuance disclosed this piece's index"),
                    hex::encode(x.asset_id),
                )
            })
            .collect();
        pieces.sort_unstable();

        let expected: Vec<(u32, String)> = testdata::PON_MEMBERS
            .iter()
            .map(|(i, id)| (*i, (*id).to_string()))
            .collect();
        assert_eq!(pieces, expected, "index↔asset_id must match what the chain published");

        // Contiguous 0..9, which is what makes `digests[index]` a total function over this
        // collection rather than a lookup with holes in it.
        let indices: Vec<u32> = pieces.iter().map(|(i, _)| *i).collect();
        assert_eq!(indices, (0..testdata::PON_PIECES as u32).collect::<Vec<_>>());

        // One document between the ten of them; `{index}` is the only thing that differs.
        for piece in assets
            .iter()
            .filter(|x| x.collection_id.map(hex::encode).as_deref() == Some(testdata::PON_COLLECTION_ID))
        {
            assert_eq!(piece.uri, testdata::PON_URI);
        }

        // `index` is `Some` exactly when `collection_id` is: both come out of the same applied
        // public issuance, so "in a collection with no readable index" is not a state this can
        // report, and the UI's `Not read yet` branch is unreachable for a public asset.
        for asset in &assets {
            assert_eq!(
                asset.collection_id.is_some(),
                asset.index.is_some(),
                "collection and index are disclosed together or not at all"
            );
        }
    }

    /// **The drift this file is arranged to make impossible.** What the balance counts and what
    /// the input selector may spend are one decision, so the spendable list must be exactly the
    /// unspent half of the reported list — same positions, same order — and the flag must be the
    /// channel's own nullifier set rather than a second opinion about it. A note counted as gone
    /// but still offered to the prover produces a transition against a nullifier the channel
    /// already holds, which every verifier rejects after the user has paid to carry it.
    #[test]
    fn what_may_be_spent_is_exactly_the_unspent_half_of_what_is_reported() {
        let view = testdata::replay_fixture();
        let account = crate::nightjar::keys::account(&testdata::issuer_seed());
        let reported = owned_notes(&view, &account);
        let spendable = spendable_notes(&view, &account);

        let unspent: Vec<u64> = reported
            .iter()
            .filter(|n| !n.spent)
            .map(|n| n.position)
            .collect();
        let offered: Vec<u64> = spendable.iter().map(|s| s.position).collect();
        assert_eq!(offered, unspent);
        assert!(!offered.is_empty() && offered.len() < reported.len());

        for s in &spendable {
            assert!(
                !view
                    .state
                    .has_nullifier(&s.note.nullifier(&s.nk, s.position).to_bytes()),
                "position {} is offered to the prover and the channel has already seen its                  nullifier",
                s.position
            );
        }
    }

    /// The balance is what the wallet *has*, not what it has held. Spent notes joining the list
    /// must not join the total — and the total is asserted here against the same numbers the
    /// reference CLI prints for these two wallets.
    #[test]
    fn the_balance_counts_unspent_notes_only() {
        let view = testdata::replay_fixture();
        let account = crate::nightjar::keys::account(&testdata::issuer_seed());
        let notes = owned_notes(&view, &account);
        assert_eq!(
            notes.iter().map(|n| n.amount).sum::<u64>(),
            1_650,
            "the history sums to more than the wallet holds, which is why it cannot be a balance"
        );

        let assets = asset_summaries(&view, &notes);
        let a = dmt(&assets);
        assert_eq!(a.balance, 600, "440 + 150 + 10, the unspent three");
        assert_eq!(a.note_count, 3);
        assert_eq!(
            a.balance,
            notes
                .iter()
                .filter(|n| !n.spent)
                .map(|n| n.amount)
                .sum::<u64>()
        );

        // the two wallets' balances still account for the whole issued supply, which they would
        // not if a spent note were being counted anywhere
        let demo = crate::nightjar::keys::account(&testdata::demo_seed());
        let demo_notes = owned_notes(&view, &demo);
        let demo_assets = asset_summaries(&view, &demo_notes);
        assert_eq!(dmt(&demo_assets).balance, 0, "both receipts were spent back");
        assert_eq!(
            dmt(&demo_assets).balance + a.balance,
            testdata::ASSET_ISSUED,
            "the two wallets still account for the whole issued supply"
        );
    }
}
