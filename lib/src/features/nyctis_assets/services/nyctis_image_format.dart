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
enum NyctisImageFormat {
  png,
  jpeg,
  webp,

  /// Refused. See the library comment.
  svg,

  /// Anything else: GIF, BMP, HTML, a JSON error page, zeros.
  unsupported;

  bool get isRenderable =>
      this == NyctisImageFormat.png ||
      this == NyctisImageFormat.jpeg ||
      this == NyctisImageFormat.webp;
}

/// Sniffs [bytes]. Never throws; an empty or truncated buffer is
/// [NyctisImageFormat.unsupported].
NyctisImageFormat sniffNyctisImageFormat(Uint8List bytes) {
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
    return NyctisImageFormat.png;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return NyctisImageFormat.jpeg;
  }
  if (bytes.length >= 12 &&
      _startsWith(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return NyctisImageFormat.webp;
  }
  if (_looksLikeSvg(bytes)) return NyctisImageFormat.svg;
  return NyctisImageFormat.unsupported;
}

/// The largest canvas, in pixels, this wallet will hand to the image decoder.
///
/// A wallet choice, not a number from the specification. `Image.memory`'s
/// `cacheWidth`/`cacheHeight` do not bound the decode: `dart:ui` documents
/// that an image "will be scaled after being decoded", and for PNG (which
/// Skia cannot decode at a reduced scale) that means a full-size bitmap
/// first. Deflate compresses a flat canvas about a thousand to one, so a
/// 256 KiB PNG can declare 8000×8000 and cost 256 MB of RGBA on draw.
/// 2048×2048 is 16 MiB decoded, which is generous for a logo or a piece of
/// artwork shown at most a few hundred points wide.
const int kNyctisImageMaxPixels = 2048 * 2048;

/// The longest side this wallet will decode, whatever the area. Keeps a
/// 1×4,000,000 strip — inside the pixel bound — away from the texture-size
/// limits of the GPU backends.
const int kNyctisImageMaxSide = 4096;

/// A canvas size read from an image header.
class NyctisImageDimensions {
  const NyctisImageDimensions(this.width, this.height);

  final int width;
  final int height;

  int get pixels => width * height;

  /// Whether this is a canvas this wallet will decode.
  bool get isWithinDecodeBound =>
      width > 0 &&
      height > 0 &&
      width <= kNyctisImageMaxSide &&
      height <= kNyctisImageMaxSide &&
      pixels <= kNyctisImageMaxPixels;

  @override
  bool operator ==(Object other) =>
      other is NyctisImageDimensions &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// The canvas size [bytes] *declare*, read from the header without decoding,
/// or null when the header is missing, truncated or not one of the three
/// drawable formats.
///
/// Null is a refusal for the caller, not a pass: an image whose size cannot
/// be read before decoding is exactly the one whose decode cannot be bounded.
///
/// * PNG: the `IHDR` chunk, which the format requires to come first.
/// * JPEG: the first start-of-frame marker (`SOF0`–`SOF15`, less the three
///   non-frame codes), found by walking the segment lengths. A frame whose
///   height is deferred to a later `DNL` marker (height 0) reads as null.
/// * WebP: the `VP8 `, `VP8L` or `VP8X` header, whichever the file opens with.
NyctisImageDimensions? readNyctisImageDimensions(Uint8List bytes) {
  return switch (sniffNyctisImageFormat(bytes)) {
    NyctisImageFormat.png => _pngDimensions(bytes),
    NyctisImageFormat.jpeg => _jpegDimensions(bytes),
    NyctisImageFormat.webp => _webpDimensions(bytes),
    NyctisImageFormat.svg || NyctisImageFormat.unsupported => null,
  };
}

NyctisImageDimensions? _pngDimensions(Uint8List bytes) {
  // Signature (8), chunk length (4), `IHDR` (4), width (4), height (4).
  if (bytes.length < 24) return null;
  if (bytes[12] != 0x49 ||
      bytes[13] != 0x48 ||
      bytes[14] != 0x44 ||
      bytes[15] != 0x52) {
    return null;
  }
  final data = ByteData.sublistView(bytes);
  return _positive(data.getUint32(16), data.getUint32(20));
}

NyctisImageDimensions? _jpegDimensions(Uint8List bytes) {
  var i = 2;
  while (i + 1 < bytes.length) {
    if (bytes[i] != 0xFF) return null;
    // Fill bytes: any number of 0xFF may precede a marker code.
    while (i < bytes.length && bytes[i] == 0xFF) {
      i++;
    }
    if (i >= bytes.length) return null;
    final marker = bytes[i];
    i++;
    // Standalone markers carry no length.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
    // End of image, or start of scan before any frame header: no size.
    if (marker == 0xD9 || marker == 0xDA) return null;
    if (i + 1 >= bytes.length) return null;
    final length = (bytes[i] << 8) | bytes[i + 1];
    if (length < 2) return null;
    final isFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) {
      // Length (2), precision (1), height (2), width (2).
      if (i + 6 >= bytes.length) return null;
      final height = (bytes[i + 3] << 8) | bytes[i + 4];
      final width = (bytes[i + 5] << 8) | bytes[i + 6];
      return _positive(width, height);
    }
    i += length;
  }
  return null;
}

NyctisImageDimensions? _webpDimensions(Uint8List bytes) {
  // `RIFF` size `WEBP`, then the first chunk's fourcc at 12 and data at 20.
  if (bytes.length < 30) return null;
  final fourcc = String.fromCharCodes(bytes.sublist(12, 16));
  switch (fourcc) {
    case 'VP8 ':
      // Frame tag (3), start code 9d 01 2a, then 14-bit width and height.
      if (bytes[23] != 0x9D || bytes[24] != 0x01 || bytes[25] != 0x2A) {
        return null;
      }
      final width = (bytes[26] | (bytes[27] << 8)) & 0x3FFF;
      final height = (bytes[28] | (bytes[29] << 8)) & 0x3FFF;
      return _positive(width, height);
    case 'VP8L':
      // Signature 0x2f, then width-1 and height-1 as two 14-bit fields.
      if (bytes[20] != 0x2F) return null;
      final bits =
          bytes[21] | (bytes[22] << 8) | (bytes[23] << 16) | (bytes[24] << 24);
      return _positive((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    case 'VP8X':
      // Flags (1), reserved (3), then canvas width-1 and height-1, 24-bit.
      final width = (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16)) + 1;
      final height = (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16)) + 1;
      return _positive(width, height);
    default:
      return null;
  }
}

NyctisImageDimensions? _positive(int width, int height) =>
    width > 0 && height > 0 ? NyctisImageDimensions(width, height) : null;

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
