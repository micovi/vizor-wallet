# This fork

`micovi/vizor-wallet` is a fork of [Vizor](https://github.com/chainapsis/vizor-wallet), the
self-custody Zcash wallet by Chainapsis, released under the Apache License 2.0 ([LICENSE](LICENSE)).
We use it as the wallet for **Nyctis**, a client-verified layer for small private programs carried
by Zcash shielded memos. Everything Vizor does, this fork does the same way; Nyctis is an addition,
not a replacement.

It is not an official Vizor build, it is not endorsed by Chainapsis, and problems found here should
be reported here, not upstream, unless they reproduce on an unmodified Vizor.

## Branches

| Branch | What it is |
|---|---|
| `main` | An exact mirror of `chainapsis/vizor-wallet` `main`. It never carries a commit of ours, so it can always be fast-forwarded. |
| `nyctis-poc` | Vizor plus Nyctis. Upstream `main` is merged into it regularly; our changes are commits on top. |

## What this fork adds

All of it sits behind a build-time switch, `--dart-define=VIZOR_NYCTIS_ENABLED=true`, off by
default: without it the app behaves exactly like upstream (no Nyctis routes, reads or rows).

- **Reading a Nyctis channel.** The wallet fetches messages from a Nyctis indexer, recomputes every
  message id, verifies every Groth16 proof and replays the channel itself, so the indexer supplies
  data, not trust. The read path uses a viewing key derived once per unlock and kept in memory
  only; it never takes the seed.
- **Holding and paying Nyctis assets.** Balances, collections (with the cap bound into the
  collection id), metadata documents shown only after the user accepts them, and payments built as
  proven transitions carried in a raw shielded memo.
- The protocol crates are path dependencies on the Nyctis repository beside this one
  (`../nyctis/crates/nyctis-*`, see `rust/Cargo.toml`); `docs/NYCTIS-POC.md` describes the design,
  the devnet and the limits. No mainnet channel is configured.

Code of ours lives mostly in `lib/src/features/nyctis_assets/`, `rust/src/nyctis/` and
`rust/src/api/nyctis.rs`, so upstream merges stay small.

## Keeping up with upstream

- **Automatically:** `.github/workflows/nyctis-upstream-sync.yml` runs daily. It fast-forwards
  `main` to upstream and, when upstream moved, opens a pull request that merges it into
  `nyctis-poc`. When the merge conflicts it opens an issue instead, naming the files.
- **By hand:** `scripts/nyctis-sync-upstream.sh` does the same locally and goes further: when the
  only conflicts are the generated Flutter Rust Bridge files, it regenerates them, then runs
  `cargo check` and `fvm flutter analyze`.

## Names and marks

The Apache License does not grant rights to the names "Vizor", "Keplr" or "Chainapsis", or to their
logos (section 6). This fork keeps them only where they describe where the code comes from. A build
distributed to users under this fork must carry its own name, icons and application identifiers.
