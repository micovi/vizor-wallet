/// What a Nyctis address looks like on each network, checked in Dart so a
/// typo costs a keystroke rather than a channel read and a proof.
///
/// A Nyctis address is Bech32m with a network prefix (`ny` / `nytest` /
/// `nyreg`, `note-format-v0.md` section 4; Rust's `NyctisNetwork::ny_hrp`).
/// This checks the prefix and the checksum. Whether the payload is a key the
/// circuit accepts is still Rust's to say, inside `nyctisBuildPay` — but a
/// string that fails here can never pass there, so refusing it early is free.
library;

import '../../../core/config/nyctis_config.dart';
import '../../../core/crypto/bech32.dart';

/// The Bech32m prefix of a Nyctis address on [networkName].
String nyctisAddressHrp(String networkName) {
  return switch (zcashNetworkFromName(networkName)) {
    ZcashNetwork.mainnet => 'ny',
    ZcashNetwork.testnet => 'nytest',
    ZcashNetwork.regtest => 'nyreg',
  };
}

/// Placeholder text for a recipient field on [networkName], e.g. `nyreg1…`.
String nyctisAddressHint(String networkName) =>
    '${nyctisAddressHrp(networkName)}1…';

const _nyctisHrps = {'ny': 'Mainnet', 'nytest': 'Testnet', 'nyreg': 'Regtest'};

/// Zcash prefixes a user is likely to paste by mistake. Named, because "not a
/// Nyctis address" sends them hunting for a typo that is not there.
const _zcashHrps = {
  'u',
  'utest',
  'uregtest',
  'zs',
  'ztestsapling',
  'zregtestsapling',
  'tex',
  'textest',
  'texregtest',
};

/// Sentence-case reason [text] cannot be paid on [networkName], or null when
/// it is empty or looks like a Nyctis address for this network.
String? nyctisRecipientError(String text, {required String networkName}) {
  final value = text.trim();
  if (value.isEmpty) return null;
  final expected = nyctisAddressHrp(networkName);
  final example = nyctisAddressHint(networkName);

  // Transparent Zcash addresses are Base58, not Bech32, so name them before
  // the decoder refuses them as "not an address".
  if (RegExp(r'^t[1-9A-HJ-NP-Za-km-z]{20,}$').hasMatch(value) &&
      !value.toLowerCase().startsWith('tex')) {
    return 'This is a Zcash address. A Nyctis payment needs a Nyctis '
        'address, which starts with $example';
  }

  final decoded = decodeBech32m(value);
  if (decoded == null) {
    return 'This is not a Nyctis address. Check it for typos; a Nyctis '
        'address starts with $example';
  }
  if (decoded.hrp == expected) return null;

  final otherNetwork = _nyctisHrps[decoded.hrp];
  if (otherNetwork != null) {
    return 'This is a $otherNetwork Nyctis address. This wallet sends on '
        '${nyctisNetworkLabel(networkName)}, where addresses start with '
        '$example';
  }
  if (_zcashHrps.contains(decoded.hrp)) {
    return 'This is a Zcash address. A Nyctis payment needs a Nyctis '
        'address, which starts with $example';
  }
  return 'This is not a Nyctis address. A Nyctis address starts with '
      '$example';
}
