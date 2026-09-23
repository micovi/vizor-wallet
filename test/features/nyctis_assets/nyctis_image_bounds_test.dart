/// C15: the size limit bounds the file, not the bitmap.
///
/// `dart:ui` documents that an image "will be scaled after being decoded", so
/// `cacheWidth`/`cacheHeight` do not bound what a PNG costs to decode: a
/// 256 KiB file can declare an 8000×8000 canvas and cost 256 MB of RGBA on
/// draw. The fetcher reads the declared size from the header and refuses a
/// canvas past the bound before any widget can hand the bytes to the engine.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_image_format.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_transport.dart';

import 'support/nyctis_metadata_fixtures.dart';

/// The 1×1 fixture PNG with its IHDR width and height rewritten.
///
/// Only the header changes, which is the point: a real encoder would produce
/// the same first 24 bytes for a canvas this size, and those are all the
/// fetcher reads. The IHDR CRC is left stale; the fetcher never checks it and
/// neither would an attacker bother to break it.
Uint8List _pngDeclaring(int width, int height) {
  final bytes = Uint8List.fromList(kOnePixelPng);
  ByteData.sublistView(bytes)
    ..setUint32(16, width)
    ..setUint32(20, height);
  return bytes;
}

/// A minimal JPEG: SOI, an APP0 segment to walk past, then SOF0.
Uint8List _jpegDeclaring(int width, int height, {int sof = 0xC0}) {
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE0, 0x00, 0x06, 0x4A, 0x46, 0x49, 0x46, // APP0, length 6
    0xFF, sof, 0x00, 0x0B, 0x08, // SOFn, length 11, precision 8
    height >> 8, height & 0xFF,
    width >> 8, width & 0xFF,
    0x01, 0x01, 0x11, 0x00, // one component
    0xFF, 0xD9, // EOI
  ]);
}

Uint8List _webp(String fourcc, List<int> payload) {
  final bytes = <int>[
    ...'RIFF'.codeUnits,
    0, 0, 0, 0, // size, unchecked
    ...'WEBP'.codeUnits,
    ...fourcc.codeUnits,
    payload.length, 0, 0, 0,
    ...payload,
  ];
  while (bytes.length < 40) {
    bytes.add(0);
  }
  return Uint8List.fromList(bytes);
}

Uint8List _webpLossy(int width, int height) => _webp('VP8 ', [
  0x00, 0x00, 0x00, // frame tag
  0x9D, 0x01, 0x2A, // start code
  width & 0xFF, (width >> 8) & 0x3F,
  height & 0xFF, (height >> 8) & 0x3F,
]);

Uint8List _webpLossless(int width, int height) {
  final bits = (width - 1) | ((height - 1) << 14);
  return _webp('VP8L', [
    0x2F,
    bits & 0xFF,
    (bits >> 8) & 0xFF,
    (bits >> 16) & 0xFF,
    (bits >> 24) & 0xFF,
  ]);
}

Uint8List _webpExtended(int width, int height) {
  final w = width - 1;
  final h = height - 1;
  return _webp('VP8X', [
    0x00, 0x00, 0x00, 0x00, // flags, reserved
    w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF,
    h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF,
  ]);
}

void main() {
  group('readNyctisImageDimensions', () {
    test('reads the fixture PNG as 1x1', () {
      expect(
        readNyctisImageDimensions(kOnePixelPng),
        const NyctisImageDimensions(1, 1),
      );
    });

    test('reads a PNG IHDR without decoding', () {
      expect(
        readNyctisImageDimensions(_pngDeclaring(8000, 8000)),
        const NyctisImageDimensions(8000, 8000),
      );
    });

    test('reads the devnet collection artwork', () {
      final png = File(
        'test/features/nyctis_assets/fixtures/pon/logo.png',
      ).readAsBytesSync();
      final dimensions = readNyctisImageDimensions(png);
      expect(dimensions, isNotNull);
      expect(dimensions!.isWithinDecodeBound, isTrue);
    });

    test('walks JPEG segments to the frame header', () {
      expect(
        readNyctisImageDimensions(_jpegDeclaring(640, 480)),
        const NyctisImageDimensions(640, 480),
      );
      // A progressive frame is a frame too.
      expect(
        readNyctisImageDimensions(_jpegDeclaring(300, 200, sof: 0xC2)),
        const NyctisImageDimensions(300, 200),
      );
    });

    test('a JPEG whose height is deferred to DNL reads as unknown', () {
      expect(readNyctisImageDimensions(_jpegDeclaring(640, 0)), isNull);
    });

    test('reads all three WebP headers', () {
      expect(
        readNyctisImageDimensions(_webpLossy(320, 240)),
        const NyctisImageDimensions(320, 240),
      );
      expect(
        readNyctisImageDimensions(_webpLossless(1000, 16384)),
        const NyctisImageDimensions(1000, 16384),
      );
      expect(
        readNyctisImageDimensions(_webpExtended(16000000, 2)),
        const NyctisImageDimensions(16000000, 2),
      );
    });

    test('truncated or foreign bytes read as unknown, never throw', () {
      expect(readNyctisImageDimensions(Uint8List(0)), isNull);
      expect(readNyctisImageDimensions(kOnePixelPng.sublist(0, 20)), isNull);
      expect(
        readNyctisImageDimensions(Uint8List.fromList([0xFF, 0xD8, 0xFF])),
        isNull,
      );
      expect(readNyctisImageDimensions(kSvgBytes), isNull);
    });

    test('the decode bound is on area and on each side', () {
      expect(
        const NyctisImageDimensions(2048, 2048).isWithinDecodeBound,
        isTrue,
      );
      expect(
        const NyctisImageDimensions(2049, 2048).isWithinDecodeBound,
        isFalse,
      );
      expect(
        const NyctisImageDimensions(
          kNyctisImageMaxSide + 1,
          1,
        ).isWithinDecodeBound,
        isFalse,
      );
    });
  });

  group('the fetcher refuses a canvas it will not decode', () {
    final documentUri = Uri.parse('https://example.invalid/ny/gold.json');
    final logoUri = Uri.parse('https://example.invalid/ny/gold.png');

    Future<NyctisMetadataFetchOutcome> fetchLogo(Uint8List logo) {
      final fake = FakeNyctisTransport({
        documentUri: NyctisHttpReply(
          statusCode: 200,
          body: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'schema': 'nyctis-asset-metadata/1',
                'description': 'A demonstration asset.',
                'logo': {'uri': logoUri.toString()},
              }),
            ),
          ),
        ),
        logoUri: NyctisHttpReply(statusCode: 200, body: logo),
      });
      return NyctisAssetMetadataFetcher(
        transport: fake,
      ).fetch(assetId: 'ab' * 32, uri: documentUri.toString());
    }

    test('a small PNG declaring 8000x8000 never reaches a widget', () async {
      final bomb = _pngDeclaring(8000, 8000);
      expect(bomb.length, lessThan(kNyctisLogoMaxBytes));

      final outcome = await fetchLogo(bomb);

      // The document still renders; only the picture is refused.
      expect(outcome.hasView, isTrue);
      expect(outcome.view!.logoBytes, isNull);
    });

    test('an image whose size cannot be read is refused too', () async {
      // A PNG signature and nothing after it: sniffed as PNG, header absent.
      final outcome = await fetchLogo(kOnePixelPng.sublist(0, 12));

      expect(outcome.view!.logoBytes, isNull);
    });

    test('an ordinary logo is kept', () async {
      final outcome = await fetchLogo(kOnePixelPng);

      expect(outcome.view!.logoBytes, kOnePixelPng);
    });
  });
}
