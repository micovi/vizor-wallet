import 'dart:typed_data';

/// Decoding helpers shared by every Nightjar indexer model.
///
/// Two rules from the indexer's API contract are enforced here rather than at
/// each call site:
///
/// * **u64 amounts are decimal strings, never JSON numbers.** `issued` is
///   folded into `issued_hash` as a `u64`, so a double that rounds above 2^53
///   is a wrong hash with no error attached. [nightjarBigInt] refuses a number.
/// * a missing or wrong-typed field is a [FormatException] with a sentence-case
///   `.message`, not a silent `null`.

/// The shared failure message for a response the wallet cannot read.
const kNightjarUnreadableResponseMessage =
    'The indexer sent a response this wallet could not read.';

Map<String, Object?> nightjarObject(Object? value, String what) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw FormatException('The indexer $what is not an object.');
}

List<Object?> nightjarList(Object? value, String what) {
  if (value is List) return value;
  throw FormatException('The indexer $what is not a list.');
}

String nightjarString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('The indexer response is missing "$key".');
}

String? nightjarStringOrNull(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('The indexer field "$key" is not text.');
}

int nightjarInt(Map<String, Object?> json, String key) {
  final value = nightjarIntOrNull(json, key);
  if (value == null) {
    throw FormatException('The indexer response is missing "$key".');
  }
  return value;
}

int? nightjarIntOrNull(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is int) return value;
  // A whole-number double would silently lose precision above 2^53 and the
  // indexer never sends one, so this is a contract violation either way.
  throw FormatException('The indexer field "$key" is not a whole number.');
}

int nightjarIntOr(Map<String, Object?> json, String key, int fallback) =>
    nightjarIntOrNull(json, key) ?? fallback;

bool nightjarBool(Map<String, Object?> json, String key) {
  final value = nightjarBoolOrNull(json, key);
  if (value == null) {
    throw FormatException('The indexer response is missing "$key".');
  }
  return value;
}

bool? nightjarBoolOrNull(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is bool) return value;
  throw FormatException('The indexer field "$key" is not true or false.');
}

bool nightjarBoolOr(Map<String, Object?> json, String key, bool fallback) =>
    nightjarBoolOrNull(json, key) ?? fallback;

/// Reads a u64 amount that the indexer serializes as a decimal string.
///
/// A JSON number is rejected on purpose: accepting one here is how a balance
/// above 2^53 turns into a wrong number that still looks like a number.
BigInt nightjarBigInt(Map<String, Object?> json, String key) {
  final value = nightjarBigIntOrNull(json, key);
  if (value == null) {
    throw FormatException('The indexer response is missing "$key".');
  }
  return value;
}

BigInt? nightjarBigIntOrNull(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException(
      'The indexer field "$key" must be a decimal string amount.',
    );
  }
  final parsed = BigInt.tryParse(value);
  if (parsed == null || parsed.isNegative) {
    throw FormatException('The indexer field "$key" is not a valid amount.');
  }
  return parsed;
}

/// Decodes lowercase hex into bytes.
Uint8List nightjarHexBytes(Map<String, Object?> json, String key) {
  final value = nightjarHexBytesOrNull(json, key);
  if (value == null) {
    throw FormatException('The indexer response is missing "$key".');
  }
  return value;
}

Uint8List? nightjarHexBytesOrNull(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('The indexer field "$key" is not hex text.');
  }
  return nightjarDecodeHex(value, key);
}

Uint8List nightjarDecodeHex(String hex, String what) {
  if (hex.length.isOdd) {
    throw FormatException('The indexer field "$what" is not valid hex.');
  }
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) {
      throw FormatException('The indexer field "$what" is not valid hex.');
    }
    bytes[i] = byte;
  }
  return bytes;
}
