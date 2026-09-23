/// Local fixtures for the Nyctis issuer-metadata tests.
///
/// The devnet's two named assets do not serve a real metadata document —
/// "NIGHTJAR" points at `https://nightjar.cash/`, which is a site and not a
/// JSON document — so the happy path is exercised against these bytes and a
/// [FakeNyctisTransport] rather than against a live host. That is also the
/// only way to test the refusals: nothing on the devnet serves an oversize
/// document, a wrong digest, or an SVG pretending to be a PNG.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_transport.dart';

/// A 1x1 transparent PNG. Real bytes, so the sniffing and the engine's decoder
/// both see a genuine PNG rather than a magic-number prefix.
final Uint8List kOnePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// A *different* 1x1 PNG — one red pixel rather than one transparent one.
///
/// It exists so a test can serve a genuinely valid image that is not the image
/// a digest pinned. That is the shape of the attack section 3.3 of
/// `spec/asset-collection-v0.md` and section 2.1 of `asset-metadata-v0.md`
/// exist for: whoever holds the host later serves a perfectly good picture
/// that the issuer never signed for. Testing it with corrupt bytes would pass
/// for the wrong reason — the format sniff would refuse them before the digest
/// was ever compared.
final Uint8List kOtherPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAF'
  'AAH/iZk9HQAAAABJRU5ErkJggg==',
);

/// An SVG, which section 4.2 refuses. It is served under a `mime` of
/// `image/png` in the tests, because that member is exactly what a wallet is
/// forbidden from trusting.
final Uint8List kSvgBytes = Uint8List.fromList(
  utf8.encode(
    '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" '
    'width="8" height="8"><rect width="8" height="8"/></svg>',
  ),
);

/// A scripted [NyctisMetadataTransport] that records what was asked for.
///
/// Recording matters more than replying: most of these tests assert on the
/// requests that were *not* made.
class FakeNyctisTransport implements NyctisMetadataTransport {
  FakeNyctisTransport(this.replies, {this.onRequest});

  final Map<Uri, NyctisHttpReply> replies;

  /// Called before the scripted reply is looked up. Throw from here to
  /// simulate a timeout, a dead host, or the transport's own origin guard.
  final void Function(Uri uri)? onRequest;

  final List<Uri> requested = [];

  /// The headers the fetcher sent, in request order.
  final List<Map<String, String>> headers = [];

  /// The `maxBytes` each request was allowed, in request order.
  final List<int> maxBytes = [];

  @override
  Future<NyctisHttpReply> get(
    Uri uri, {
    required Duration timeout,
    required Map<String, String> headers,
    required int maxBytes,
  }) async {
    requested.add(uri);
    this.headers.add(headers);
    this.maxBytes.add(maxBytes);
    onRequest?.call(uri);
    final reply = replies[uri];
    if (reply == null) {
      return NyctisHttpReply(statusCode: 404, body: Uint8List(0));
    }
    return reply;
  }
}
