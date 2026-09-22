import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_image_format.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_digest.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_transport.dart';

import 'support/nightjar_metadata_fixtures.dart';

void main() {
  const assetId = 'a1b2c3';
  final documentUri = Uri.parse('https://example.invalid/nj/gold.json');
  final logoUri = Uri.parse('https://example.invalid/nj/gold.png');

  Uint8List document({Map<String, Object?>? overrides}) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'schema': 'nightjar-asset-metadata/1',
        'description': 'A demonstration asset.',
        'logo': {'uri': logoUri.toString()},
        ...?overrides,
      }),
    ),
  );

  group('happy path', () {
    test('fetches, parses and renders a logo from a local fixture', () async {
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(statusCode: 200, body: document()),
        logoUri: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.hasView, isTrue);
      expect(outcome.view!.metadata.description, 'A demonstration asset.');
      expect(outcome.view!.hasLogo, isTrue);
      expect(
        sniffNightjarImageFormat(outcome.view!.logoBytes!),
        NightjarImageFormat.png,
      );
      expect(outcome.view!.documentPinned, isFalse);
      expect(outcome.view!.sourceOrigin, 'example.invalid');
      expect(transport.requested, [documentUri, logoUri]);
    });

    test('verifies a #b2= pin over the exact document bytes', () async {
      final bytes = document();
      final digest = nightjarB2Digest(bytes);
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(statusCode: 200, body: bytes),
        logoUri: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: '$documentUri#b2=$digest',
      );

      expect(outcome.hasView, isTrue);
      expect(outcome.view!.documentPinned, isTrue);
    });
  });

  group('section 2 and 3 refusals', () {
    test('an http: uri is refused before any request is made', () async {
      final transport = FakeNightjarTransport(const {});
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: 'http://example.invalid/nj/gold.json',
      );

      expect(outcome.reason, NightjarMetadataAbandonReason.pointerRefused);
      expect(transport.requested, isEmpty);
    });

    test(
      'a document over 16 KiB is abandoned, not surfaced as an error',
      () async {
        final transport = FakeNightjarTransport({
          documentUri: NightjarHttpReply(
            statusCode: 200,
            body: Uint8List(kNightjarDocumentMaxBytes + 1),
          ),
        });
        final fetcher = NightjarAssetMetadataFetcher(transport: transport);

        final outcome = await fetcher.fetch(
          assetId: assetId,
          uri: documentUri.toString(),
        );

        expect(outcome.reason, NightjarMetadataAbandonReason.tooLarge);
        expect(outcome.view, isNull);
      },
    );

    test('a logo over 256 KiB costs the logo and nothing else', () async {
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(statusCode: 200, body: document()),
        logoUri: NightjarHttpReply(
          statusCode: 200,
          body: Uint8List(kNightjarLogoMaxBytes + 1),
        ),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.hasView, isTrue);
      expect(outcome.view!.hasLogo, isFalse);
      expect(outcome.view!.metadata.description, 'A demonstration asset.');
    });

    test('a digest mismatch discards the document with no retry', () async {
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(statusCode: 200, body: document()),
        logoUri: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);
      final wrongDigest = nightjarB2Digest(utf8.encode('something else'));

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: '$documentUri#b2=$wrongDigest',
      );

      expect(outcome.reason, NightjarMetadataAbandonReason.digestMismatch);
      // One request, and no second source: the logo was never asked for.
      expect(transport.requested, [documentUri]);
    });

    test('a logo whose b2 does not match is dropped', () async {
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(
          statusCode: 200,
          body: document(
            overrides: {
              'logo': {
                'uri': logoUri.toString(),
                'b2': nightjarB2Digest(utf8.encode('not the image')),
              },
            },
          ),
        ),
        logoUri: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.hasView, isTrue);
      expect(outcome.view!.hasLogo, isFalse);
    });

    test('an unknown schema is refused', () async {
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(
          statusCode: 200,
          body: Uint8List.fromList(
            utf8.encode(jsonEncode({'schema': 'something-else/9'})),
          ),
        ),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.reason, NightjarMetadataAbandonReason.documentRefused);
    });

    test('an SVG logo is rejected however it is declared', () async {
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(
          statusCode: 200,
          body: document(
            overrides: {
              'logo': {'uri': logoUri.toString(), 'mime': 'image/png'},
            },
          ),
        ),
        logoUri: NightjarHttpReply(statusCode: 200, body: kSvgBytes),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.hasView, isTrue);
      expect(outcome.view!.hasLogo, isFalse);
      expect(sniffNightjarImageFormat(kSvgBytes), NightjarImageFormat.svg);
    });

    test('a same-origin redirect is followed', () async {
      final moved = Uri.parse('https://example.invalid/nj/moved.json');
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(
          statusCode: 301,
          body: Uint8List(0),
          location: '/nj/moved.json',
        ),
        moved: NightjarHttpReply(statusCode: 200, body: document()),
        logoUri: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.hasView, isTrue);
      expect(transport.requested.take(2), [documentUri, moved]);
    });

    test('a cross-origin redirect is refused', () async {
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(
          statusCode: 302,
          body: Uint8List(0),
          location: 'https://elsewhere.invalid/nj/gold.json',
        ),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.reason, NightjarMetadataAbandonReason.redirectRefused);
      expect(transport.requested, [documentUri]);
    });

    test('more than three redirects is refused', () async {
      final replies = <Uri, NightjarHttpReply>{};
      for (var i = 0; i < 6; i++) {
        replies[Uri.parse('https://example.invalid/hop$i')] = NightjarHttpReply(
          statusCode: 307,
          body: Uint8List(0),
          location: '/hop${i + 1}',
        );
      }
      final transport = FakeNightjarTransport(replies);
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: 'https://example.invalid/hop0',
      );

      expect(outcome.reason, NightjarMetadataAbandonReason.redirectRefused);
      expect(transport.requested.length, kNightjarMetadataMaxRedirects + 1);
    });

    test(
      'a transport that refuses a cross-origin hop is an abandonment',
      () async {
        final transport = FakeNightjarTransport(
          const {},
          onRequest: (uri) => throw NightjarCrossOriginRedirectException(
            uri,
            Uri.parse('https://elsewhere.invalid/'),
          ),
        );
        final fetcher = NightjarAssetMetadataFetcher(transport: transport);

        final outcome = await fetcher.fetch(
          assetId: assetId,
          uri: documentUri.toString(),
        );

        expect(outcome.reason, NightjarMetadataAbandonReason.redirectRefused);
      },
    );

    test('a timeout abandons rather than erroring the screen', () async {
      final transport = FakeNightjarTransport(
        const {},
        onRequest: (_) => throw TimeoutException('too slow'),
      );
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.reason, NightjarMetadataAbandonReason.timedOut);
    });

    test('an unreachable host abandons rather than throwing', () async {
      final transport = FakeNightjarTransport(
        const {},
        onRequest: (_) => throw const SocketException('no route'),
      );
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.reason, NightjarMetadataAbandonReason.transport);
    });

    test('a 404 abandons', () async {
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(statusCode: 404, body: Uint8List(0)),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.reason, NightjarMetadataAbandonReason.httpStatus);
    });
  });

  group('caching', () {
    test('a second fetch makes no second request', () async {
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(statusCode: 200, body: document()),
        logoUri: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      await fetcher.fetch(assetId: assetId, uri: documentUri.toString());
      await fetcher.fetch(assetId: assetId, uri: documentUri.toString());

      expect(transport.requested, [documentUri, logoUri]);
    });

    test(
      'a refusal is cached too, so a dead host is not a heartbeat',
      () async {
        final transport = FakeNightjarTransport({
          documentUri: NightjarHttpReply(statusCode: 500, body: Uint8List(0)),
        });
        final fetcher = NightjarAssetMetadataFetcher(transport: transport);

        await fetcher.fetch(assetId: assetId, uri: documentUri.toString());
        await fetcher.fetch(assetId: assetId, uri: documentUri.toString());

        expect(transport.requested, [documentUri]);
      },
    );

    test('two callers in one frame share one request', () async {
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(statusCode: 200, body: document()),
        logoUri: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      await Future.wait([
        fetcher.fetch(assetId: assetId, uri: documentUri.toString()),
        fetcher.fetch(assetId: assetId, uri: documentUri.toString()),
      ]);

      expect(transport.requested, [documentUri, logoUri]);
    });

    test('forget drops the cached answer for one asset', () async {
      final transport = FakeNightjarTransport({
        documentUri: NightjarHttpReply(statusCode: 200, body: document()),
        logoUri: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: transport);

      await fetcher.fetch(assetId: assetId, uri: documentUri.toString());
      expect(
        fetcher.cached(assetId: assetId, uri: documentUri.toString()),
        isNotNull,
      );

      fetcher.forget(assetId);

      expect(
        fetcher.cached(assetId: assetId, uri: documentUri.toString()),
        isNull,
      );
    });
  });
}
