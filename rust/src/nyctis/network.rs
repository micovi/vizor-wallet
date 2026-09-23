//! The two network-derived constants Nyctis needs, hung off the wallet's own
//! [`WalletNetwork`] rather than off a second enum of our own.
//!
//! Nyctis's reference CLI threads its network through a `Net<P>` value for one reason
//! (`nyctis-cli/src/zk.rs`, F46): the transport's network byte enters `channel_id`, which is
//! public input #1 of every proof, so a single site that reaches for a hardcoded `Regtest`
//! produces a wallet that replays a *different channel* than the one the user named and reports
//! an empty balance with no error anywhere. The same hazard exists here, and the same discipline
//! answers it — but this wallet already has exactly one network value, parsed once at the FFI
//! edge, so introducing a Nyctis-only enum beside it would create the second source of truth
//! the discipline is meant to prevent. An extension trait keeps one value and still makes a
//! missed site a compile error, because nothing downstream of the edge accepts a string.

use nyctis_codec::transport::Network as WireNetwork;

use crate::wallet::network::WalletNetwork;

/// Nyctis's view of a wallet network.
pub trait NyctisNetwork {
    /// The transport's network byte, which enters `channel_id` and therefore every proof.
    fn ny_wire(self) -> WireNetwork;
    /// Bech32m prefix of a Nyctis address on this network (`note-format-v0.md` §4).
    fn ny_hrp(self) -> &'static str;
}

impl NyctisNetwork for WalletNetwork {
    fn ny_wire(self) -> WireNetwork {
        match self {
            WalletNetwork::Main => WireNetwork::Mainnet,
            WalletNetwork::Test => WireNetwork::Testnet,
            WalletNetwork::Regtest => WireNetwork::Regtest,
        }
    }

    fn ny_hrp(self) -> &'static str {
        match self {
            WalletNetwork::Main => "ny",
            WalletNetwork::Test => "nytest",
            WalletNetwork::Regtest => "nyreg",
        }
    }
}

/// Parse the network string the Dart layer passes, once, at the FFI edge.
///
/// The error names the accepted values because the caller is a string literal in Dart that no
/// Rust compiler ever checks; a typo here must not fall back to a default network.
pub fn parse_network(network: &str) -> Result<WalletNetwork, String> {
    WalletNetwork::from_str(network).ok_or_else(|| {
        format!("unknown network {network:?}: expected \"main\", \"test\" or \"regtest\"")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The three networks must map to three distinct wire bytes and three distinct prefixes.
    /// A collision in either direction is the F46 failure: a wallet that silently replays, or
    /// pays into, the wrong network's channel.
    #[test]
    fn every_network_has_its_own_wire_byte_and_prefix() {
        let all = [
            WalletNetwork::Main,
            WalletNetwork::Test,
            WalletNetwork::Regtest,
        ];
        for (i, a) in all.iter().enumerate() {
            for b in &all[i + 1..] {
                assert_ne!(a.ny_wire() as u8, b.ny_wire() as u8);
                assert_ne!(a.ny_hrp(), b.ny_hrp());
            }
        }
        assert_eq!(WalletNetwork::Regtest.ny_hrp(), "nyreg");
        assert_eq!(WalletNetwork::Regtest.ny_wire() as u8, 0x02);
    }

    #[test]
    fn an_unknown_network_string_is_refused_rather_than_defaulted() {
        assert_eq!(parse_network("regtest"), Ok(WalletNetwork::Regtest));
        let e = parse_network("mainnet").unwrap_err();
        assert!(e.contains("mainnet") && e.contains("main"), "{e}");
    }
}
