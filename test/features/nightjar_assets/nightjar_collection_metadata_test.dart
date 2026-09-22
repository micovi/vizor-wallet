/// `spec/asset-collection-v0.md`: the collection document, the one
/// substitution it defines, and the digests that pin what it points at.
///
/// The rule under test in almost every case here is section 1's: the index
/// comes from the chain, because it is hashed into `asset_id` through `terms`.
/// A document that could supply its own index could rename any piece into any
/// other, and the shared form — one document for a hundred pieces — would stop
/// being safe. Most of the tests below are one phrasing or another of "the
/// document did not get to decide that".
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_asset_metadata.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_collection_metadata.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_digest.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_transport.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_artwork_data.dart';

import 'support/nightjar_metadata_fixtures.dart';

/// The reference collection, shaped like the one on the devnet: a template
/// with `{index}`, a `digests` array, and a `max_supply` the channel does not
/// have to agree with.
Map<String, Object?> _document({
  Map<String, Object?>? item,
  List<Object?>? digests,
  List<Object?>? items,
  Map<String, Object?>? extra,
}) => {
  'schema': 'nightjar-collection-metadata/1',
  'revision': 0,
  'name': 'Phases of One Night',
  'max_supply': 100,
  'item':
      item ??
      {
        'name': 'Phases of One Night #{index}',
        'image': 'https://example.invalid/pon/{index}.png',
      },
  'digests': ?digests,
  'items': ?items,
  ...?extra,
};

NightjarCollectionMetadata _parse(Map<String, Object?> json) =>
    NightjarCollectionMetadata.fromJson(json);

Uint8List _bytes(Map<String, Object?> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  final documentUri = Uri.parse('https://example.invalid/pon/c.json');
  const assetId = 'a1b2c3';

  // The digest of the one image every test serves, in the form section 3.3
  // writes it: `BLAKE2b-256`, base64url, unpadded — "exactly as `logo.b2`".
  final pngDigest = nightjarB2Digest(kOnePixelPng);

  Uri imageUri(int index) =>
      Uri.parse('https://example.invalid/pon/$index.png');

  group('section 3.2 — {index} comes from the chain', () {
    test('substitutes the on-chain index as decimal with no padding', () {
      final collection = _parse(_document());

      expect(collection.memberAt(7)!.image, imageUri(7));
      expect(collection.memberAt(7)!.name, 'Phases of One Night #7');
      // No padding: `007` would be a different URL and a different digest.
      expect(collection.memberAt(0)!.image, imageUri(0));
      expect(collection.memberAt(99)!.image, imageUri(99));
    });

    test('ignores an index the document supplies at the top level', () {
      // A document claiming `"index": 3` for everybody. There is no member to
      // read it — the parser has no such field — so the on-chain 7 is the only
      // index in play.
      final collection = _parse(_document(extra: {'index': 3}));

      expect(collection.memberAt(7)!.image, imageUri(7));
    });

    test(
      'an items entry selects an override and never supplies the index',
      () {
        final collection = _parse(
          _document(
            items: [
              {
                'index': 3,
                'image': 'https://example.invalid/pon/decoy.png',
                'name': 'Decoy',
              },
            ],
          ),
        );

        // Section 3.4: an entry whose index the wallet does not hold is
        // ignored. Resolving 7 must not pick up 3's override, and must not
        // substitute 3 into the template either.
        final seven = collection.memberAt(7)!;
        expect(seven.image, imageUri(7));
        expect(seven.name, 'Phases of One Night #7');

        // The same entry, asked for by its own index, is an override.
        final three = collection.memberAt(3)!;
        expect(three.image, Uri.parse('https://example.invalid/pon/decoy.png'));
        expect(three.name, 'Decoy');
      },
    );

    test('substitutes nothing the specification has not defined', () {
      final collection = _parse(
        _document(
          item: {'image': 'https://example.invalid/pon/{index}-{phase}.png'},
        ),
      );

      // `{phase}` is left literal, which makes the result not a URI. Section
      // 3.2: that is *the piece* having no artwork, never the collection being
      // invalid — so the document still parsed and the member still exists.
      final member = collection.memberAt(7)!;
      expect(member.image, isNull);
      expect(member.imageRejection, NightjarItemImageRejection.unresolvedToken);
    });

    test('refuses a substituted image that is not https', () {
      final collection = _parse(
        _document(item: {'image': 'http://example.invalid/pon/{index}.png'}),
      );

      final member = collection.memberAt(7)!;
      expect(member.image, isNull);
      expect(member.imageRejection, NightjarItemImageRejection.notHttps);
    });

    test('a negative index resolves to nothing', () {
      // `index` is a `u32` on the wire, so a negative one did not come from a
      // transition.
      expect(_parse(_document()).memberAt(-1), isNull);
    });
  });

  group('section 3.1 — max_supply is advisory in the document', () {
    test('a member whose index is past max_supply is still resolved', () {
      // "A wallet **MUST NOT** treat a member whose index is ≥ this as
      // invalid." Revision 5 renamed the member and kept the rule: the
      // document's number is a mirror of an on-chain cap, and the chain — not
      // the file — decides which members exist.
      final collection = _parse(_document());

      expect(collection.maxSupply, 100);
      expect(collection.memberAt(150)!.image, imageUri(150));
      expect(collection.memberAt(150)!.name, 'Phases of One Night #150');
    });

    test('the old `size` spelling is not read', () {
      // Revision 5 is a rename, not an alias. A document still written against
      // revision 4 declares no cap this wallet can see, which is the uncapped
      // reading — and uncapped is the safe direction: section 6 step 6f of
      // `transition-v0.md` lets a wallet call a capped collection's count
      // verified and forbids it for an uncapped one.
      final collection = _parse(
        _document(extra: const {'size': 100})..remove('max_supply'),
      );

      expect(collection.maxSupply, isNull);
      expect(collection.memberAt(150)!.image, imageUri(150));
    });

    test('an absent or zero max_supply is uncapped', () {
      final absent = _parse(_document()..remove('max_supply'));
      expect(absent.maxSupply, isNull);

      // Section 3.1 makes "0" and "absent" one state, so the model gives it
      // one representation rather than leaving every reader to remember that a
      // cap of zero is not a cap.
      final zero = _parse(_document(extra: const {'max_supply': 0}));
      expect(zero.maxSupply, isNull);
    });
  });

  group('section 3.3 — digests', () {
    test('pins the image at its own index', () {
      final collection = _parse(
        _document(digests: ['a' * 43, pngDigest, 'c' * 43]),
      );

      expect(collection.memberAt(1)!.digestB2, pngDigest);
      expect(collection.memberAt(1)!.isPinned, isTrue);
    });

    test('a short array leaves the tail unpinned, not invalid', () {
      final collection = _parse(_document(digests: [pngDigest]));

      final unpinned = collection.memberAt(7)!;
      expect(unpinned.digestB2, isNull);
      expect(unpinned.isPinned, isFalse);
      // Unpinned is not "no artwork": the image is still resolved and still
      // fetched, it is simply revocable by whoever holds the host.
      expect(unpinned.image, imageUri(7));
    });

    test('an unreadable entry is a hole, not a shift', () {
      // Compacting a bad entry out would move every later digest down one and
      // pin each piece with its neighbour's hash — every image would then fail
      // section 3.3's MUST and the bug would read as a hostile host.
      final collection = _parse(
        _document(digests: ['not-a-digest', pngDigest]),
      );

      expect(collection.digests.length, 2);
      expect(collection.memberAt(0)!.digestB2, isNull);
      expect(collection.memberAt(1)!.digestB2, pngDigest);
    });

    test('an items entry overrides the array for its own index', () {
      final collection = _parse(
        _document(
          digests: ['a' * 43, 'b' * 43],
          items: [
            {'index': 1, 'b2': pngDigest},
          ],
        ),
      );

      expect(collection.memberAt(1)!.digestB2, pngDigest);
      expect(collection.memberAt(0)!.digestB2, 'a' * 43);
    });
  });

  group('the document itself', () {
    test('rejects a schema major it does not implement', () {
      expect(
        () => _parse(_document(extra: {'schema': 'nightjar-collection-'
            'metadata/2'})),
        throwsA(isA<NightjarMetadataFormatException>()),
      );
    });

    test('treats a malformed schema as an unrecognized major', () {
      // `asset-metadata-v0.md` section 4.4: a leading zero is malformed, and a
      // malformed schema is an unrecognized major rather than a parse failure
      // to surface. Both land as the same refusal here.
      expect(
        () => _parse(_document(extra: {'schema': 'nightjar-collection-'
            'metadata/01'})),
        throwsA(isA<NightjarMetadataFormatException>()),
      );
      expect(nightjarSchemaMajor('nightjar-collection-metadata/01',
          kNightjarCollectionSchemaFamily), isNull);
      expect(nightjarSchemaMajor('nightjar-collection-metadata/1',
          kNightjarCollectionSchemaFamily), 1);
    });

    test('rejects a document with no item template', () {
      final json = _document()..remove('item');
      expect(
        () => _parse(json),
        throwsA(isA<NightjarMetadataFormatException>()),
      );
    });

    test('ignores members it does not recognize, at every level', () {
      final collection = _parse(
        _document(
          extra: {'futureThing': 42, 'revision': 9},
          items: [
            {'index': 1, 'name': 'One', 'futureThing': 'x'},
          ],
        ),
      );

      expect(collection.revision, 9);
      expect(collection.memberAt(1)!.name, 'One');
    });

    test('carries website and links on the asset document rules', () {
      final collection = _parse(
        _document(
          extra: {
            'website': 'https://example.invalid/',
            'links': [
              {'rel': 'github', 'uri': 'https://github.com/example'},
              {'rel': 'http-only', 'uri': 'http://example.invalid'},
            ],
          },
        ),
      );

      expect(collection.website, Uri.parse('https://example.invalid/'));
      expect(collection.links.length, 1);
      expect(collection.links.single.rel, 'github');
    });
  });

  group('fetching a collection member', () {
    /// A transport serving the document plus images at `/0.png` … `/9.png`.
    FakeNightjarTransport transport({
      Map<String, Object?>? document,
      Uint8List? image,
      Map<Uri, NightjarHttpReply> extra = const {},
    }) => FakeNightjarTransport({
      documentUri: NightjarHttpReply(
        statusCode: 200,
        body: _bytes(document ?? _document(digests: [pngDigest, pngDigest])),
      ),
      for (var i = 0; i < 10; i++)
        imageUri(i): NightjarHttpReply(
          statusCode: 200,
          body: image ?? kOnePixelPng,
        ),
      ...extra,
    });

    test('fetches the image for the on-chain index, and only that one', () async {
      final fake = transport();
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: documentUri.toString(),
        index: 1,
      );

      expect(outcome.memberView, isNotNull);
      expect(outcome.memberView!.index, 1);
      expect(outcome.hasImage, isTrue);
      expect(outcome.imagePinned, isTrue);
      // One document, one image, and the image is the one the *chain* named.
      expect(fake.requested, [documentUri, imageUri(1)]);
    });

    test('a digest mismatch discards the image without retrying', () async {
      // The host serves a real PNG whose hash is not the one the document
      // pinned for this index. Section 3.3: discard, and do not retry a
      // different source.
      final fake = transport(
        document: _document(digests: ['a' * 43, 'b' * 43]),
      );
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: documentUri.toString(),
        index: 1,
      );

      expect(outcome.hasImage, isFalse);
      expect(
        outcome.memberView!.imageReason,
        NightjarMetadataAbandonReason.digestMismatch,
      );
      // Exactly two requests: the document and the one image. No second
      // attempt, at this URL or any other.
      expect(fake.requested, [documentUri, imageUri(1)]);

      final data = NightjarArtworkData.fromOutcome(outcome);
      expect(data.status, NightjarArtworkStatus.refused);
      expect(data.hasImage, isFalse);
    });

    test('a missing digest renders as unpinned, not as a failure', () async {
      // `digests` covers index 0 only; index 1 is past the end of it.
      final fake = transport(document: _document(digests: [pngDigest]));
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: documentUri.toString(),
        index: 1,
      );

      expect(outcome.hasImage, isTrue);
      expect(outcome.imagePinned, isFalse);
      expect(outcome.memberView!.isUnpinned, isTrue);

      final data = NightjarArtworkData.fromOutcome(outcome);
      expect(data.status, NightjarArtworkStatus.unpinned);
      // The distinction section 3.3 exists for: a picture is drawn either way,
      // and the two states are not the same state.
      expect(data.hasImage, isTrue);
      expect(data.isPinned, isFalse);
    });

    test('the shared document is fetched once for the whole collection', () async {
      // `asset-collection-v0.md` section 2: the members' `uri` may be the same
      // string, and a wallet holding forty pieces fetches it **once**. Without
      // this the shared form is only tidier, not more private.
      final fake = transport();
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      await Future.wait([
        for (var i = 0; i < 4; i++)
          fetcher.fetchArtwork(
            assetId: 'piece$i',
            uri: documentUri.toString(),
            index: i,
          ),
      ]);

      expect(fake.requested.where((uri) => uri == documentUri).length, 1);
      expect(
        fake.requested.where((uri) => uri != documentUri).toSet(),
        {imageUri(0), imageUri(1), imageUri(2), imageUri(3)},
      );
    });

    test('a member with no on-chain index gets no artwork', () async {
      final fake = transport();
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: documentUri.toString(),
      );

      expect(outcome.reason, NightjarMetadataAbandonReason.documentRefused);
      // The document was read; no image was, because there is no index to
      // substitute and section 3.2 allows exactly one source for it.
      expect(fake.requested, [documentUri]);
    });

    test('a template that does not resolve costs the piece, not the document',
        () async {
      final fake = transport(
        document: _document(
          item: {'image': 'https://example.invalid/pon/{phase}.png'},
        ),
      );
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: documentUri.toString(),
        index: 1,
      );

      // A member view, not an abandonment: the collection parsed, its name and
      // links are still worth drawing, and this one piece has no artwork.
      expect(outcome.memberView, isNotNull);
      expect(outcome.memberView!.collection.name, 'Phases of One Night');
      expect(
        outcome.memberView!.imageReason,
        NightjarMetadataAbandonReason.noImage,
      );
      expect(fake.requested, [documentUri]);
    });

    test('a collection document over 16 KiB is refused', () async {
      final fake = FakeNightjarTransport({
        documentUri: NightjarHttpReply(
          statusCode: 200,
          body: Uint8List(kNightjarDocumentMaxBytes + 1),
        ),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: documentUri.toString(),
        index: 1,
      );

      // Section 3.4 is explicit that the limit binds here too: a publisher
      // whose `items` will not fit must use the per-piece form rather than
      // have a wallet raise it.
      expect(outcome.reason, NightjarMetadataAbandonReason.tooLarge);
      expect(outcome.hasImage, isFalse);
    });

    test("a member's image over 256 KiB is refused", () async {
      final fake = transport(
        document: _document(),
        image: Uint8List(kNightjarLogoMaxBytes + 1),
      );
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: documentUri.toString(),
        index: 1,
      );

      expect(outcome.hasImage, isFalse);
      expect(
        outcome.memberView!.imageReason,
        NightjarMetadataAbandonReason.tooLarge,
      );
    });

    test('an SVG served as a member image is refused', () async {
      final fake = transport(document: _document(), image: kSvgBytes);
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: documentUri.toString(),
        index: 1,
      );

      expect(outcome.hasImage, isFalse);
      expect(
        outcome.memberView!.imageReason,
        NightjarMetadataAbandonReason.imageFormatRefused,
      );
    });

    test('an http: collection uri is refused before any request', () async {
      final fake = FakeNightjarTransport(const {});
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: 'http://example.invalid/pon/c.json',
        index: 1,
      );

      expect(outcome.reason, NightjarMetadataAbandonReason.pointerRefused);
      expect(fake.requested, isEmpty);
    });

    test('a member image that redirects off-origin is refused', () async {
      // Section 2 of `asset-metadata-v0.md`, which section 3.2 of the
      // collection spec defers to: the comparison is against the origin the
      // fetch *started* at, so a chain cannot walk somewhere one hop at a time.
      final fake = transport(
        document: _document(),
        extra: {
          imageUri(1): NightjarHttpReply(
            statusCode: 302,
            body: Uint8List(0),
            location: 'https://elsewhere.invalid/pon/1.png',
          ),
        },
      );
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: documentUri.toString(),
        index: 1,
      );

      expect(outcome.hasImage, isFalse);
      expect(
        outcome.memberView!.imageReason,
        NightjarMetadataAbandonReason.redirectRefused,
      );
      // The redirect was never followed: nothing was asked of the other host.
      expect(
        fake.requested.any((uri) => uri.host == 'elsewhere.invalid'),
        isFalse,
      );
    });

    test('a #b2= that does not match the document is discarded', () async {
      final fake = transport();
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: '$documentUri#b2=${'a' * 43}',
        index: 1,
      );

      expect(outcome.reason, NightjarMetadataAbandonReason.digestMismatch);
      // Section 2.1: discarded without retrying a different source.
      expect(fake.requested, [documentUri]);
    });

    test('a pinned document reports its pin to the UI', () async {
      final bytes = _bytes(_document(digests: [pngDigest, pngDigest]));
      final fake = FakeNightjarTransport({
        documentUri: NightjarHttpReply(statusCode: 200, body: bytes),
        imageUri(1): NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: '$documentUri#b2=${nightjarB2Digest(bytes)}',
        index: 1,
      );

      final data = NightjarArtworkData.fromOutcome(outcome);
      expect(data.status, NightjarArtworkStatus.verified);
      expect(data.documentPinned, isTrue);
      expect(data.sourceOrigin, 'example.invalid');
    });

    test('forgetting the last member drops the shared document too', () async {
      final fake = transport();
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      await fetcher.fetchArtwork(
        assetId: 'one',
        uri: documentUri.toString(),
        index: 0,
      );
      await fetcher.fetchArtwork(
        assetId: 'two',
        uri: documentUri.toString(),
        index: 1,
      );
      expect(fake.requested.where((uri) => uri == documentUri).length, 1);

      // One member forgotten: the other thirty-nine must not pay for it with a
      // fresh request.
      fetcher.forget('one');
      await fetcher.fetchArtwork(
        assetId: 'two',
        uri: documentUri.toString(),
        index: 1,
      );
      expect(fake.requested.where((uri) => uri == documentUri).length, 1);

      // Nothing draws from it any more, so the wallet stops holding it.
      fetcher.forget('two');
      await fetcher.fetchArtwork(
        assetId: 'two',
        uri: documentUri.toString(),
        index: 1,
      );
      expect(fake.requested.where((uri) => uri == documentUri).length, 2);
    });
  });

  group('an asset document is still an asset document', () {
    test('a uri pointing at one is parsed as one, index or no index', () async {
      final assetDocument = Uri.parse('https://example.invalid/nj/gold.json');
      final logo = Uri.parse('https://example.invalid/nj/gold.png');
      final fake = FakeNightjarTransport({
        assetDocument: NightjarHttpReply(
          statusCode: 200,
          body: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'schema': 'nightjar-asset-metadata/1',
                'description': 'A demonstration asset.',
                'logo': {'uri': logo.toString()},
              }),
            ),
          ),
        ),
        logo: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      // Section 4 of `asset-collection-v0.md` lets a collection member point
      // at a per-piece document, so having an index must not force the
      // collection parser on a document that is not one.
      final outcome = await fetcher.fetchArtwork(
        assetId: assetId,
        uri: assetDocument.toString(),
        index: 7,
      );

      expect(outcome.assetView, isNotNull);
      expect(outcome.memberView, isNull);
      expect(outcome.hasImage, isTrue);
    });
  });

  group("the collection's own logo (section 3.5)", () {
    final logoUri = Uri.parse('https://example.invalid/pon/logo.png');

    test('is parsed by the section 4.2 parser, not a second one', () {
      final parsed = _parse(
        _document(
          extra: {
            'logo': {
              'uri': logoUri.toString(),
              'b2': nightjarB2Digest(kOnePixelPng),
              // Advisory, and section 3.5 defers to section 4.2, which makes
              // trusting it forbidden. The type is the proof: a
              // `NightjarAssetLogoRef` has nowhere to put these.
              'mime': 'image/svg+xml',
              'width': 999999,
              'height': 999999,
            },
          },
        ),
      );

      expect(parsed.logo, isA<NightjarAssetLogoRef>());
      expect(parsed.logo!.uri, logoUri);
      expect(parsed.logo!.isPinned, isTrue);
    });

    test('drops a non-https uri without costing the document', () {
      // Section 3.5, via `asset-metadata-v0.md` section 4.1: a bad member
      // costs the member, never the document. Ninety-nine pieces do not lose
      // their artwork over the collection's own picture.
      final parsed = _parse(
        _document(
          extra: {
            'logo': {'uri': 'http://example.invalid/pon/logo.png'},
          },
        ),
      );

      expect(parsed.logo, isNull);
      expect(parsed.memberAt(7)!.image, isNotNull);
    });

    test('an absent b2 is unpinned, not invalid', () {
      final parsed = _parse(
        _document(
          extra: {
            'logo': {'uri': logoUri.toString()},
          },
        ),
      );

      expect(parsed.logo, isNotNull);
      expect(parsed.logo!.isPinned, isFalse);
    });

    test('is not pinned by digests, and does not consume an entry', () {
      // `digests[i]` is the image for member `i` and the collection's picture
      // has no index. A reader that let the two share an array would pin every
      // piece with its neighbour's hash.
      final parsed = _parse(
        _document(
          digests: [nightjarB2Digest(kOnePixelPng)],
          extra: {
            'logo': {'uri': logoUri.toString()},
          },
        ),
      );

      expect(parsed.digestAt(0), nightjarB2Digest(kOnePixelPng));
      expect(parsed.memberAt(0)!.isPinned, isTrue);
      expect(parsed.logo!.digestB2, isNull);
    });

    test('a document with no logo is the ordinary case, not a failure', () {
      final parsed = _parse(_document());
      expect(parsed.logo, isNull);
      expect(parsed.memberAt(3), isNotNull);
    });
  });

  group("fetching the collection's logo", () {
    final logoUri = Uri.parse('https://example.invalid/pon/logo.png');

    FakeNightjarTransport transportWith(Uint8List logoBytes, {String? b2}) =>
        FakeNightjarTransport({
          documentUri: NightjarHttpReply(
            statusCode: 200,
            body: _bytes(
              _document(
                digests: [for (var i = 0; i < 10; i++) pngDigest],
                extra: {
                  'logo': {'uri': logoUri.toString(), 'b2': ?b2},
                },
              ),
            ),
          ),
          for (var i = 0; i < 10; i++)
            Uri.parse('https://example.invalid/pon/$i.png'):
                NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
          logoUri: NightjarHttpReply(statusCode: 200, body: logoBytes),
        });

    test('once per document, however many members ask for it', () async {
      // The whole saving of the shared form, applied to section 3.5: forty
      // accepted pieces of one collection make one request for one picture.
      final fake = transportWith(kOtherPng, b2: nightjarB2Digest(kOtherPng));
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      for (var i = 0; i < 5; i++) {
        final outcome = await fetcher.fetchArtwork(
          assetId: 'piece$i',
          uri: documentUri.toString(),
          index: i,
        );
        expect(outcome.memberView!.collectionLogoBytes, kOtherPng);
        expect(outcome.memberView!.collectionLogoPinned, isTrue);
      }

      expect(fake.requested.where((uri) => uri == logoUri).length, 1);
      expect(fake.requested.where((uri) => uri == documentUri).length, 1);
    });

    test('a mismatching b2 is discarded without retrying', () async {
      // Section 3.5 repeats section 4.2's MUST: verify it, discard a
      // mismatching image, and do not try another source.
      final fake = transportWith(
        kOtherPng,
        b2: nightjarB2Digest(kOnePixelPng),
      );
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: 'piece0',
        uri: documentUri.toString(),
        index: 0,
      );

      expect(outcome.memberView!.collectionLogoBytes, isNull);
      expect(outcome.memberView!.collectionLogoPinned, isFalse);
      // The piece's own artwork is untouched: a refused collection picture is
      // not a refused collection.
      expect(outcome.memberView!.imageBytes, isNotNull);
      expect(fake.requested.where((uri) => uri == logoUri).length, 1);
    });

    test('an SVG is refused however the document labels it', () async {
      final fake = transportWith(kSvgBytes);
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: 'piece0',
        uri: documentUri.toString(),
        index: 0,
      );

      expect(outcome.memberView!.collectionLogoBytes, isNull);
    });

    test('a document with no logo asks no host for one', () async {
      final fake = FakeNightjarTransport({
        documentUri: NightjarHttpReply(
          statusCode: 200,
          body: _bytes(_document(digests: [pngDigest])),
        ),
        Uri.parse('https://example.invalid/pon/0.png'): NightjarHttpReply(
          statusCode: 200,
          body: kOnePixelPng,
        ),
      });
      final fetcher = NightjarAssetMetadataFetcher(transport: fake);

      final outcome = await fetcher.fetchArtwork(
        assetId: 'piece0',
        uri: documentUri.toString(),
        index: 0,
      );

      expect(outcome.memberView!.collectionLogoBytes, isNull);
      expect(fake.requested, isNot(contains(logoUri)));
    });
  });
}
