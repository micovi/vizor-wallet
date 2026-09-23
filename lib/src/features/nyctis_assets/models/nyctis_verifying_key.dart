import 'dart:typed_data';

import 'nyctis_json.dart';

/// `GET /api/vk` — the Groth16 verifying key the wallet checks every proof
/// with.
///
/// Fetching this from the indexer is data availability, not trust: [vkHash] is
/// meant to be compared against a hash pinned somewhere that is not this
/// server, and the bytes are only usable once it matches.
class NyctisVerifyingKey {
  const NyctisVerifyingKey({
    required this.vkHash,
    required this.vk,
    required this.circuit,
    required this.circuitVersion,
  });

  /// BLAKE2b-256 over the compressed verifying-key bytes, lowercase hex.
  final String vkHash;

  /// The compressed verifying-key bytes themselves.
  final Uint8List vk;

  /// Circuit fingerprint. A fingerprint, not an identity.
  final String circuit;

  final int circuitVersion;

  int get lengthInBytes => vk.lengthInBytes;

  /// Whether this key came from the indexer described by a `/api/status`
  /// `info.vk_hash`. Equal hashes do not make either one trustworthy; a
  /// mismatch makes both unusable.
  bool matchesVkHash(String expectedVkHash) =>
      vkHash.toLowerCase() == expectedVkHash.toLowerCase();

  factory NyctisVerifyingKey.fromJson(Map<String, Object?> json) {
    return NyctisVerifyingKey(
      vkHash: nyctisString(json, 'vk_hash'),
      vk: nyctisHexBytes(json, 'vk'),
      circuit: nyctisString(json, 'circuit'),
      circuitVersion: nyctisInt(json, 'circuit_version'),
    );
  }
}
