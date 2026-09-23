//! Nyctis: a client-verified asset overlay on Zcash.
//!
//! Nyctis's messages ride inside ordinary Ironwood shielded memos addressed to a public
//! *channel*, and every participant replays that channel to reach the same state. Nothing about
//! it is enforced by consensus, so a wallet that wants to believe a Nyctis balance has to
//! verify the proofs itself — which is what this module tree does, and the reason it exists at
//! all rather than trusting the indexer's own JSON.
//!
//! The three crates linked here (`nyctis-codec`, `nyctis-state`, `nyctis-zk`) carry no
//! Zcash dependency. `nyctis-scanner`, `nyctis-chain` and `nyctis-wallet` deliberately are
//! not linked: they depend on upstream librustzcash, which would put a second, incompatible Zcash
//! stack beside the Zakura forks this wallet is built on — two `orchard` crates and two
//! `zcash_client_sqlite` migration sets over one database file. Every Zcash-shaped job Nyctis
//! needs is done by this wallet's own stack instead, and the channel-scanning half is done by the
//! Nyctis indexer over HTTP (see `docs/NYCTIS-POC.md`).
//!
//! `nyctis-scanner` not being linkable has one further consequence worth naming here, because
//! it is the largest piece of duplicated logic in the tree: its `PaidClaims` — the ZEC-claim
//! oracle of spec step 6b, which the indexer and the CLI both use — is **ported** into
//! [`zec`] rather than depended on, and the transaction it needs is fetched by [`carrier`] from
//! this wallet's own database and lightwalletd. A port has to be kept honest by test, and the
//! test is `replay::tests`: the recorded devnet channel, claims included, must reach the same
//! `state_root` and the same per-message verdicts as the indexer published for it.

pub mod carrier;
pub mod keys;
pub mod network;
pub mod owned;
pub mod pay;
pub mod replay;
pub mod trust;
pub mod zec;

#[cfg(test)]
pub(crate) mod testdata;
