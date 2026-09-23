# Nyctis in Vizor — proof of concept

A PoC that lets this wallet **hold and pay** Nyctis assets on the regtest devnet: list what it
owns, verify it for itself, show its Nyctis receive address, and pay an asset to another Nyctis
address with a proven transition — see "Sending" and "What this PoC does and does not do" below.

Nyctis is a client-verified overlay on Zcash. Its messages ride inside ordinary
Ironwood shielded memos addressed to a public *channel*, and every participant
replays the channel to reach the same state. Nothing is enforced by consensus, so a
wallet that wants to believe a balance has to verify the proofs itself.

## The cut

Three Nyctis crates carry **no zcash dependency at all** and are linked into
`rust_lib_zcash_wallet` directly, plus the two upstream crates they need:

| crate | what it gives us |
|---|---|
| `nyctis-codec` | the wire format: memo framing, message reassembly, `Transition` encode/decode, the policy tree |
| `nyctis-state` | the deterministic verifier: apply messages, nullifier set, commitment tree, asset registry |
| `nyctis-zk` | keys and addresses, note encryption, Groth16 prove/verify |
| `decaf377-rdsa`, `bech32` | the curve signatures and address encoding those need — published crates, not Nyctis's |

They are **path dependencies into the Nyctis repo**
(`rust/Cargo.toml`: `path = "../../nyctis/crates/nyctis-codec"` and the other two), so this
checkout expects the protocol repository beside it at `../nyctis`; cloned alone it gives a tree
that does not build. There is no `nyctis-tx` dependency: the one transition this wallet builds, a
plain payment (`rust/src/nyctis/pay.rs`, see "Sending"), is built with `nyctis-zk`'s own
transition builder and prover.

`nyctis-scanner`, `nyctis-chain` and `nyctis-wallet` are **deliberately left
out**. They depend on upstream librustzcash, which would put a second, incompatible
Zcash stack beside the Zakura forks this wallet is built on — two `orchard` crates,
two `zcash_client_sqlite` migration sets over one database file. Every Zcash-shaped
job Nyctis needs is done with this wallet's own stack instead:

- **getting the messages** — the Nyctis indexer's HTTP API, fetched from Dart
  through `NetworkHttpClient` so the Tor route policy still applies.
- **sending a message** — this wallet's own proposal/broadcast path, extended with a
  raw-memo output (a Nyctis memo is binary and starts with `0xFF`, so the existing
  text-memo path drops it).

What the indexer gives us is *data availability*, not trust: it hands over message
bodies and the verifying key, and the wallet verifies every Groth16 proof and
recomputes the whole state locally.

Verifying the proofs is necessary and it is not sufficient. A message arrives with a
`msg_id`, and **nothing in the proof covers it** — the proof commits to the transition's field
elements, `tx.sighash` commits to `channel_id ‖` the body without its signature fields, and
neither mentions the id. Meanwhile `nyctis_state::State::apply` uses `msg_id` as its
replay-protection key and enters it in the `Applied` set, whose sparse-Merkle root is folded into
`state_root` (`nyctis.state.v2`). Taking it on the indexer's word therefore gave the indexer a
free hand on the one number two verifiers are supposed to compare. Both halves were reproduced
against the live devnet of the time. The ids, roots and counts below are **an illustration from
that earlier chain** (the pre-revision-12 devnet, whose channel carried 350 messages under the old
`nightjar.*` separators); that devnet has since been reset and spec revision 12 renamed every
`msg_id` and root, so they cannot be reproduced today:

- rename applied message `82852615…` to `00…00` and `state_root` moves from `2adf95cd…` to
  `85b0349c…` with every proof still verifying, `applied` still 7 and the balance still 100;
- give applied message `ea47c855…` the `msg_id` of `82852615…` and the first is swallowed by the
  replay-protection set — `applied` 7 → 6, root `c7354b4b…`, and one line of `ignored_reasons`
  reading "message already applied". Every message served is individually valid and the set is
  complete, so comparing message lists against a second indexer does not catch it.

Both attacks are pinned against the current recording
(`rust/tests/fixtures/nyctis/devnet-channel.json`) by
`replay::tests::renaming_an_applied_message_is_refused_rather_than_producing_a_second_root` (which
first shows the rename moves the root, then that `replay` refuses it) and
`replay::tests::reusing_one_applied_messages_id_for_another_is_refused_rather_than_suppressing_it`.

So the wallet recomputes the id:

```
msg_id = BLAKE2b-256("nyctis.msg.v0" ‖ channel_id ‖ [VERSION, kind] ‖ count_le ‖ body)
```

`nyctis::replay::check_binding` runs this over every message before any of them reaches the
state machine, and a mismatch **fails the whole call** rather than skipping the message. Skipping
would hand the attacker the suppression they were after and hide it in a count the UI shows as
ordinary channel spam; an honest source cannot produce a mismatch at all, since the reassembler
computes the same hash and will not complete a message that fails it (all 67 messages the devnet
indexer served on 23 September 2026, at tip 3997, recompute exactly, as do all 59 of the recorded
fixture channel and all 26 of the claims fixture). `count` is the fragment count, which `/api/messages` serves as
`fragments` — it is hashed into the id, so `NyMessageInput.fragments` is required and must be
passed through verbatim.

What remains is withholding. The indexer can serve fewer messages than the channel carries, and
nothing in the replay notices; comparing `state_root` against a second verifier is what catches
it, which is exactly why the id binding above has to hold. **That is the documented limit of this
cut.**

## Identity

A Nyctis account is derived from raw seed bytes by a BLAKE2b path that has nothing
to do with ZIP 32 (`nyctis_zk::keys::Account::from_seed`). The wallet feeds it the
same seed it already holds — the 64-byte **BIP39 seed**, passphrase applied, which
`rust/src/nyctis/keys.rs` `account_from_mnemonic` obtains through the wallet's own
`mnemonic_bytes_to_seed` — so the Nyctis identity comes along with the wallet with no extra
backup:

```
ask  = Fr(BLAKE2b-512("nyctis.key.v0.ask." ‖ "spend" ‖ seed))    (the issuance key uses "issue")
nk   = Fq(BLAKE2b-512("nyctis.key.v0.nk"   ‖ seed))
ivk  = Fr(BLAKE2b-512("nyctis.key.v0.ivk"  ‖ seed))
address = bech32m(hrp, 0x00 ‖ ak ‖ nkc ‖ pk_enc)     hrp = nyreg | nytest | ny
```

The BIP39 seed never reaches Dart and the read path never sees it. The stored secret (the
mnemonic, or the JSON envelope a passphrase wallet stores) does pass through Dart once: the first
time a Nyctis screen needs a key after an unlock, `NyctisViewingKeyCache`
(`services/nyctis_view_loader.dart`) reads it through
`AccountNotifier.getMnemonicBytesForAccount`, issues `nyctis_viewing_key` with it and zeroes its
own copy before awaiting the result. Rust turns it into the seed, derives the account and returns
only its **viewing key** (`ak ‖ nk ‖ ivk`, 96 bytes), the receive address and the public `ak` and
`nkc`, zeroizing the input and the seed. The wallet caches that key in memory, one per account
and network, hands it to every replay, and zeroes it when the lock state changes. It cannot sign.
Only paying needs the spend key: the send pipeline reads the stored secret the same way, after
its network reads, for the one `nyctis_build_pay` call, zeroes its copy as soon as the call is
issued, and Rust drops the derived account when the call returns.

Two keys do two different jobs, and the PoC keeps them apart:

- the **channel** UIVK is public and says *where to look*;
- the account's own **`ivk`** says *what is mine* — it trial-decrypts the ciphertexts
  inside the messages the channel carries.

## Layers

```
Dart   NyctisIndexerClient ── /api/status /api/vk /api/messages?body=1
          │                                        (data availability only)
          ▼
FRB    nyctisChannelId(uivk, address) ──► channel_id   (checked against /api/status)
FRB    nyctisViewingKey(secret) ──► NyViewingKey      (once per account per unlock, memory only)
          │
FRB    nyctisReplay(messages, vk, vkPin, viewingKey, …) ──► NyView { assets, notes, roots, vk_hash }
          │                     check vk against the pin, rebind every msg_id, verify every
          │                     proof, replay state, decrypt with ivk
          ▼
FRB    nyctisBuildPay(secret, …) ──► NyPayPlan { memos, … }   (replay, Groth16 prove, framing)
          │
          ▼
Rust   proposeSendRaw(outputs with raw memo bytes) ──► existing execute/broadcast
```

## Proving

Verifying is cheap and the wallet always does it: the verifying key is 1 880 bytes (circuit v0.4
and the current v0.5, spec revision 12; the devnet's `interpreter-v0.vk` measures 1,880 B),
served by the indexer at `/api/vk`, and a proof costs about 3 ms to verify (3.1-3.3 ms, circuit
v0.4, MacBook Pro M4 Pro). Before it believes anything the wallet checks the key against a hash
the indexer does not supply: the channel configuration's **pinned `vk_hash`**
(`NyctisConfig.vkPin` — the compiled-in `NYCTIS_REGTEST_VK_PIN` default, which
`scripts/build-macos-devnet.sh` sets from the devnet's `interpreter-v0.circuit` manifest).
`nyctis_replay` and `nyctis_build_pay` refuse any key that does not hash to it
(`trust::check_vk_pin`) before a single proof is verified, and an empty pin refuses every key.
Dart then makes two consistency checks: `/api/vk`'s hash against the one `/api/status`
publishes, and `NyView.vk_hash` — the hash of the key the replay *actually* verified against —
against that same published value.

Be precise about what that buys. Comparing two values a single server hands over catches an
inconsistent server, not a dishonest one; a server that lies can lie consistently. The pin is what
is worth something, because it is a value the build holds out of band rather than one the indexer
hands over; it is only as good as the channel of whoever set it, which on the devnet is the local
key manifest. Together the pin and the comparisons make the wrong-key case loud rather than
silent: a key from another ceremony makes every proof fail, and without a check that arrives as a
clean, confident, empty asset list — which is why a replay that applied nothing and ignored
something is also reported as unverified rather than as an empty wallet.

The hash the replay verified with is on the result: `NyView.vk_hash`, lowercase hex of the
`BLAKE2b-256` of the compressed key it actually verified against, so a caller can report the
identity it checked and the proving-key settings can compare against it.
`Groth16Verifier::from_vk_bytes` also rejects a buffer with trailing bytes:
the hash is over the whole buffer while the arkworks deserializer stops at the end of the key, so
`vk` and `vk ‖ "\n"` used to load identically and report two different identities for one key.

*Making* a proof is the expensive half: the proving key is ~83 MiB (82.6 MiB measured for circuit
v0.4; the devnet's current v0.5 `interpreter-v0.pk` is 86,696,400 B, 82.7 MiB), and one proof
costs about 1.2 s (1.19 s) with a staged prove-only peak of about 590 MiB on a MacBook Pro M4 Pro,
12 threads, circuit v0.4 (v0.5 adds 105 constraints and has not been re-benchmarked). On an
iPhone 16 Pro, measured on the older circuit v0.1: 2.54 s and a 648 MB peak.
Nothing serves that key over HTTP, and nothing should — it is not secret, but it is large and it
is only needed by someone who intends to spend.

**The transport.** `propose_send_raw` (`rust/src/api/sync.rs`, over the internal
`build_send_request_raw` in `rust/src/wallet/sync/send.rs`) carries arbitrary memos of up to 512
bytes, byte for byte, through this wallet's own proposal and broadcast path, and
`get_transaction_raw_memos` reads them
back without the UTF-8 narrowing that silently drops every binary memo. Above them,
`nyctis_build_pay` (`rust/src/nyctis/pay.rs`) turns "pay N units of asset A to ny-address R" into
those memos: it replays the channel through the same verified path the read side uses, selects
inputs honouring the policy each note is actually openable under, builds the recipient and change
outputs, proves and signs the transition, and frames the body into 1-8 memos of exactly 512 bytes.
It returns them and does not broadcast. The only network it can touch is the one the replay
touches: for a message carrying a ZEC claim it fetches the carrying Zcash transaction from this
wallet's own database or its own lightwalletd (`GetTransaction`) — never the indexer, and nothing
at all on a channel without claims. The app's send pipeline
(`lib/src/features/nyctis_assets/services/nyctis_send_flow.dart`) is what calls both — see
"Sending" below.

All the memos of one payment must ride **one** transaction: a reader reassembles a message only from
fragments sharing a txid, so a payment whose memos were split across two sends is undecodable and
the value carrying it is gone. `propose_send_raw` takes the whole list for that reason. Each memo is
an ordinary shielded output to the *channel's* address and so must carry value of its own — 10 000
zatoshi (`pay::MEMO_OUTPUT_VALUE_ZATOSHI`, reported as `NyPayPlan.memo_value_zatoshi`), the
reference CLI's `nyctis wallet pay --value` default — which is the one cost of a Nyctis payment denominated in
something other than the asset being paid.

The proving key is what makes this expensive, and the shape this PoC assumes is a **file path in
settings** pointing at the folder holding `interpreter-v0.pk`, `.vk` and `.circuit`
(`.devnet/keys` on the devnet), with sending unavailable and visibly so until it is set.
It is set in **Settings → Nyctis → Sending → Proving key folder**, and `nyctis_check_proving_key` is what
validates it: it reads the 1.8 KiB
verifying key and the one-line manifest and only `stat`s the 83 MiB proving key, and it returns the
folder's `vk_hash` so the screen can compare it with `NyView.vk_hash` — a key set from another
ceremony shares the same `circuit` fingerprint and produces proofs every verifier on the channel
rejects, which would otherwise be discovered after the user had paid the Zcash fee to carry one.
`nyctis_build_pay` refuses that mismatch itself as well, before it loads the proving key. The key
is read and dropped inside the call rather than cached, so its ~83 MiB and the ~590 MiB peak of
the proof are transient rather than a permanent floor. A shipping wallet would download the key once and
cache it; that is a packaging decision, not a protocol one.

## Sending

**Nyctis → an asset → Send Nyctis asset.** The button is offered on the asset detail screen when
the balance is above zero. The flow has three screens (`screens/nyctis_send_screen.dart`,
`nyctis_send_review_screen.dart`, `nyctis_send_status_screen.dart`, each wrapped for mobile in
`screens/mobile/`):

1. **Compose** (`/nyctis/:assetId/send`): the recipient's Nyctis address, checked against this
   network's prefix (`nyreg1…` on the devnet), and the amount in the asset's own decimals (a
   decimal comma is read as a decimal point; the amount may not exceed the balance, and **Use
   max** stops at the two largest unspent notes, the circuit's input limit). Pressing **Review
   payment** is what builds the plan: the channel is read fresh from the indexer and
   `nyctisBuildPay` replays it, verifies every proof and proves the payment, with the back control
   withheld while it runs. Nothing is spent yet.
2. **Review** (`/nyctis/send/review`): shows the plan, and quotes its ZEC cost by proposing exactly
   the outputs the broadcast will and releasing the proposal at once. Each memo is a shielded
   output to the *channel's* address carrying `NyPayPlan.memo_value_zatoshi` (10 000 zatoshi),
   plus the Zcash network fee; the recipient of the asset receives no ZEC. The quoted fee becomes a
   ceiling: a proposal that costs more at send time is released unsigned. A plan is anchored at
   `tip − 10` and ages out of the anchor window (200 blocks, `nyctis_state::ANCHOR_WINDOW`; the
   screen warns in the last 40), so an expired plan — or one built for a channel address that
   settings have since changed — cannot be sent: **Confirm & send** is replaced by **Rebuild
   payment**, which proves again in place. A plan whose message was already broadcast is not
   offered again.
3. **Sending → receipt** (`/nyctis/send/status`): the payment is recorded as in flight, then one
   `proposeSendRaw` call carries every memo of the payment in one transaction and
   `executeProposal` signs and broadcasts it. While it is live there is no back link, system back
   is refused and **Back to Nyctis assets** is disabled; afterwards every exit goes to the assets
   list, never back to the review. The receipt shows the amount, the recipient, the ZEC paid to
   the channel, the memo count, the message id and the carrying transaction, and says that the
   channel applies the payment only once that transaction is 10 blocks deep. **Try again** is
   offered only when nothing was broadcast and the plan has not expired.

The composer's **Review payment** is disabled, with the reason beside it, before any proof is
started (`providers/nyctis_send_readiness_provider.dart`): a hardware account (a Nyctis payment is
proved from the seed, which a hardware account keeps on the device), a missing or mismatched
proving key (the only reason with an **Open Nyctis settings** action), a payment of the same
asset still settling (`providers/nyctis_in_flight_send_provider.dart` — until it is final, the
notes it spent still look unspent to the replay, so a second payment could pick them again), and
too little spendable ZEC to carry even the smallest message (20 000 zatoshi: one memo's
10 000 plus the 10 000 ZIP 317 minimum fee, a lower bound; the review then quotes the real figure).
The asset detail screen's **Send Nyctis asset** button checks only the proving key; the other
three reasons appear once the composer is open.

## What this PoC does and does not do

**It does:** derive the wallet's Nyctis identity from the seed it already holds, read a channel
from the indexer, verify every Groth16 proof locally, replay the state machine to the same state
root a full verifier computes, decrypt the ciphertexts with the wallet's own key, and show the
assets and notes that come back — with issued supply for public assets and nothing invented for
private ones.

**It reports what it has spent, not only what it holds.** `NyView.notes` is every note the wallet
has ever owned on the channel, spent ones marked and each naming the `msg_id` that created it and
the `msg_id` that consumed it (`rust/src/nyctis/owned.rs`). Without the second half a payment
left only its change behind, and change with no input beside it reads as money arriving. Grouping
by `msg_id` recovers the payment: owning *every* input of a message means this wallet signed it,
and what left is the inputs less the outputs it kept. `NyAsset.balance` counts the unspent notes
alone and is unchanged by any of this. What stays out of reach is who was paid — the other outputs
of a message are ciphertexts addressed to keys this wallet has not got, so `created_outputs` says
one exists and nothing says what is in it.

**It sends**, as described in "Sending": a payment of one asset to one Nyctis address, proved on
the device with the proving key from settings. **It does not** download that key (it must be put
on disk and chosen in settings), sign with a hardware account, or build the other programs the
protocol can express (offers, sales for ZEC, timelocks — the CLI's `--expires` deadline is not
exposed either — or a cross-channel export): only a plain payment, with change back to this
wallet.

**It cannot notice** an indexer that withholds a message. Everything else it is handed is checked:
the channel id against the configured UIVK (and the configured channel address against that
UIVK), each `msg_id` recomputed from its own body, every proof against a key that must hash to the
channel's pinned `vk_hash` and whose hash is also compared with the one the indexer publishes, and
the resulting state and tree roots against the ones the indexer publishes for the same height
(when it has settled one there). Withholding is the residue, and the state-root
comparison is where it would show if a second source were available to compare against.

**ZEC claims are verified**, as of the claim oracle. Checking one means summing the Ironwood
outputs of the Zcash transaction that carried the message which decrypt under the claimed key,
against a per-`(transaction, account)` budget so one payment cannot fund two claims
(`transition-v0.md` section 6 step 6b, F24). `rust/src/nyctis/zec.rs` does that — a **port** of
`nyctis-scanner`'s `PaidClaims`, which cannot be linked here because it pulls upstream
librustzcash — and `rust/src/nyctis/carrier.rs` gets the transaction from this wallet's own
database or its own lightwalletd `GetTransaction`, never from the indexer. The fetched bytes are
bound to the message before anything is read out of them: the transaction's Ironwood actions are
trial-decrypted with the channel key and must contain that message's own fragments, so a
substituted transaction cannot pass.

What is still refused, and says so: a claim whose carrying transaction **could not be fetched** —
no lightwalletd, an unsynced wallet — is not paid, which is the pre-oracle behaviour and the
deliberate fail-closed direction. The outcome carries "could not be checked: …" and `NyView`
reports `zec_unverifiable`, so "I could not look" never renders as "the network says unpaid". A
non-zero count also explains a state-root mismatch that is the wallet's own fault rather than the
indexer's.

**One identity per wallet, not per account.** `Account::from_seed` takes no ZIP 32 index, so every
Vizor account sharing a mnemonic shares one Nyctis address. That is upstream's derivation.

## Devnet

The wallet points at the regtest devnet from `infra/README.md` in the Nyctis repo:

| | |
|---|---|
| lightwalletd (the wallet's own sync) | `http://127.0.0.1:19067` — upstream lightwalletd v0.5.4 from `infra/lwd/`, a second reader against the devnet's Zebra |
| Zaino | `127.0.0.1:28137` — used by Nyctis's own scanner and indexer, **not** by this wallet: Zaino 0.6.0 rejects `GetSubtreeRoots` for Ironwood and a fresh wallet sync fails |
| Nyctis indexer | `http://127.0.0.1:8787` |
| channel birthday | 2 |
| finality depth | 10 blocks — a received asset is invisible until it is that deep |

The replay only ever considers `[birthday, tip − 10]`, which is the range `nyctis-scanner` is
handed. A message completing above that is preview and is held back and counted
(`NyView.preview_messages`); a message completing *below* the birthday is refused outright,
because no reference verifier replays that block and silently dropping it would be a second way
for a message set to differ from the scanner's with the root still looking authoritative.

`scripts/build-macos-devnet.sh` builds a signed debug macOS app for this devnet. The defines that
matter for Nyctis are:

```
--dart-define=ZCASH_DEFAULT_NETWORK=regtest
--dart-define=ZCASH_REGTEST_IRONWOOD_ACTIVATION_HEIGHT=2
--dart-define=VIZOR_NYCTIS_ENABLED=true
--dart-define=ZCASH_E2E_LIGHTWALLETD_URL=http://127.0.0.1:19067
```

plus `NYCTIS_REGTEST_CHANNEL_UIVK`, `NYCTIS_REGTEST_CHANNEL_ADDRESS` and `NYCTIS_REGTEST_VK_PIN`,
which the script reads from the live devnet (`.devnet/channel` and
`.devnet/keys/interpreter-v0.circuit` in the Nyctis repository) and omits when there is none, so
the compiled-in defaults stand. Those defaults (`lib/src/core/config/nyctis_config.dart`) are the
recorded fixture's channel (`channel_id 708443a8…`) and the current key's pin (`a8600f30…`). On
23 September 2026 the devnet indexer on 8787 served a different channel (`9264c0bf…`), so a build
without the channel defines reports that its indexer serves another channel. `VIZOR_NYCTIS_ENABLED` is the build switch; the user still turns
the feature on in **Settings → Nyctis → Nyctis assets**, which is off by default.
`ZCASH_E2E_LIGHTWALLETD_URL` is honoured only in debug builds; the default regtest endpoint
(`127.0.0.1:9067`) has nothing behind it on this devnet.

The Ironwood define is not optional. This wallet keeps regtest Orchard-only unless a height is
configured (`rust/src/wallet/network.rs`, `DEFAULT_REGTEST_NU6_3_ACTIVATION_HEIGHT = u32::MAX`),
and Nyctis memos ride Ironwood outputs — without it the wallet sees none of them.

The two networks disagree about height 1: this wallet puts NU5 through NU6.2 there, the devnet's
Zebra puts Canopy there and NU5 through NU6.3 at height 2. It does not matter in practice — the
disagreement is confined to block 1, which carries only a coinbase, and from height 2 up both
sides agree that NU6.3 is active — but it is the kind of mismatch that produces an unreadable
transaction rather than an error message, so it is written down here rather than discovered
twice.
