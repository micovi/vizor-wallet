/// `spec/asset-collection-v0.md` section 3.3.1 — the digest table.
///
/// The table exists so that a collection above 302 members keeps the pinning
/// and the privacy of the shared form. Both halves are under test here, and
/// the privacy half is the one worth stating: the document stops growing with
/// the collection, so every member of a collection of any size signs the
/// **same** `uri`. A test that only checked the digests came out right would
/// pass against a design that split them across documents, which is the design
/// this one was chosen over.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_collection_metadata.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_digest.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_transport.dart';

import 'support/nyctis_metadata_fixtures.dart';

/// A table of [count] distinct digests, so that an off-by-one in the offset
/// arithmetic cannot pass by coincidence. A table of one repeated digest would
/// let `32 * index` and `32 * (index - 1)` agree.
Uint8List _table(int count) {
  final bytes = Uint8List(count * kNyctisDigestBytes);
  for (var i = 0; i < count; i++) {
    for (var b = 0; b < kNyctisDigestBytes; b++) {
      bytes[i * kNyctisDigestBytes + b] = (i * 31 + b * 7) & 0xFF;
    }
  }
  return bytes;
}

String _digestAt(Uint8List table, int index) => base64Url
    .encode(
      Uint8List.sublistView(
        table,
        index * kNyctisDigestBytes,
        (index + 1) * kNyctisDigestBytes,
      ),
    )
    .replaceAll('=', '');

Map<String, Object?> _document({
  Map<String, Object?>? digestTable,
  List<Object?>? digests,
  Map<String, Object?>? extra,
  int maxSupply = 10000,
}) => {
  'schema': 'nyctis-collection-metadata/1',
  'name': 'Phases of One Night',
  'max_supply': maxSupply,
  'item': {
    'name': 'Phases of One Night #{index}',
    'image': 'https://example.invalid/pon/{index}.png',
  },
  'digests': ?digests,
  'digest_table': ?digestTable,
  ...?extra,
};

Map<String, Object?> _pointer(Uint8List table) => {
  'uri': 'https://example.invalid/pon/d.bin',
  'b2': nyctisB2Digest(table),
  'count': table.length ~/ kNyctisDigestBytes,
};

void main() {
  group('section 3.3.1 — the pointer', () {
    test('parses uri, b2 and count', () {
      final table = _table(10000);
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digestTable: _pointer(table)),
      );

      expect(collection.digestTable, isNotNull);
      expect(collection.digestTable!.count, 10000);
      expect(
        collection.digestTable!.uri,
        Uri.parse('https://example.invalid/pon/d.bin'),
      );
      expect(collection.digestTable!.expectedBytes, 320000);
    });

    test('holding the pointer is not holding the digests', () {
      // Until the table is fetched the wallet genuinely does not know any
      // digest, and the honest rendering of that is "unpinned" — not a guess
      // and not an error.
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digestTable: _pointer(_table(10))),
      );

      expect(collection.hasResolvedDigestTable, isFalse);
      expect(collection.digestAt(0), isNull);
      expect(collection.memberAt(0)!.digestB2, isNull);
    });

    test('a pointer with no b2 is no pointer at all', () {
      // Section 3.3.1 makes `b2` required and says why: an unpinned table is a
      // swap vector for every image in the collection at once. So this is
      // dropped rather than accepted as a table that will simply go unverified.
      final pointer = _pointer(_table(10))..remove('b2');
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digestTable: pointer),
      );

      expect(collection.digestTable, isNull);
    });

    test('refuses a count past the section 3.2 ceiling', () {
      final pointer = _pointer(_table(10))
        ..['count'] = kNyctisDigestTableMaxCount + 1;
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digestTable: pointer),
      );

      // Believing it would mean sizing a read from a number the format calls
      // advisory everywhere else. 32 * 16384 is the 512 KiB of section 3.2.
      expect(collection.digestTable, isNull);
      expect(kNyctisDigestTableMaxCount * kNyctisDigestBytes, 512 * 1024);
    });

    test('refuses a b2 that is not 43 base64url characters', () {
      for (final bad in ['short', 'x' * 44, '${'a' * 42}+', '${'a' * 42}/']) {
        final pointer = _pointer(_table(10))..['b2'] = bad;
        expect(
          NyctisCollectionMetadata.fromJson(
            _document(digestTable: pointer),
          ).digestTable,
          isNull,
          reason: 'b2 "$bad" should not parse',
        );
      }
    });
  });

  group('section 3.3.1 — resolving', () {
    test('resolves and answers every index from the table', () {
      final table = _table(10000);
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digestTable: _pointer(table)),
      ).resolveDigestTable(table)!;

      expect(collection.hasResolvedDigestTable, isTrue);
      for (final index in [0, 1, 9, 302, 5000, 9999]) {
        expect(
          collection.digestAt(index),
          _digestAt(table, index),
          reason: 'digest for member $index',
        );
      }
    });

    test('the digest reaches the member, so nothing downstream can tell', () {
      // The whole point of encoding the table's 32 bytes back into base64url:
      // `memberAt` and everything past it sees exactly what an inline document
      // would have given it.
      final table = _table(400);
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digestTable: _pointer(table)),
      ).resolveDigestTable(table)!;

      expect(collection.memberAt(310)!.digestB2, _digestAt(table, 310));
      expect(collection.memberAt(310)!.digestB2!.length, 43);
    });

    test('an index past the table is unpinned, not an error', () {
      final table = _table(100);
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digestTable: _pointer(table)),
      ).resolveDigestTable(table)!;

      expect(collection.digestAt(100), isNull);
      expect(collection.digestAt(99), isNotNull);
      // Section 3.1: a member past `size` is still a member.
      expect(collection.memberAt(100), isNotNull);
      expect(collection.memberAt(100)!.digestB2, isNull);
    });

    test('refuses a table whose b2 does not match', () {
      final table = _table(100);
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digestTable: _pointer(table)),
      );

      final tampered = Uint8List.fromList(table);
      tampered[32 * 7] ^= 0x01; // one bit, inside member 7's digest

      expect(collection.resolveDigestTable(tampered), isNull);
    });

    test('refuses a table of the wrong length, both directions', () {
      final table = _table(100);
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digestTable: _pointer(table)),
      );

      expect(
        collection.resolveDigestTable(
          Uint8List.sublistView(table, 0, table.length - 1),
        ),
        isNull,
        reason: 'one byte short',
      );
      expect(
        collection.resolveDigestTable(
          Uint8List.fromList([...table, 0]),
        ),
        isNull,
        reason: 'one byte long',
      );
    });

    test('a failed table is the whole collection unpinned, not part of it', () {
      // There is no partial credit for a table. Returning null rather than a
      // half-resolved document is how that is made unrepresentable, and this
      // is the test that would fail if someone made resolveDigestTable salvage
      // the prefix of a truncated file.
      final table = _table(100);
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digestTable: _pointer(table)),
      );

      final truncated = Uint8List.sublistView(table, 0, 50 * 32);
      expect(collection.resolveDigestTable(truncated), isNull);
      expect(collection.digestAt(0), isNull, reason: 'not even member 0');
    });

    test('resolveDigestTable is null when there is no pointer', () {
      final collection = NyctisCollectionMetadata.fromJson(_document());
      expect(collection.resolveDigestTable(_table(10)), isNull);
    });

    test('resolving leaves the original document untouched', () {
      final table = _table(10);
      final original = NyctisCollectionMetadata.fromJson(
        _document(digestTable: _pointer(table)),
      );
      final resolved = original.resolveDigestTable(table)!;

      expect(resolved.digestAt(3), isNotNull);
      expect(original.digestAt(3), isNull);
      expect(original.hasResolvedDigestTable, isFalse);
    });
  });

  group('section 3.3.1 — the two shapes are mutually exclusive', () {
    test('a document carrying both uses the table', () {
      // So that two sources can never disagree about one index. The inline
      // array here pins member 0 to a digest the table does not carry; the
      // table must win.
      final table = _table(10);
      final collection = NyctisCollectionMetadata.fromJson(
        _document(
          digestTable: _pointer(table),
          digests: [nyctisB2Digest(utf8.encode('something else'))],
        ),
      ).resolveDigestTable(table)!;

      expect(collection.digestAt(0), _digestAt(table, 0));
    });

    test('inline digests still work, unchanged', () {
      // Revision 4 takes nothing away: a document carrying `digests` inline is
      // valid exactly as before.
      final digest = nyctisB2Digest(utf8.encode('one'));
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digests: [digest], maxSupply: 1),
      );

      expect(collection.digestTable, isNull);
      expect(collection.digestAt(0), digest);
      expect(collection.hasResolvedDigestTable, isFalse);
    });
  });

  group('the size property the table exists for', () {
    test('the document is constant in N, so one uri serves any size', () {
      // This is the test that distinguishes the design from the one it beat.
      // Splitting digests across documents would make the document constant
      // too — but it would need one uri per range, and then which uri a wallet
      // fetches is a fact about which pieces it holds. Here the byte size of
      // the document does not move between a hundred members and ten thousand.
      Map<String, Object?> doc(int n) =>
          _document(digestTable: _pointer(_table(n)), maxSupply: n);

      final small = utf8.encode(jsonEncode(doc(100))).length;
      final large = utf8.encode(jsonEncode(doc(10000))).length;

      // Only `size` and `count` gained digits.
      expect(large - small, lessThan(16));
      expect(large, lessThan(16 * 1024));
    });

    test('ten thousand members fit where inline digests reach 302', () {
      final table = _table(10000);
      final collection = NyctisCollectionMetadata.fromJson(
        _document(digestTable: _pointer(table), maxSupply: 10000),
      ).resolveDigestTable(table)!;

      expect(collection.digestAt(9999), isNotNull);
      expect(table.length, 320000);
    });
  });

  group('through the fetcher', () {
    final documentUri = Uri.parse('https://example.invalid/pon/c.json');
    final tableUri = Uri.parse('https://example.invalid/pon/d.bin');
    Uri imageUri(int i) => Uri.parse('https://example.invalid/pon/$i.png');

    /// A 400-member collection whose every image is the same PNG, pinned
    /// through a table. 400 is past the 302 an inline document could hold, so
    /// this collection could not exist in the old shape at all.
    (FakeNyctisTransport, Uint8List) serve() {
      final pngDigest = nyctisB2Digest(kOnePixelPng);
      final raw = base64Url.decode('$pngDigest=');
      final table = Uint8List(400 * kNyctisDigestBytes);
      for (var i = 0; i < 400; i++) {
        table.setRange(i * kNyctisDigestBytes, (i + 1) * kNyctisDigestBytes, raw);
      }
      final doc = _document(digestTable: _pointer(table), maxSupply: 400);
      return (
        FakeNyctisTransport({
          documentUri: NyctisHttpReply(
            statusCode: 200,
            body: Uint8List.fromList(utf8.encode(jsonEncode(doc))),
          ),
          tableUri: NyctisHttpReply(statusCode: 200, body: table),
          for (var i = 0; i < 400; i++)
            imageUri(i): NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
        }),
        table,
      );
    }

    test('fetches the table and pins the member through it', () async {
      final (fake, _) = serve();
      final fetcher = NyctisAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: 'a1',
        uri: documentUri.toString(),
        index: 310,
      );

      expect(outcome.hasImage, isTrue);
      expect(outcome.imagePinned, isTrue, reason: 'member 310 is pinned');
      expect(fake.requested, [documentUri, tableUri, imageUri(310)]);
    });

    test('one table request serves every member of the collection', () async {
      // The saving the shared form exists for, applied to the table. Forty
      // members must cost one table fetch between them, not forty.
      final (fake, _) = serve();
      final fetcher = NyctisAssetMetadataFetcher(transport: fake);

      for (var i = 0; i < 40; i++) {
        await fetcher.fetchArtwork(
          assetId: 'asset-$i',
          uri: documentUri.toString(),
          index: i,
        );
      }

      expect(
        fake.requested.where((u) => u == tableUri).length,
        1,
        reason: 'the table belongs to the document, not to a member',
      );
      expect(
        fake.requested.where((u) => u == documentUri).length,
        1,
        reason: 'and so does the document',
      );
      expect(fake.requested.where((u) => u.path.endsWith('.png')).length, 40);
    });

    test('never sends a Range header for the table', () async {
      // Section 3.3.1 forbids it, and the reason is not bandwidth: the offset
      // of a digest *is* its index, so `Range: bytes=9920-9951` tells the host
      // the wallet wants member 310 and nothing else. That is the section 2.1
      // disclosure arriving through the mechanism chosen to avoid it.
      final (fake, _) = serve();
      final fetcher = NyctisAssetMetadataFetcher(transport: fake);

      await fetcher.fetchArtwork(
        assetId: 'a1',
        uri: documentUri.toString(),
        index: 310,
      );

      for (final headers in fake.headers) {
        expect(
          headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('range')),
        );
      }
    });

    test('a table the host tampers with unpins the whole collection', () async {
      final (fake, table) = serve();
      final tampered = Uint8List.fromList(table)..[0] ^= 0x01;
      final fake2 = FakeNyctisTransport({
        ...fake.replies,
        tableUri: NyctisHttpReply(statusCode: 200, body: tampered),
      });
      final fetcher = NyctisAssetMetadataFetcher(transport: fake2);

      // Member 310's own 32 bytes are untouched; only member 0's were flipped.
      // It still reads as unpinned, because a table is verified whole.
      final outcome = await fetcher.fetchArtwork(
        assetId: 'a1',
        uri: documentUri.toString(),
        index: 310,
      );

      expect(outcome.imagePinned, isFalse);
    });

    test('an unreachable table is unpinned, not a failed collection', () async {
      final (fake, _) = serve();
      final fake2 = FakeNyctisTransport({
        ...fake.replies,
      }..remove(tableUri));
      final fetcher = NyctisAssetMetadataFetcher(transport: fake2);

      final outcome = await fetcher.fetchArtwork(
        assetId: 'a1',
        uri: documentUri.toString(),
        index: 310,
      );

      // The artwork still arrives and still renders; what is lost is the
      // pinning, and that is what the UI must say.
      expect(outcome.hasImage, isTrue);
      expect(outcome.imagePinned, isFalse);
    });
  });

  group('section 3.4.1 — the items document', () {
    Uint8List itemsBytes(List<Object?> entries) =>
        Uint8List.fromList(utf8.encode(jsonEncode(entries)));

    Map<String, Object?> itemsPointer(Uint8List body) => {
      'uri': 'https://example.invalid/pon/i.json',
      'b2': nyctisB2Digest(body),
      'bytes': body.length,
    };

    final body = itemsBytes([
      {
        'index': 5000,
        'name': 'The Crown',
        'attributes': [
          {'trait': 'Phase', 'value': 'Full'},
        ],
      },
    ]);

    test('parses uri, b2 and the declared length', () {
      final c = NyctisCollectionMetadata.fromJson(
        _document(extra: {'items_document': itemsPointer(body)}),
      );

      expect(c.itemsDocument, isNotNull);
      expect(c.itemsDocument!.bytes, body.length);
    });

    test('holding the pointer is not holding the traits', () {
      final c = NyctisCollectionMetadata.fromJson(
        _document(extra: {'items_document': itemsPointer(body)}),
      );

      // The template still draws the piece; it simply has no override.
      expect(c.overrideFor(5000), isNull);
      expect(c.memberAt(5000)!.name, 'Phases of One Night #5000');
    });

    test('resolves, and the override reaches the member', () {
      final c = NyctisCollectionMetadata.fromJson(
        _document(extra: {'items_document': itemsPointer(body)}),
      ).resolveItemsDocument(body)!;

      expect(c.overrideFor(5000), isNotNull);
      expect(c.memberAt(5000)!.name, 'The Crown');
      expect(c.memberAt(5000)!.attributes.single.trait, 'Phase');
      // A member with no entry still renders from the template.
      expect(c.memberAt(4999)!.name, 'Phases of One Night #4999');
    });

    test('refuses a body whose length is not the declared one', () {
      // The check that makes the member worth having: a wallet decides whether
      // to spend before it spends, so the declaration has to be binding.
      final c = NyctisCollectionMetadata.fromJson(
        _document(extra: {'items_document': itemsPointer(body)}),
      );

      expect(
        c.resolveItemsDocument(Uint8List.fromList([...body, 32])),
        isNull,
      );
      expect(
        c.resolveItemsDocument(
          Uint8List.sublistView(body, 0, body.length - 1),
        ),
        isNull,
      );
    });

    test('refuses a body whose b2 does not match', () {
      final pointer = itemsPointer(body)
        ..['b2'] = nyctisB2Digest(utf8.encode('other'));
      final c = NyctisCollectionMetadata.fromJson(
        _document(extra: {'items_document': pointer}),
      );

      expect(c.resolveItemsDocument(body), isNull);
    });

    test('refuses a body that is not a JSON array', () {
      final notArray = Uint8List.fromList(utf8.encode('{"items":[]}'));
      final c = NyctisCollectionMetadata.fromJson(
        _document(extra: {'items_document': itemsPointer(notArray)}),
      );

      // The file's top level is the array itself, with nothing wrapping it.
      expect(c.resolveItemsDocument(notArray), isNull);
    });

    test('refuses a declaration past the 2 MiB ceiling, before fetching', () {
      final pointer = itemsPointer(body)
        ..['bytes'] = kNyctisItemsDocumentMaxBytes + 1;
      final c = NyctisCollectionMetadata.fromJson(
        _document(extra: {'items_document': pointer}),
      );

      expect(c.itemsDocument, isNull, reason: 'refused at parse, not at fetch');
    });

    test('the external form beats an inline items array', () {
      final c = NyctisCollectionMetadata.fromJson(
        _document(
          extra: {
            'items_document': itemsPointer(body),
            'items': [
              {'index': 5000, 'name': 'Something Else'},
            ],
          },
        ),
      ).resolveItemsDocument(body)!;

      expect(c.memberAt(5000)!.name, 'The Crown');
    });

    test('resolving items does not disturb a resolved digest table', () {
      // Both side files land on one document, and the second must not throw
      // away the first.
      final table = _table(10000);
      final c = NyctisCollectionMetadata.fromJson(
        _document(
          digestTable: _pointer(table),
          extra: {'items_document': itemsPointer(body)},
        ),
      ).resolveDigestTable(table)!.resolveItemsDocument(body)!;

      expect(c.hasResolvedDigestTable, isTrue);
      expect(c.digestAt(5000), _digestAt(table, 5000));
      expect(c.memberAt(5000)!.name, 'The Crown');
    });

    test('ten thousand traits fit where inline items reach 81', () {
      final many = itemsBytes([
        for (var i = 0; i < 10000; i++)
          {
            'index': i,
            'attributes': [
              {'trait': 'Phase', 'value': 'P$i'},
            ],
          },
      ]);
      final c = NyctisCollectionMetadata.fromJson(
        _document(extra: {'items_document': itemsPointer(many)}),
      ).resolveItemsDocument(many)!;

      expect(c.memberAt(9999)!.attributes.single.value, 'P9999');
      expect(many.length, lessThan(kNyctisItemsDocumentMaxBytes));
    });
  });
}
