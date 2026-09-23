import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_image_format.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_digest.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_transport.dart';

import 'support/nyctis_metadata_fixtures.dart';

void main() {
  const assetId = 'a1b2c3';
  final documentUri = Uri.parse('https://example.invalid/ny/gold.json');
  final logoUri = Uri.parse('https://example.invalid/ny/gold.png');

  Uint8List document({Map<String, Object?>? overrides}) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'schema': 'nyctis-asset-metadata/1',
        'description': 'A demonstration asset.',
        'logo': {'uri': logoUri.toString()},
        ...?overrides,
      }),
    ),
  );

  group('happy path', () {
    test('fetches, parses and renders a logo from a local fixture', () async {
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(statusCode: 200, body: document()),
        logoUri: NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.hasView, isTrue);
      expect(outcome.view!.metadata.description, 'A demonstration asset.');
      expect(outcome.view!.hasLogo, isTrue);
      expect(
        sniffNyctisImageFormat(outcome.view!.logoBytes!),
        NyctisImageFormat.png,
      );
      expect(outcome.view!.documentPinned, isFalse);
      expect(outcome.view!.sourceOrigin, 'example.invalid');
      expect(transport.requested, [documentUri, logoUri]);
    });

    test('verifies a #b2= pin over the exact document bytes', () async {
      final bytes = document();
      final digest = nyctisB2Digest(bytes);
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(statusCode: 200, body: bytes),
        logoUri: NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

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
      final transport = FakeNyctisTransport(const {});
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: 'http://example.invalid/ny/gold.json',
      );

      expect(outcome.reason, NyctisMetadataAbandonReason.pointerRefused);
      expect(transport.requested, isEmpty);
    });

    test(
      'a document over 16 KiB is abandoned, not surfaced as an error',
      () async {
        final transport = FakeNyctisTransport({
          documentUri: NyctisHttpReply(
            statusCode: 200,
            body: Uint8List(kNyctisDocumentMaxBytes + 1),
          ),
        });
        final fetcher = NyctisAssetMetadataFetcher(transport: transport);

        final outcome = await fetcher.fetch(
          assetId: assetId,
          uri: documentUri.toString(),
        );

        expect(outcome.reason, NyctisMetadataAbandonReason.tooLarge);
        expect(outcome.view, isNull);
      },
    );

    test('a logo over 256 KiB costs the logo and nothing else', () async {
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(statusCode: 200, body: document()),
        logoUri: NyctisHttpReply(
          statusCode: 200,
          body: Uint8List(kNyctisLogoMaxBytes + 1),
        ),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.hasView, isTrue);
      expect(outcome.view!.hasLogo, isFalse);
      expect(outcome.view!.metadata.description, 'A demonstration asset.');
    });

    test('a digest mismatch discards the document with no retry', () async {
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(statusCode: 200, body: document()),
        logoUri: NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);
      final wrongDigest = nyctisB2Digest(utf8.encode('something else'));

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: '$documentUri#b2=$wrongDigest',
      );

      expect(outcome.reason, NyctisMetadataAbandonReason.digestMismatch);
      // One request, and no second source: the logo was never asked for.
      expect(transport.requested, [documentUri]);
    });

    test('a logo whose b2 does not match is dropped', () async {
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(
          statusCode: 200,
          body: document(
            overrides: {
              'logo': {
                'uri': logoUri.toString(),
                'b2': nyctisB2Digest(utf8.encode('not the image')),
              },
            },
          ),
        ),
        logoUri: NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.hasView, isTrue);
      expect(outcome.view!.hasLogo, isFalse);
    });

    test('an unknown schema is refused', () async {
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(
          statusCode: 200,
          body: Uint8List.fromList(
            utf8.encode(jsonEncode({'schema': 'something-else/9'})),
          ),
        ),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.reason, NyctisMetadataAbandonReason.documentRefused);
    });

    test('an SVG logo is rejected however it is declared', () async {
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(
          statusCode: 200,
          body: document(
            overrides: {
              'logo': {'uri': logoUri.toString(), 'mime': 'image/png'},
            },
          ),
        ),
        logoUri: NyctisHttpReply(statusCode: 200, body: kSvgBytes),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.hasView, isTrue);
      expect(outcome.view!.hasLogo, isFalse);
      expect(sniffNyctisImageFormat(kSvgBytes), NyctisImageFormat.svg);
    });

    test('a same-origin redirect is followed', () async {
      final moved = Uri.parse('https://example.invalid/ny/moved.json');
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(
          statusCode: 301,
          body: Uint8List(0),
          location: '/ny/moved.json',
        ),
        moved: NyctisHttpReply(statusCode: 200, body: document()),
        logoUri: NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.hasView, isTrue);
      expect(transport.requested.take(2), [documentUri, moved]);
    });

    test('a cross-origin redirect is refused', () async {
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(
          statusCode: 302,
          body: Uint8List(0),
          location: 'https://elsewhere.invalid/ny/gold.json',
        ),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.reason, NyctisMetadataAbandonReason.redirectRefused);
      expect(transport.requested, [documentUri]);
    });

    test('more than three redirects is refused', () async {
      final replies = <Uri, NyctisHttpReply>{};
      for (var i = 0; i < 6; i++) {
        replies[Uri.parse('https://example.invalid/hop$i')] = NyctisHttpReply(
          statusCode: 307,
          body: Uint8List(0),
          location: '/hop${i + 1}',
        );
      }
      final transport = FakeNyctisTransport(replies);
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: 'https://example.invalid/hop0',
      );

      expect(outcome.reason, NyctisMetadataAbandonReason.redirectRefused);
      expect(transport.requested.length, kNyctisMetadataMaxRedirects + 1);
    });

    test(
      'a transport that refuses a cross-origin hop is an abandonment',
      () async {
        final transport = FakeNyctisTransport(
          const {},
          onRequest: (uri) => throw NyctisCrossOriginRedirectException(
            uri,
            Uri.parse('https://elsewhere.invalid/'),
          ),
        );
        final fetcher = NyctisAssetMetadataFetcher(transport: transport);

        final outcome = await fetcher.fetch(
          assetId: assetId,
          uri: documentUri.toString(),
        );

        expect(outcome.reason, NyctisMetadataAbandonReason.redirectRefused);
      },
    );

    test('a timeout abandons rather than erroring the screen', () async {
      final transport = FakeNyctisTransport(
        const {},
        onRequest: (_) => throw TimeoutException('too slow'),
      );
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.reason, NyctisMetadataAbandonReason.timedOut);
    });

    test('an unreachable host abandons rather than throwing', () async {
      final transport = FakeNyctisTransport(
        const {},
        onRequest: (_) => throw const SocketException('no route'),
      );
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.reason, NyctisMetadataAbandonReason.transport);
    });

    test('a 404 abandons', () async {
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(statusCode: 404, body: Uint8List(0)),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      final outcome = await fetcher.fetch(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.reason, NyctisMetadataAbandonReason.httpStatus);
    });
  });

  group('caching', () {
    test('a second fetch makes no second request', () async {
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(statusCode: 200, body: document()),
        logoUri: NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      await fetcher.fetch(assetId: assetId, uri: documentUri.toString());
      await fetcher.fetch(assetId: assetId, uri: documentUri.toString());

      expect(transport.requested, [documentUri, logoUri]);
    });

    test(
      'a refusal is cached too, so a dead host is not a heartbeat',
      () async {
        final transport = FakeNyctisTransport({
          documentUri: NyctisHttpReply(statusCode: 500, body: Uint8List(0)),
        });
        final fetcher = NyctisAssetMetadataFetcher(transport: transport);

        await fetcher.fetch(assetId: assetId, uri: documentUri.toString());
        await fetcher.fetch(assetId: assetId, uri: documentUri.toString());

        expect(transport.requested, [documentUri]);
      },
    );

    test('two callers in one frame share one request', () async {
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(statusCode: 200, body: document()),
        logoUri: NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

      await Future.wait([
        fetcher.fetch(assetId: assetId, uri: documentUri.toString()),
        fetcher.fetch(assetId: assetId, uri: documentUri.toString()),
      ]);

      expect(transport.requested, [documentUri, logoUri]);
    });

    test('forget drops the cached answer for one asset', () async {
      final transport = FakeNyctisTransport({
        documentUri: NyctisHttpReply(statusCode: 200, body: document()),
        logoUri: NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: transport);

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
