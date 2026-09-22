# Nightjar in Vizor — proof of concept

A PoC that lets this wallet **hold** Nightjar assets on the regtest devnet: list what it owns,
verify it for itself, and show its Nightjar receive address. Paying an asset to another Nightjar
address is not implemented — see "What this PoC does and does not do" below.

Nightjar is a client-verified overlay on Zcash. Its messages ride inside ordinary
Ironwood shielded memos addressed to a public *channel*, and every participant
replays the channel to reach the same state. Nothing is enforced by consensus, so a
wallet that wants to believe a balance has to verify the proofs itself.

## The cut

Three Nightjar crates carry **no zcash dependency at all** and are linked into
`rust_lib_zcash_wallet` directly, plus the two upstream crates they need:

| crate | what it gives us |
|---|---|
| `nightjar-codec` | the wire format: memo framing, message reassembly, `Transition` encode/decode, the policy tree |
| `nightjar-state` | the deterministic verifier: apply messages, nullifier set, commitment tree, asset registry |
| `nightjar-zk` | keys and addresses, note encryption, Groth16 prove/verify |
| `decaf377-rdsa`, `bech32` | the curve signatures and address encoding those need — published crates, not Nightjar's |

They are **path dependencies into the Nightjar repo**
(`rust/Cargo.toml`: `path = "../../../crates/nightjar-codec"` and the other two), so this wallet
directory is not a standalone checkout: cloning it alone gives a tree that does not build. There
is no `nightjar-tx` dependency; nothing here builds a transition yet.

`nightjar-scanner`, `nightjar-chain` and `nightjar-wallet` are **deliberately left
out**. They depend on upstream librustzcash, which would put a second, incompatible
Zcash stack beside the Zakura forks this wallet is built on — two `orchard` crates,
two `zcash_client_sqlite` migration sets over one database file. Every Zcash-shaped
job Nightjar needs is done with this wallet's own stack instead:

- **getting the messages** — the Nightjar indexer's HTTP API, fetched from Dart
  through `NetworkHttpClient` so the Tor route policy still applies.
- **sending a message** — this wallet's own proposal/broadcast path, extended with a
  raw-memo output (a Nightjar memo is binary and starts with `0xFF`, so the existing
  text-memo path drops it).

What the indexer gives us is *data availability*, not trust: it hands over message
bodies and the verifying key, and the wallet verifies every Groth16 proof and
recomputes the whole state locally.

Verifying the proofs is necessary and it is not sufficient. A message arrives with a
`msg_id`, and **nothing in the proof covers it** — the proof commits to the transition's field
elements, `tx.sighash` commits to `channel_id ‖ body`, and neither mentions the id. Meanwhile
`nightjar_state::State::apply` uses `msg_id` as its replay-protection key and folds it into
`applied_hash` inside `state_root`. Taking it on the indexer's word therefore gave the indexer a
free hand on the one number two verifiers are supposed to compare. Both halves were reproducible
against the live devnet:

- rename applied message `82852615…` to `00…00` and `state_root` moves from `2adf95cd…` to
  `85b0349c…` with every proof still verifying, `applied` still 7 and the balance still 100;
- give applied message `ea47c855…` the `msg_id` of `82852615…` and the first is swallowed by the
  replay-protection set — `applied` 7 → 6, root `c7354b4b…`, and one line of `ignored_reasons`
  reading "message already applied". Every message served is individually valid and the set is
  complete, so comparing message lists against a second indexer does not catch it.

So the wallet recomputes the id:

```
msg_id = BLAKE2b-256("nightjar.msg.v0" ‖ channel_id ‖ [VERSION, kind] ‖ count_le ‖ body)
```

`nightjar::replay::check_binding` runs this over every message before any of them reaches the
state machine, and a mismatch **fails the whole call** rather than skipping the message. Skipping
would hand the attacker the suppression they were after and hide it in a count the UI shows as
ordinary channel spam; an honest source cannot produce a mismatch at all, since the reassembler
computes the same hash and will not complete a message that fails it (all 350 messages on the
devnet channel recompute exactly). `count` is the fragment count, which `/api/messages` serves as
`fragments` — it is hashed into the id, so `NjMessageInput.fragments` is required and must be
passed through verbatim.

What remains is withholding. The indexer can serve fewer messages than the channel carries, and
nothing in the replay notices; comparing `state_root` against a second verifier is what catches
it, which is exactly why the id binding above has to hold. **That is the documented limit of this
cut.**

## Identity

A Nightjar account is derived from raw seed bytes by a BLAKE2b path that has nothing
to do with ZIP 32 (`nightjar_zk::keys::Account::from_seed`). The wallet feeds it the
same seed it already holds, so the Nightjar identity comes along with the wallet with
no extra backup:

```
ask  = Fr(BLAKE2b-512("nightjar.key.v0.ask." ‖ "spend" ‖ seed))
nk   = Fq(BLAKE2b-512("nightjar.key.v0.nk"   ‖ seed))
ivk  = Fr(BLAKE2b-512("nightjar.key.v0.ivk"  ‖ seed))
address = bech32m(hrp, 0x00 ‖ ak ‖ nkc ‖ pk_enc)     hrp = njreg | njtest | nj
```

Two keys do two different jobs, and the PoC keeps them apart:

- the **channel** UIVK is public and says *where to look*;
- the account's own **`ivk`** says *what is mine* — it trial-decrypts the ciphertexts
  inside the messages the channel carries.

## Layers

```
Dart   NightjarIndexerClient ── /api/status /api/vk /api/messages?body=1
          │                                        (data availability only)
          ▼
FRB    nightjarReplay(messages, vk, seed, …) ──► NjView { assets, notes, roots, vk_hash }
          │                     rebind every msg_id, verify every proof, replay state,
          │                     decrypt with ivk
          ▼
FRB    nightjarBuildPay(…) ──► memos: List<Uint8List>     (Groth16 prove, framing)
          │
          ▼
Rust   proposeSendRaw(outputs with raw memo bytes) ──► existing execute/broadcast
```

## Proving

Verifying is cheap and the wallet always does it: the verifying key is 1 784 bytes, served by the
indexer at `/api/vk`, and a proof costs about 3 ms. The wallet checks the key three ways before it
believes anything: `/api/vk`'s hash against the one `/api/status` publishes, and both against
`NjView.vk_hash` — the hash of the key the replay *actually* verified against.

Be precise about what that buys. Comparing two values a single server hands over catches an
inconsistent server, not a dishonest one; a server that lies can lie consistently. The pin is
worth something against a **second** source, or against a value the user holds out of band, and
this PoC provides neither. What the check does do is make the wrong-key case loud rather than
silent: a key from another ceremony makes every proof fail, and without the comparison that
arrives as a clean, confident, empty asset list.

The hash the wallet pins with is on the result: `NjView.vk_hash`, lowercase hex of the
`BLAKE2b-256` of the compressed key it actually verified against. Fetching the key and the hash
from the same server pins nothing by itself — the value is worth something against a *second*
source, or against one the user holds out of band — but without it on the struct no caller could
pin anything at all. `Groth16Verifier::from_vk_bytes` also rejects a buffer with trailing bytes:
the hash is over the whole buffer while the arkworks deserializer stops at the end of the key, so
`vk` and `vk ‖ "\n"` used to load identically and report two different identities for one key.

*Making* a proof is the expensive half: the proving key is ~83 MiB and one proof costs about 1.3 s
and ~600 MB of peak memory on a laptop (2.5 s on an iPhone 16 Pro, measured on an older circuit).
Nothing serves that key over HTTP, and nothing should — it is not secret, but it is large and it
is only needed by someone who intends to spend.

**Sending has no UI.** Both layers below it exist. The transport is `propose_send_raw` and
`build_send_request_raw`, which carry arbitrary 512-byte memos through this wallet's own proposal
and broadcast path, plus `get_transaction_raw_memos` to read them back without the UTF-8 narrowing
that silently drops every binary memo. Above them, `nightjar_build_pay` (`rust/src/nightjar/pay.rs`)
turns "pay N units of asset A to nj-address R" into those memos: it replays the channel through the
same verified path the read side uses, selects inputs honouring the policy each note is actually
openable under, builds the recipient and change outputs, proves and signs the transition, and frames
the body into 1-8 memos of exactly 512 bytes. It returns them; it does not broadcast, and it never
touches the network. What is absent is the screen that calls both — and nothing in the app calls
either function yet.

All the memos of one payment must ride **one** transaction: a reader reassembles a message only from
fragments sharing a txid, so a payment whose memos were split across two sends is undecodable and
the value carrying it is gone. `propose_send_raw` takes the whole list for that reason. Each memo is
an ordinary shielded output to the *channel's* address and so must carry value of its own — 10 000
zatoshi, the reference CLI's default — which is the one cost of a Nightjar payment denominated in
something other than the asset being paid.

The proving key is what makes this expensive, and the shape this PoC assumes is a **file path in
settings** pointing at the folder holding `interpreter-v0.pk`, `.vk` and `.circuit`
(`.devnet/keys` on the devnet), with sending unavailable and visibly so until it is set.
`nightjar_check_proving_key` is what a settings screen validates that path with: it reads the 1.8 KiB
verifying key and the one-line manifest and only `stat`s the 83 MiB proving key, and it returns the
folder's `vk_hash` so the screen can compare it with `NjView.vk_hash` — a key set from another
ceremony shares the same `circuit` fingerprint and produces proofs every verifier on the channel
rejects, which would otherwise be discovered after the user had paid the Zcash fee to carry one.
`nightjar_build_pay` refuses that mismatch itself as well, before it loads the proving key. The key
is read and dropped inside the call rather than cached, so its ~83 MiB and the ~600 MB peak of the
proof are transient rather than a permanent floor. A shipping wallet would download the key once and
cache it; that is a packaging decision, not a protocol one.

## What this PoC does and does not do

**It does:** derive the wallet's Nightjar identity from the seed it already holds, read a channel
from the indexer, verify every Groth16 proof locally, replay the state machine to the same state
root a full verifier computes, decrypt the ciphertexts with the wallet's own key, and show the
assets and notes that come back — with issued supply for public assets and nothing invented for
private ones.

**It reports what it has spent, not only what it holds.** `NjView.notes` is every note the wallet
has ever owned on the channel, spent ones marked and each naming the `msg_id` that created it and
the `msg_id` that consumed it (`rust/src/nightjar/owned.rs`). Without the second half a payment
left only its change behind, and change with no input beside it reads as money arriving. Grouping
by `msg_id` recovers the payment: owning *every* input of a message means this wallet signed it,
and what left is the inputs less the outputs it kept. `NjAsset.balance` counts the unspent notes
alone and is unchanged by any of this. What stays out of reach is who was paid — the other outputs
of a message are ciphertexts addressed to keys this wallet has not got, so `created_outputs` says
one exists and nothing says what is in it.

**It does not:** send — there is no UI for it. The Rust half is there and tested
(`nightjar_build_pay`); nothing calls it. See "Proving" above.

**It cannot notice** an indexer that withholds a message. Everything else it is handed is checked:
the channel id against the configured UIVK, each `msg_id` recomputed from its own body, every
proof against a key whose hash is compared three ways, and the resulting state root against the
one the indexer publishes for the same height. Withholding is the residue, and the state-root
comparison is where it would show if a second source were available to compare against.

**ZEC claims are verified**, as of the claim oracle. Checking one means summing the Ironwood
outputs of the Zcash transaction that carried the message which decrypt under the claimed key,
against a per-`(transaction, account)` budget so one payment cannot fund two claims
(`transition-v0.md` section 6 step 6b, F24). `rust/src/nightjar/zec.rs` does that — a **port** of
`nightjar-scanner`'s `PaidClaims`, which cannot be linked here because it pulls upstream
librustzcash — and `rust/src/nightjar/carrier.rs` gets the transaction from this wallet's own
database or its own lightwalletd `GetTransaction`, never from the indexer. The fetched bytes are
bound to the message before anything is read out of them: the transaction's Ironwood actions are
trial-decrypted with the channel key and must contain that message's own fragments, so a
substituted transaction cannot pass.

What is still refused, and says so: a claim whose carrying transaction **could not be fetched** —
no lightwalletd, an unsynced wallet — is not paid, which is the pre-oracle behaviour and the
deliberate fail-closed direction. The outcome carries "could not be checked: …" and `NjView`
reports `zec_unverifiable`, so "I could not look" never renders as "the network says unpaid". A
non-zero count also explains a state-root mismatch that is the wallet's own fault rather than the
indexer's.

**One identity per wallet, not per account.** `Account::from_seed` takes no ZIP 32 index, so every
Vizor account sharing a mnemonic shares one Nightjar address. That is upstream's derivation.

## Devnet

The wallet points at the regtest devnet from `infra/README.md` in the Nightjar repo:

| | |
|---|---|
| lightwalletd (Zaino) | `http://127.0.0.1:28137` |
| Nightjar indexer | `http://127.0.0.1:8787` |
| channel birthday | 2 |
| finality depth | 10 blocks — a received asset is invisible until it is that deep |

The replay only ever considers `[birthday, tip − 10]`, which is the range `nightjar-scanner` is
handed. A message completing above that is preview and is held back and counted
(`NjView.preview_messages`); a message completing *below* the birthday is refused outright,
because no reference verifier replays that block and silently dropping it would be a second way
for a message set to differ from the scanner's with the root still looking authoritative.

Build the app with:

```
--dart-define=ZCASH_DEFAULT_NETWORK=regtest
--dart-define=ZCASH_REGTEST_IRONWOOD_ACTIVATION_HEIGHT=2
```

The second define is not optional. This wallet keeps regtest Orchard-only unless a height is
configured (`rust/src/wallet/network.rs`, `DEFAULT_REGTEST_NU6_3_ACTIVATION_HEIGHT = u32::MAX`),
and Nightjar memos ride Ironwood outputs — without it the wallet sees none of them.

The two networks disagree about height 1: this wallet puts NU5 through NU6.2 there, the devnet's
Zebra puts Canopy there and NU5 through NU6.3 at height 2. It does not matter in practice — the
disagreement is confined to block 1, which carries only a coinbase, and from height 2 up both
sides agree that NU6.3 is active — but it is the kind of mismatch that produces an unreadable
transaction rather than an error message, so it is written down here rather than discovered
twice.
