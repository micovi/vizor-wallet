/// `#b2=` — the pin from section 2.1 of `spec/asset-metadata-v0.md`.
///
/// The signature on an `ASSET` message covers the pointer, not the bytes at
/// the end of it. This is the whole difference between "the issuer published
/// this" and "whoever holds that domain today published this", and it costs
/// nothing on-chain: 43 characters of a field that already exists.
library;

import 'dart:convert';

import 'package:cryptography/dart.dart' show DartBlake2b;

const _blake2b256 = DartBlake2b(hashLengthInBytes: 32);

/// `BLAKE2b-256` of [bytes] as base64url without padding — the exact form a
/// `#b2=` fragment and a `logo.b2` member are written in.
String nightjarB2Digest(List<int> bytes) {
  final digest = _blake2b256.hashSync(bytes).bytes;
  return base64Url.encode(digest).replaceAll('=', '');
}

/// Whether [bytes] hash to [expected].
///
/// Section 2.1 and 4.2: a wallet that finds a digest **MUST** verify it and
/// **MUST** discard a document that does not match, without retrying a
/// different source. Comparison is length-then-constant-time over the string,
/// which matters less here than elsewhere — the attacker already knows the
/// bytes they served — but costs nothing.
bool nightjarB2DigestMatches(String expected, List<int> bytes) {
  final actual = nightjarB2Digest(bytes);
  if (actual.length != expected.length) return false;
  var diff = 0;
  for (var i = 0; i < actual.length; i++) {
    diff |= actual.codeUnitAt(i) ^ expected.codeUnitAt(i);
  }
  return diff == 0;
}
