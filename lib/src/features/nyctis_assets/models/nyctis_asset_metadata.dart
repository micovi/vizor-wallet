/// The asset metadata document (`spec/asset-metadata-v0.md`, section 4) as a
/// typed value, plus the parser that refuses to guess.
///
/// Three things about this document decide the shape of everything here, and
/// they are all in section 1 of the spec:
///
/// * It is **not** identity. `asset_id` is (`note-format-v0.md` section 3),
///   and two assets with different ids are different assets however identical
///   their documents. Nothing in this file carries an id, on purpose.
/// * It **cannot** override `name`, `symbol` or `decimals`. Those are signed
///   and on-chain. A document that repeats them is not wrong to; a document
///   that disagrees with them is merely wrong about something it does not get
///   to decide, and is *not* rejected for it. So the parser reads no such
///   member at all — there is nothing for a caller to accidentally prefer.
/// * It is **advisory decoration**, chosen by whoever controls the `uri` now,
///   which is the issuer at signing time and whoever holds the host after.
///
/// Unknown members are ignored at every level (section 4.4). That is the whole
/// extension story: a future revision adds members, and a wallet that has
/// never heard of them loses decoration and nothing else.
library;

import 'dart:convert';

/// The only `schema` this revision understands. Section 4.1 makes an
/// unrecognized value a rejection rather than a best-effort read: the members
/// of a schema we do not know do not necessarily mean what ours mean.
const String kNyctisMetadataSchema = 'nyctis-asset-metadata/1';

/// The family half of that string, and the major this revision implements.
/// Split out so that [nyctisSchemaMajor] can serve this document and the
/// collection document of `spec/asset-collection-v0.md` from one rule.
const String kNyctisMetadataSchemaFamily = 'nyctis-asset-metadata';
const int kNyctisMetadataSchemaMajor = 1;

/// Section 4.1: `description` is truncated here, never rendered as rich text
/// and never rendered as a link.
const int kNyctisMetadataMaxDescriptionChars = 1000;

/// Section 4.3: at most 16 links.
const int kNyctisMetadataMaxLinks = 16;

/// `rel` tokens this wallet renders. Section 4.3 defines none and reserves
/// none; a wallet "renders the ones it recognizes and MUST ignore the rest",
/// which is what makes a new platform a zero-change addition on both sides.
/// Unrecognized tokens are still *parsed* — they are simply not drawn.
const Set<String> kNyctisKnownLinkRels = {
  'x',
  'github',
  'discord',
  'telegram',
  'docs',
  'forum',
  'audit',
};

/// A document this wallet will not read. Never shown to a user as an error:
/// section 3.2 says a document that fails is *absent*, and the signed name
/// and symbol still render.
class NyctisMetadataFormatException implements Exception {
  const NyctisMetadataFormatException(this.message);

  /// Diagnostic, not user-facing.
  final String message;

  @override
  String toString() => 'NyctisMetadataFormatException: $message';
}

/// The `logo` member (section 4.2).
class NyctisAssetLogoRef {
  const NyctisAssetLogoRef({required this.uri, this.digestB2});

  /// `https:` only here. Section 2 also permits `ipfs:`; this wallet has no
  /// gateway and resolving one through a third party's HTTPS gateway would
  /// disclose the fetch to a host the issuer did not even choose, so an
  /// `ipfs:` logo is dropped rather than rewritten.
  final Uri uri;

  /// `BLAKE2b-256` of the image bytes, base64url unpadded, when the document
  /// carried one. Section 4.2 makes verifying it mandatory once found.
  final String? digestB2;

  /// Whether the image bytes are pinned. An unpinned logo is not invalid; it
  /// is revocable by whoever holds the host, which the UI says out loud.
  bool get isPinned => digestB2 != null;

  /// `mime`, `width` and `height` are deliberately absent.
  ///
  /// `mime` is advisory and section 4.2 requires the format to be determined
  /// from the bytes, so keeping it would only offer a caller something it must
  /// not trust. `width`/`height` are advisory layout hints, and this wallet
  /// draws every logo into a fixed box — reading them would hand an attacker
  /// the declared dimensions the same section says must not be able to drive
  /// memory use.
  static const String membersDeliberatelyDropped = 'mime, width, height';
}

/// One entry of the `links` array (section 4.3).
class NyctisAssetLink {
  const NyctisAssetLink({required this.rel, required this.uri});

  /// Short lowercase token naming the kind of link.
  final String rel;

  /// `https:` only.
  final Uri uri;

  /// Whether this wallet draws it. Section 4.3: render the recognized ones,
  /// ignore the rest.
  bool get isRecognized => kNyctisKnownLinkRels.contains(rel);
}

/// A parsed metadata document.
class NyctisAssetMetadata {
  const NyctisAssetMetadata({
    this.description,
    this.logo,
    this.website,
    this.links = const [],
  });

  /// Plain text, already truncated to [kNyctisMetadataMaxDescriptionChars]
  /// and stripped of the invisible direction-override characters that let one
  /// string render as another.
  final String? description;

  final NyctisAssetLogoRef? logo;

  /// `https:` only.
  final Uri? website;

  /// Every link the document carried, recognized or not, capped at
  /// [kNyctisMetadataMaxLinks]. Filter with [renderableLinks] to draw.
  final List<NyctisAssetLink> links;

  /// The links a wallet of this revision draws.
  List<NyctisAssetLink> get renderableLinks => [
    for (final link in links)
      if (link.isRecognized) link,
  ];

  bool get isEmpty =>
      description == null && logo == null && website == null && links.isEmpty;

  /// Parses the document's exact bytes.
  ///
  /// Section 4: `application/json`, UTF-8, no BOM, a JSON object at the top
  /// level. A BOM is refused rather than skipped — the digest in section 2.1
  /// is over the exact bytes, so "the same document with a BOM" is a different
  /// document and quietly accepting both makes the pin mean less than it says.
  factory NyctisAssetMetadata.parseBytes(List<int> bytes) =>
      NyctisAssetMetadata.fromJson(nyctisDecodeDocument(bytes));

  factory NyctisAssetMetadata.parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw NyctisMetadataFormatException('not JSON: ${error.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const NyctisMetadataFormatException(
        'top level is not a JSON object',
      );
    }
    return NyctisAssetMetadata.fromJson(decoded);
  }

  factory NyctisAssetMetadata.fromJson(Map<String, Object?> json) {
    final major = nyctisSchemaMajor(
      json['schema'],
      kNyctisMetadataSchemaFamily,
    );
    if (major != kNyctisMetadataSchemaMajor) {
      // Section 4.1 and 4.4: reject rather than guess at the members, and a
      // malformed `schema` is an unrecognized major rather than a parse
      // failure to surface.
      throw NyctisMetadataFormatException(
        'unknown schema "${json['schema']}"',
      );
    }
    return NyctisAssetMetadata(
      description: _description(json['description']),
      logo: _logo(json['logo']),
      website: nyctisHttpsUri(json['website']),
      links: nyctisMetadataLinks(json['links']),
    );
  }

  static String? _description(Object? value) {
    if (value is! String) return null;
    final cleaned = sanitizeNyctisMetadataText(value);
    if (cleaned.isEmpty) return null;
    final runes = cleaned.runes.toList();
    if (runes.length <= kNyctisMetadataMaxDescriptionChars) return cleaned;
    return String.fromCharCodes(
      runes.take(kNyctisMetadataMaxDescriptionChars),
    );
  }

  static NyctisAssetLogoRef? _logo(Object? value) =>
      nyctisAssetLogoRef(value);
}

/// The `logo` object of section 4.2, parsed.
///
/// Shared with the collection document, whose section 3.5 says its own `logo`
/// is "`asset-metadata-v0.md` section 4.2, applied to a collection instead of
/// to an asset" and refuses to restate the rules — so there is one parser and
/// not two. The rule most worth not having a second copy of is the one section
/// 3.5 names: `mime` is never read, so nothing downstream can believe it, and
/// the format is decided from the bytes by [sniffNyctisImageFormat] with the
/// SVG refusal in it.
///
/// A malformed or non-`https:` `uri` costs the member and not the document
/// (section 4.1): no picture, still a description, still a hundred pieces.
NyctisAssetLogoRef? nyctisAssetLogoRef(Object? value) {
  if (value is! Map<String, Object?>) return null;
  final uri = nyctisHttpsUri(value['uri']);
  if (uri == null) return null;
  final digest = value['b2'];
  return NyctisAssetLogoRef(
    uri: uri,
    digestB2: digest is String && isNyctisB2Digest(digest) ? digest : null,
  );
}

/// The `links` array of section 4.3, parsed.
///
/// Shared with the collection document, whose section 3.1 says `website` and
/// `links` are "exactly as `asset-metadata-v0.md` sections 4.1 and 4.3" — so
/// they are parsed by exactly this code rather than by a second copy of the
/// rules that could drift from it.
List<NyctisAssetLink> nyctisMetadataLinks(Object? value) {
  if (value is! List) return const [];
  final links = <NyctisAssetLink>[];
  for (final entry in value) {
    if (links.length >= kNyctisMetadataMaxLinks) break;
    if (entry is! Map<String, Object?>) continue;
    final rel = entry['rel'];
    if (rel is! String) continue;
    final token = rel.trim().toLowerCase();
    if (token.isEmpty || token.length > 32) continue;
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(token)) continue;
    final uri = nyctisHttpsUri(entry['uri']);
    if (uri == null) continue;
    links.add(NyctisAssetLink(rel: token, uri: uri));
  }
  return List.unmodifiable(links);
}

/// A member that must be `https:`, or null.
///
/// A bad one drops the *member*, never the document. Section 1 is explicit
/// that a document is not rejected for being wrong about something it does
/// not get to decide, and a `website` nobody can open is exactly that.
Uri? nyctisHttpsUri(Object? value) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return null;
  if (uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return uri;
}

/// The major of a `schema` value, or null when it does not name [family] at
/// all.
///
/// Section 4.4: `<family>/<major>`, where the major is a decimal integer with
/// no leading zero, and **the major is the compatibility boundary and the only
/// one**. A malformed value — wrong prefix, non-integer, leading zero —
/// **MUST** be treated as an unrecognized major rather than as a parse failure
/// to surface, which is what returning null here lets the caller do.
int? nyctisSchemaMajor(Object? value, String family) {
  if (value is! String) return null;
  final prefix = '$family/';
  if (!value.startsWith(prefix)) return null;
  final digits = value.substring(prefix.length);
  if (digits.isEmpty) return null;
  // No leading zero, and nothing but digits: `01` and `1.2` are malformed, not
  // "major 1".
  if (digits.length > 1 && digits.startsWith('0')) return null;
  if (!RegExp(r'^[0-9]+$').hasMatch(digits)) return null;
  return int.tryParse(digits);
}

/// UTF-8 JSON bytes as a top-level object, or a
/// [NyctisMetadataFormatException].
///
/// Section 4: UTF-8, no BOM, a JSON object at the top level. A BOM is refused
/// rather than skipped — the digest in section 2.1 is over the exact bytes, so
/// "the same document with a BOM" is a different document and quietly
/// accepting both makes the pin mean less than it says.
///
/// Shared with the collection document of `spec/asset-collection-v0.md`, which
/// is the same envelope with different members inside it, and which is told
/// apart from this one by its `schema`.
Map<String, Object?> nyctisDecodeDocument(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    throw const NyctisMetadataFormatException('document starts with a BOM');
  }
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException catch (error) {
    throw NyctisMetadataFormatException('not UTF-8: ${error.message}');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    throw NyctisMetadataFormatException('not JSON: ${error.message}');
  }
  if (decoded is! Map<String, Object?>) {
    throw const NyctisMetadataFormatException(
      'top level is not a JSON object',
    );
  }
  return decoded;
}

/// Whether [value] is a `BLAKE2b-256` digest as section 2.1 writes one: 43
/// characters of base64url, unpadded.
bool isNyctisB2Digest(String value) =>
    value.length == 43 && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);

/// Strips the characters that let issuer-controlled text render as something
/// other than what it is: bidi overrides and embeddings, zero-width joiners,
/// and the C0/C1 controls. Newlines survive; nothing else invisible does.
///
/// Not required by the spec, and not a substitute for anything in section 5 —
/// a name can still be a perfect copy of another name. It closes the narrower
/// hole where a *visually different* string renders identically.
String sanitizeNyctisMetadataText(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final isControl =
        rune < 0x20 || (rune >= 0x7F && rune <= 0x9F) || rune == 0xFEFF;
    final isBidi =
        (rune >= 0x200B && rune <= 0x200F) ||
        (rune >= 0x202A && rune <= 0x202E) ||
        (rune >= 0x2066 && rune <= 0x2069);
    if (isBidi) continue;
    if (isControl) {
      if (rune == 0x0A) buffer.writeCharCode(rune);
      continue;
    }
    buffer.writeCharCode(rune);
  }
  return buffer.toString().trim();
}

/// `example.invalid` / `example.invalid:8443` — what a wallet shows before it
/// opens a link (section 4.3) and where a document came from (section 2.1).
String nyctisUriOrigin(Uri uri) {
  final host = uri.host;
  if (!uri.hasPort) return host;
  final isDefault =
      (uri.scheme == 'https' && uri.port == 443) ||
      (uri.scheme == 'http' && uri.port == 80);
  return isDefault ? host : '$host:${uri.port}';
}
