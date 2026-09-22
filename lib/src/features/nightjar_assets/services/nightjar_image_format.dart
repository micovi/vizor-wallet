/// What a logo's bytes actually are (section 4.2 of
/// `spec/asset-metadata-v0.md`).
///
/// The document's `mime` member is advisory and the spec says so in a MUST: a
/// wallet **MUST** determine the format from the bytes and **MUST NOT** trust
/// that member. So nothing here takes a declared type as an argument — there
/// is no parameter for a caller to pass one through.
///
/// `image/svg+xml` is refused and stays refused. SVG is a document format with
/// script and external-reference capability; rendering one from an untrusted
/// issuer inside a wallet is a remote-content execution surface, and this app
/// does render SVG — `flutter_svg` is already a dependency for the icon set,
/// which is exactly what makes "just allow it, we have the renderer" the easy
/// and wrong change. It is refused by *name* below rather than falling out of
/// an allow-list so that the refusal is visible to anyone who greps for it.
library;

import 'dart:typed_data';

/// Formats this wallet will draw, plus the two refusals worth naming.
enum NightjarImageFormat {
  png,
  jpeg,
  webp,

  /// Refused. See the library comment.
  svg,

  /// Anything else: GIF, BMP, HTML, a JSON error page, zeros.
  unsupported;

  bool get isRenderable =>
      this == NightjarImageFormat.png ||
      this == NightjarImageFormat.jpeg ||
      this == NightjarImageFormat.webp;
}

/// Sniffs [bytes]. Never throws; an empty or truncated buffer is
/// [NightjarImageFormat.unsupported].
NightjarImageFormat sniffNightjarImageFormat(Uint8List bytes) {
  if (_startsWith(bytes, const [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ])) {
    return NightjarImageFormat.png;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return NightjarImageFormat.jpeg;
  }
  if (bytes.length >= 12 &&
      _startsWith(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return NightjarImageFormat.webp;
  }
  if (_looksLikeSvg(bytes)) return NightjarImageFormat.svg;
  return NightjarImageFormat.unsupported;
}

/// Leading whitespace, an optional XML declaration or doctype, then `<svg`.
///
/// Only the first 512 bytes are examined: a file that has not said it is SVG
/// by then is being rejected as unsupported anyway, and the distinction only
/// exists so the refusal can be logged for what it is.
bool _looksLikeSvg(Uint8List bytes) {
  final window = bytes.length > 512 ? bytes.sublist(0, 512) : bytes;
  final text = String.fromCharCodes(
    window.where((byte) => byte != 0x00),
  ).toLowerCase();
  return text.contains('<svg') || text.contains('<!doctype svg');
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}
