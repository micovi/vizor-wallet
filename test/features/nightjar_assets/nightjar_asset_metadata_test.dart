import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_asset_metadata.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_metadata_pointer.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_digest.dart';

/// The example document from section 4 of `spec/asset-metadata-v0.md`, minus
/// the `b2` values it elides.
const _document = {
  'schema': 'nightjar-asset-metadata/1',
  'description': 'A demonstration asset on the Nightjar regtest devnet.',
  'logo': {
    'uri': 'https://example.invalid/nj/gold.png',
    'mime': 'image/png',
    'width': 512,
    'height': 512,
  },
  'website': 'https://example.invalid/',
  'links': [
    {'rel': 'x', 'uri': 'https://x.com/example'},
    {'rel': 'github', 'uri': 'https://github.com/example'},
    {'rel': 'docs', 'uri': 'https://example.invalid/docs'},
  ],
};

void main() {
  group('NightjarAssetMetadata.parse', () {
    test('reads the section 4 example', () {
      final metadata = NightjarAssetMetadata.parse(jsonEncode(_document));

      expect(
        metadata.description,
        'A demonstration asset on the Nightjar regtest devnet.',
      );
      expect(
        metadata.logo!.uri.toString(),
        'https://example.invalid/nj/gold.png',
      );
      expect(metadata.logo!.isPinned, isFalse);
      expect(metadata.website.toString(), 'https://example.invalid/');
      expect(metadata.links.map((link) => link.rel), ['x', 'github', 'docs']);
    });

    test('rejects an unrecognized schema rather than guessing at members', () {
      expect(
        () => NightjarAssetMetadata.parse(
          jsonEncode({..._document, 'schema': 'nightjar-asset-metadata/2'}),
        ),
        throwsA(isA<NightjarMetadataFormatException>()),
      );
    });

    test('rejects a document with no schema', () {
      expect(
        () => NightjarAssetMetadata.parse(jsonEncode({'description': 'hi'})),
        throwsA(isA<NightjarMetadataFormatException>()),
      );
    });

    test('rejects a top level that is not an object', () {
      expect(
        () => NightjarAssetMetadata.parse('[]'),
        throwsA(isA<NightjarMetadataFormatException>()),
      );
      expect(
        () => NightjarAssetMetadata.parse('not json'),
        throwsA(isA<NightjarMetadataFormatException>()),
      );
    });

    test('rejects a UTF-8 BOM, because the digest is over exact bytes', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(jsonEncode(_document))];
      expect(
        () => NightjarAssetMetadata.parseBytes(bytes),
        throwsA(isA<NightjarMetadataFormatException>()),
      );
    });

    test('ignores unknown members at every level (section 4.4)', () {
      final metadata = NightjarAssetMetadata.parse(
        jsonEncode({
          'schema': 'nightjar-asset-metadata/1',
          'description': 'kept',
          'futureTopLevel': {'anything': true},
          'logo': {
            'uri': 'https://example.invalid/logo.png',
            'futureLogoMember': 'ignored',
          },
          'links': [
            {
              'rel': 'docs',
              'uri': 'https://example.invalid/docs',
              'futureLinkMember': 42,
            },
          ],
        }),
      );

      expect(metadata.description, 'kept');
      expect(metadata.logo!.uri.host, 'example.invalid');
      expect(metadata.links.single.rel, 'docs');
    });

    test(
      'never lets a document override the signed name, symbol or decimals',
      () {
        // Section 1: a document MAY repeat them, a wallet MUST ignore the
        // copies, and disagreement is not an error. The parser therefore has no
        // member to read them into at all.
        final metadata = NightjarAssetMetadata.parse(
          jsonEncode({
            'schema': 'nightjar-asset-metadata/1',
            'name': 'Not the signed name',
            'symbol': 'NOPE',
            'decimals': 18,
            'description': 'still read',
          }),
        );

        expect(metadata.description, 'still read');
        expect(
          NightjarAssetMetadata.parse(
            jsonEncode({'schema': 'nightjar-asset-metadata/1'}),
          ).isEmpty,
          isTrue,
        );
      },
    );

    test('truncates description at 1 000 characters', () {
      final metadata = NightjarAssetMetadata.parse(
        jsonEncode({
          'schema': 'nightjar-asset-metadata/1',
          'description': 'a' * 5000,
        }),
      );

      expect(
        metadata.description!.length,
        kNightjarMetadataMaxDescriptionChars,
      );
    });

    test(
      'strips the invisible characters that let text render as other text',
      () {
        final metadata = NightjarAssetMetadata.parse(
          jsonEncode({
            'schema': 'nightjar-asset-metadata/1',
            // Written as escapes, not as the characters themselves: a literal
            // U+202E reverses the rest of this file for anyone reading it, which
            // is the very trick the parser is being tested for.
            'description': 'safe\u202Ereversed\u200Bzero',
          }),
        );

        expect(metadata.description, 'safereversedzero');
      },
    );

    test(
      'drops a non-https website, logo or link without dropping the document',
      () {
        final metadata = NightjarAssetMetadata.parse(
          jsonEncode({
            'schema': 'nightjar-asset-metadata/1',
            'description': 'kept',
            'website': 'http://example.invalid/',
            'logo': {'uri': 'http://example.invalid/logo.png'},
            'links': [
              {'rel': 'docs', 'uri': 'http://example.invalid/docs'},
              {'rel': 'forum', 'uri': 'https://example.invalid/forum'},
            ],
          }),
        );

        expect(metadata.description, 'kept');
        expect(metadata.website, isNull);
        expect(metadata.logo, isNull);
        expect(metadata.links.single.rel, 'forum');
      },
    );

    test('keeps at most 16 links and skips malformed entries', () {
      final metadata = NightjarAssetMetadata.parse(
        jsonEncode({
          'schema': 'nightjar-asset-metadata/1',
          'links': [
            'not an object',
            {'rel': 'DOCS', 'uri': 'https://example.invalid/0'},
            {'uri': 'https://example.invalid/no-rel'},
            {'rel': 'has space', 'uri': 'https://example.invalid/1'},
            for (var i = 0; i < 40; i++)
              {'rel': 'forum', 'uri': 'https://example.invalid/$i'},
          ],
        }),
      );

      expect(metadata.links.length, kNightjarMetadataMaxLinks);
      expect(metadata.links.first.rel, 'docs');
    });

    test('parses every link but renders only recognized rels', () {
      final metadata = NightjarAssetMetadata.parse(
        jsonEncode({
          'schema': 'nightjar-asset-metadata/1',
          'links': [
            {'rel': 'github', 'uri': 'https://example.invalid/a'},
            {'rel': 'newplatform', 'uri': 'https://example.invalid/b'},
          ],
        }),
      );

      expect(metadata.links.length, 2);
      expect(metadata.renderableLinks.single.rel, 'github');
    });

    test('keeps a logo b2 only when it is a real digest', () {
      final good = NightjarAssetMetadata.parse(
        jsonEncode({
          'schema': 'nightjar-asset-metadata/1',
          'logo': {
            'uri': 'https://example.invalid/logo.png',
            'b2': nightjarB2Digest(const [1, 2, 3]),
          },
        }),
      );
      final bad = NightjarAssetMetadata.parse(
        jsonEncode({
          'schema': 'nightjar-asset-metadata/1',
          'logo': {'uri': 'https://example.invalid/logo.png', 'b2': 'short'},
        }),
      );

      expect(good.logo!.isPinned, isTrue);
      expect(bad.logo!.isPinned, isFalse);
    });
  });

  group('nightjarUriOrigin', () {
    test('drops a default port and keeps a custom one', () {
      expect(
        nightjarUriOrigin(Uri.parse('https://example.invalid/a/b')),
        'example.invalid',
      );
      expect(
        nightjarUriOrigin(Uri.parse('https://example.invalid:8443/a')),
        'example.invalid:8443',
      );
    });
  });

  group('readNightjarMetadataUri', () {
    NightjarPointerRejection? reject(String uri) =>
        readNightjarMetadataUri(uri).rejection;

    test('accepts https', () {
      final pointer = readNightjarMetadataUri(
        'https://example.invalid/nj/gold.json',
      ).pointer!;

      expect(
        pointer.requestUri.toString(),
        'https://example.invalid/nj/gold.json',
      );
      expect(pointer.isPinned, isFalse);
      expect(pointer.origin, 'example.invalid');
    });

    test('rejects http', () {
      expect(
        reject('http://example.invalid/nj/gold.json'),
        NightjarPointerRejection.insecureScheme,
      );
    });

    test('rejects data:, file: and every other scheme', () {
      expect(
        reject('data:application/json,%7B%7D'),
        NightjarPointerRejection.forbiddenScheme,
      );
      expect(
        reject('file:///etc/passwd'),
        NightjarPointerRejection.forbiddenScheme,
      );
      expect(
        reject('ipfs://bafkreiexample'),
        NightjarPointerRejection.unsupportedScheme,
      );
    });

    test('rejects a uri over the wire limit or outside US-ASCII', () {
      // Sized off the constant rather than off 255, so the fixture stays a
      // rejection if the limit ever moves again. What cannot move is the
      // ceiling: `uri_len` is a `u8`, so 255 is the largest value the wire
      // format can express at all.
      final long = 'https://example.invalid/${'a' * (kNightjarUriMaxBytes + 1)}';
      expect(long.length, greaterThan(kNightjarUriMaxBytes));
      expect(reject(long), NightjarPointerRejection.malformed);
      expect(
        reject('https://exámple.invalid/a.json'),
        NightjarPointerRejection.malformed,
      );
    });

    test('treats an empty uri as absent, not as a fault', () {
      expect(reject(''), NightjarPointerRejection.absent);
      expect(
        readNightjarMetadataUri(null).rejection,
        NightjarPointerRejection.absent,
      );
    });

    test('reads a #b2= fragment and strips it from the request', () {
      final digest = nightjarB2Digest(utf8.encode('{}'));
      final pointer = readNightjarMetadataUri(
        'https://example.invalid/a.json#b2=$digest',
      ).pointer!;

      expect(pointer.digestB2, digest);
      expect(pointer.isPinned, isTrue);
      expect(pointer.requestUri.toString(), 'https://example.invalid/a.json');
    });

    test('refuses a #b2= that cannot be a digest', () {
      expect(
        reject('https://example.invalid/a.json#b2=tooshort'),
        NightjarPointerRejection.malformedDigest,
      );
    });

    test('ignores a fragment that is not a b2 pin', () {
      final pointer = readNightjarMetadataUri(
        'https://example.invalid/a.json#section',
      ).pointer!;

      expect(pointer.isPinned, isFalse);
    });
  });

  group('nightjarB2Digest', () {
    test('matches the BLAKE2b-256 test vector for "abc"', () {
      // bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319
      final digest = nightjarB2Digest(utf8.encode('abc'));
      final bytes = base64Url.decode('$digest=');

      expect(
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319',
      );
      expect(digest.length, 43);
      expect(nightjarB2DigestMatches(digest, utf8.encode('abc')), isTrue);
      expect(nightjarB2DigestMatches(digest, utf8.encode('abd')), isFalse);
    });
  });
}
