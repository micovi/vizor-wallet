/// The artwork chain end to end, against **published bytes** rather than
/// bytes a test wrote to match itself.
///
/// `nightjar_collection_artwork_widget_test.dart` beside this one exercises
/// the same code with a synthetic document, a 1×1 PNG and a digest computed
/// from that PNG. That suite proves the wiring; it cannot fail if the
/// publisher's real document and the wallet's reader disagree, because the
/// only thing it ever compares the wallet against is itself.
///
/// This one closes that. Every byte here was fetched from the devnet's own
/// sources and checked in verbatim:
///
/// * `fixtures/pon/c.json` — 6 076 bytes, exactly what
///   `https://raw.githubusercontent.com/micovi/nightjar-assets/main/pon/c.json`
///   serves: `schema: nightjar-collection-metadata/1`, `max_supply: 100` — the
///   revision-4 spelling, which revision 5 renamed to `max_supply` and this
///   published file predates — an
///   `item.image` carrying the `{index}` token, and **100 `digests`**;
/// * `fixtures/pon/art/0.png` … `9.png` — the publisher's own images, 2 556 to
///   3 084 bytes, 512×512 PNGs;
/// * [_members] — the ten `(index, asset_id)` pairs the devnet indexer reports
///   at `/api/assets` for collection `c3d9066b…`, the same table
///   `rust/src/nightjar/testdata.rs` asserts the replay reproduces.
///
/// So the digests these tests verify are the publisher's digests over the
/// publisher's images, and a picture drawn here is the picture a user would
/// see. If the publisher re-renders `4.png` without updating `digests[4]`,
/// this suite goes red — which is the point: it is the only thing in the tree
/// that would notice.
///
/// **What it deliberately does not do is reach the network.** The bytes are on
/// disk and served through [FakeNightjarTransport], so the suite is
/// hermetic and every request the wallet makes is recorded and asserted. A URL
/// the fetcher resolves wrongly gets a 404 from the fake, not a picture.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_collection_metadata.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_asset_acceptance_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_asset_metadata_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_collections_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_metadata_fetcher_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/nightjar_collection_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_image_format.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_digest.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_transport.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_collection_grid.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_collection_mapper.dart';

import 'support/nightjar_metadata_fixtures.dart';

// ---------------------------------------------------------------------------
// The chain, as the devnet published it.
// ---------------------------------------------------------------------------

const String _collectionId =
    'c3d9066bfe739238bdf9aa2b3b325eaf9bbd7e16e8a767aac9f0cac0697b5004';

/// The `uri` all ten pieces carry, verbatim and unpinned — the real `ASSET`
/// messages name this document with **no `#b2=` fragment**, which is why
/// [NightjarArtworkData.documentPinned] is false throughout and the image
/// digests are the only thing pinning anything.
const String _documentUri =
    'https://raw.githubusercontent.com/micovi/nightjar-assets/main/pon/c.json';

/// `(index, asset_id)` for every member, from the devnet indexer's
/// `/api/assets` at tip 842.
///
/// The pairing is the whole assertion. `index` is hashed into `asset_id`
/// through `terms` (`spec/note-format-v0.md` section 8) and the wallet's
/// replay verifies the proof that says so, so these ten rows are what decides
/// which of `pon/0.png` … `pon/9.png` belongs under which id. Swapping any two
/// of them is the exact defect a shared collection document would otherwise
/// let a host introduce.
const List<(int, String)> _members = [
  (0, '85544f0793d86b23bebafbd382cc255a4815e512b3b8110721a80a1620eebd0f'),
  (1, '884c02bccca7d5349d90573b27987015abea06d57dc4b80f10ab70612859da01'),
  (2, '7b6bcea338b3cd48e57892049b72288fc98ddcdde6e333110f7d6c714e2c0c00'),
  (3, 'f114349ee3b5d5054e99e17f4a1c2bccfa417e9d31edbdd1eeec24f12e00340e'),
  (4, 'ee76f4ade2a79cae1f0ad661082d410163f31dadef5d7fe0c03d0538cfebb811'),
  (5, '112e167da6935691dae8bb21b57ffcf50e148e9051c269764c01210258700404'),
  (6, '9abad2a736aeba75ab8e09e83b412b602840ed0b57c95830c3338c613fa17f03'),
  (7, 'd96a1518235237504fc30f8ba49949efeec00e29c072126e9546f683a8550c00'),
  (8, '0d0c434c003ae2915c8bffb4cda172eff17dae3c7444e46b4b59b177fbbec200'),
  (9, '03a5321feb32503f8e7a4922650cd1fa16888c6f3d769852e86d6d1eade0750a'),
];

const String _fixtureDir = 'test/features/nightjar_assets/fixtures/pon';

Uint8List _documentBytes() =>
    File('$_fixtureDir/c.json').readAsBytesSync();

Uint8List _imageBytes(int index) =>
    File('$_fixtureDir/art/$index.png').readAsBytesSync();

/// `.../pon/<index>.png` — written out here rather than derived from the
/// document's own template, so that the expected URL is a constant of this
/// test and not a second evaluation of the code under test.
/// The collection's own picture (section 3.5), added to the published
/// document in revision 3. It is not a member and has no index.
final Uri _logoUri = Uri.parse(
  'https://raw.githubusercontent.com/micovi/nightjar-assets/main/pon/logo.png',
);

Uri _imageUri(int index) => Uri.parse(
  'https://raw.githubusercontent.com/micovi/nightjar-assets/main/pon/art/'
  '$index.png',
);

/// One member as the wallet's view reports it, with the **on-chain** index.
NightjarAssetDetailData _piece((int, String) member, {bool owned = false}) =>
    NightjarAssetDetailData(
      assetId: member.$2,
      name: 'Phases of One Night #${member.$1}',
      symbol: 'PON',
      collection: _collectionId,
      index: member.$1,
      isPublic: true,
      balance: owned ? BigInt.one : BigInt.zero,
      decimals: 0,
      issuedSupply: BigInt.one,
      maxSupply: BigInt.one,
      metadataUri: _documentUri,
    );

/// The real document with its `digests` array truncated to [keep] entries.
///
/// Section 3.3 of `spec/asset-collection-v0.md`: a short array leaves the
/// remaining pieces **unpinned, not invalid**. Truncating the publisher's own
/// array is how this suite produces that state without inventing a document.
Uint8List _documentWithDigests(int keep) {
  final decoded =
      (jsonDecode(utf8.decode(_documentBytes())) as Map)
          .cast<String, Object?>();
  final digests = (decoded['digests']! as List).take(keep).toList();
  return Uint8List.fromList(
    utf8.encode(jsonEncode({...decoded, 'digests': digests})),
  );
}

/// Serves the published bytes and nothing else. Anything the fetcher asks for
/// that is not in this map comes back 404, so a wrongly resolved `{index}` is
/// a refused tile rather than a silently different picture.
FakeNightjarTransport _transport({
  Uint8List? document,
  Iterable<int> images = const [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
}) => FakeNightjarTransport({
  Uri.parse(_documentUri): NightjarHttpReply(
    statusCode: 200,
    body: document ?? _documentBytes(),
  ),
  for (final i in images)
    _imageUri(i): NightjarHttpReply(statusCode: 200, body: _imageBytes(i)),
});

class _MemoryAcceptanceStore implements NightjarAcceptanceStore {
  String? value;

  @override
  Future<void> write(String encoded) async => value = encoded;

  @override
  Future<void> clear() async => value = null;
}

AppBootstrapState _bootstrap(NightjarAssetAcceptance acceptance) =>
    AppBootstrapState(
      initialLocation: '/',
      initialAccountState: AppBootstrapState.empty.initialAccountState,
      initialSyncSnapshot: AppBootstrapState.empty.initialSyncSnapshot,
      network: AppBootstrapState.empty.network,
      rpcEndpointConfig: AppBootstrapState.empty.rpcEndpointConfig,
      nightjarAcceptedAssets: acceptance,
      themeMode: AppBootstrapState.empty.themeMode,
      privacyModeEnabled: false,
      isPasswordConfigured: false,
      isUnlocked: false,
      passwordRotationRecoveryFailed: false,
    );

NightjarAssetAcceptance _acceptAll(List<(int, String)> members) =>
    NightjarAssetAcceptance([
      for (final member in members) NightjarAcceptedAsset(assetId: member.$2),
    ]);

Future<FakeNightjarTransport> _pump(
  WidgetTester tester, {
  required List<(int, String)> members,
  FakeNightjarTransport? transport,
}) async {
  await tester.binding.setSurfaceSize(const Size(460, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final fake = transport ?? _transport();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appBootstrapProvider.overrideWithValue(_bootstrap(_acceptAll(members))),
        nightjarAcceptanceStoreProvider.overrideWithValue(
          _MemoryAcceptanceStore(),
        ),
        nightjarMetadataFetcherProvider.overrideWithValue(
          NightjarAssetMetadataFetcher(transport: fake),
        ),
        nightjarViewLoaderProvider.overrideWithValue(
          () async => NightjarViewData(
            status: NightjarViewStatus.ready,
            assets: [for (final m in members) _piece(m, owned: m.$1 < 3)],
          ),
        ),
      ],
      child: MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: Consumer(
            builder: (context, ref, _) => CustomScrollView(
              slivers: buildNightjarCollectionSlivers(
                collectionId: _collectionId,
                collection: ref.watch(
                  nightjarCollectionProvider(_collectionId),
                ),
                horizontalPadding: 12,
                onMemberTap: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

/// The bytes the tile for [assetId] actually handed to the engine.
///
/// Reaching through [ResizeImage] on purpose: `Image.memory` with
/// `cacheWidth`/`cacheHeight` wraps the provider, and a test that only
/// asserted "an `Image` exists" would pass for a tile drawing the wrong
/// picture. What is asserted is the byte array.
Uint8List? _drawnBytes(WidgetTester tester, String assetId) {
  final tile = find.byWidgetPredicate(
    (w) => w is NightjarCollectionTile && w.member.assetId == assetId,
  );
  final image = find.descendant(
    of: tile,
    matching: find.byKey(const ValueKey('nightjar_logo_image')),
  );
  if (image.evaluate().isEmpty) return null;
  final provider = tester.widget<Image>(image).image;
  final memory = provider is ResizeImage ? provider.imageProvider : provider;
  return (memory as MemoryImage).bytes;
}

/// How many **member tiles** draw a picture.
///
/// Scoped to the tiles rather than counting every `nightjar_logo_image` on the
/// screen: the collection header draws a picture of its own
/// (`asset-collection-v0.md` section 3.5), and a bare count would make this
/// suite fail — or pass — for reasons that have nothing to do with the grid.
int _tilePicturesDrawn(WidgetTester tester) => find
    .descendant(
      of: find.byType(NightjarCollectionTile),
      matching: find.byKey(const ValueKey('nightjar_logo_image')),
    )
    .evaluate()
    .length;

/// How many member tiles show [text] in their empty frame.
int _tilesSaying(WidgetTester tester, String text) => find
    .descendant(
      of: find.byType(NightjarCollectionTile),
      matching: find.text(text),
    )
    .evaluate()
    .length;

int _unpinnedBadges(WidgetTester tester) => find
    .descendant(
      of: find.byType(NightjarCollectionTile),
      matching: find.byKey(const ValueKey('nightjar_artwork_unpinned_badge')),
    )
    .evaluate()
    .length;

bool _hasUnpinnedBadge(WidgetTester tester, String assetId) {
  final tile = find.byWidgetPredicate(
    (w) => w is NightjarCollectionTile && w.member.assetId == assetId,
  );
  return find
      .descendant(
        of: tile,
        matching: find.byKey(const ValueKey('nightjar_artwork_unpinned_badge')),
      )
      .evaluate()
      .isNotEmpty;
}

void main() {
  group('the published document pins the published images', () {
    test('every fixture is the byte stream the devnet serves', () {
      // Sizes are stated so a silently re-downloaded or re-encoded fixture is
      // caught here rather than as a confusing digest failure three tests
      // down.
      expect(_documentBytes().length, 6076, reason: 'pon/c.json');
      expect(
        [for (var i = 0; i < 10; i++) _imageBytes(i).length],
        [2556, 2605, 2783, 2917, 3084, 2801, 2653, 2770, 2954, 3040],
      );
    });

    test('the document parses as a collection and carries 100 digests', () {
      final collection = NightjarCollectionMetadata.parseBytes(
        _documentBytes(),
      );
      expect(collection.name, 'Phases of One Night');
      expect(collection.digests.length, 100);
      expect(collection.item.image, contains(kNightjarIndexToken));
    });

    test('the published document declares its cap under the new name', () {
      // The real `pon/c.json` was republished for revision 5 and now says
      // `max_supply: 100`. The rename is not an alias — the old spelling is
      // not read — so this test is what would catch a republication that
      // reverted it: the document would parse, every piece would still
      // resolve, and the collection would quietly read as uncapped.
      //
      // Note what this number is and is not. It mirrors the cap bound into
      // `collection_id` (`transition-v0.md` section 5); it does not establish
      // one. Section 3.1's older rule stands — the document's own count
      // decides nothing, and the wallet compares it against the chain.
      final decoded =
          (jsonDecode(utf8.decode(_documentBytes())) as Map)
              .cast<String, Object?>();
      expect(decoded['max_supply'], 100);
      expect(decoded.containsKey('size'), isFalse);

      expect(
        NightjarCollectionMetadata.parseBytes(_documentBytes()).maxSupply,
        100,
      );
      // And every one of the hundred pieces still resolves through it.
      expect(
        NightjarCollectionMetadata.parseBytes(
          _documentBytes(),
        ).memberAt(99)!.image,
        _imageUri(99),
      );
    });

    test('digests[i] is BLAKE2b-256 of the real pon/i.png, for all ten', () {
      // The one assertion that proves the pinning works against **published**
      // data. Nothing here computes a digest and then checks it against
      // itself: `digests` came off the publisher's host and the bytes came off
      // the publisher's host, separately.
      final collection = NightjarCollectionMetadata.parseBytes(
        _documentBytes(),
      );
      for (var i = 0; i < 10; i++) {
        final bytes = _imageBytes(i);
        final member = collection.memberAt(i)!;
        expect(
          member.image.toString(),
          _imageUri(i).toString(),
          reason: '{index} resolved for piece $i',
        );
        expect(member.digestB2, collection.digests[i]);
        expect(
          nightjarB2DigestMatches(member.digestB2!, bytes),
          isTrue,
          reason: 'digests[$i] must pin pon/$i.png; got '
              '${nightjarB2Digest(bytes)}',
        );
        expect(sniffNightjarImageFormat(bytes), NightjarImageFormat.png);
      }
    });

    test('and they are real 512x512 images, not eleven-byte stubs', () async {
      // Decoded through the engine's own codec. A "picture" that the decoder
      // refuses is a placeholder with extra steps, and the widget's
      // `errorBuilder` would draw the empty frame for it.
      for (var i = 0; i < 10; i++) {
        final codec = await ui.instantiateImageCodec(_imageBytes(i));
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 512);
        expect(frame.image.height, 512);
        frame.image.dispose();
        codec.dispose();
      }
    });
  });

  group('the grid draws the published pictures', () {
    testWidgets('ten tiles, ten pictures, one document', (tester) async {
      final fake = await _pump(tester, members: _members);

      expect(_tilePicturesDrawn(tester), 10);
      expect(_tilesSaying(tester, kNightjarArtworkNotAcceptedTileText), 0);
      expect(_tilesSaying(tester, kNightjarArtworkRefusedTileText), 0);
      expect(_tilesSaying(tester, kNightjarArtworkPendingTileText), 0);

      // Section 2: one request for the document, however many pieces name it.
      expect(
        fake.requested.where((u) => u.toString() == _documentUri).length,
        1,
      );

      // The resolved image URLs, exactly, plus the collection's own picture.
      // This is `{index}` substitution observed from outside the code that
      // performs it — and the eleventh request is not a leak: section 3.5's
      // `logo` belongs to the document, is fetched once for the whole
      // collection, and its URL carries no index.
      expect(
        fake.requested.where((u) => u.toString() != _documentUri).toSet(),
        {_logoUri, for (var i = 0; i < 10; i++) _imageUri(i)},
      );
    });

    testWidgets('and each tile holds its own piece, not its neighbour\'s', (
      tester,
    ) async {
      await _pump(tester, members: _members);

      for (final (index, assetId) in _members) {
        expect(
          _drawnBytes(tester, assetId),
          _imageBytes(index),
          reason: 'the tile for $assetId must draw pon/$index.png',
        );
      }
    });

    testWidgets('every piece reads as verified, because all 100 digests are '
        'published', (tester) async {
      await _pump(tester, members: _members);

      expect(_unpinnedBadges(tester), 0);
    });
  });

  group('the index comes from the chain, not from the list', () {
    // The ten-piece case cannot tell the two apart: piece `i` sits at position
    // `i`, so a wallet that used a position would draw the same grid. Three
    // members whose indices are 3, 7 and 9 sit at positions 0, 1 and 2, and
    // only the on-chain reading produces the right pictures.
    final sparse = [_members[3], _members[7], _members[9]];

    testWidgets('three pieces at positions 0,1,2 fetch 3.png, 7.png, 9.png', (
      tester,
    ) async {
      final fake = await _pump(
        tester,
        members: sparse,
        transport: _transport(images: const [3, 7, 9]),
      );

      expect(
        fake.requested.where((u) => u.toString() != _documentUri).toSet(),
        {_logoUri, _imageUri(3), _imageUri(7), _imageUri(9)},
        reason: 'positions 0,1,2 would have asked for 0.png, 1.png, 2.png',
      );
      for (final (index, assetId) in sparse) {
        expect(_drawnBytes(tester, assetId), _imageBytes(index));
      }
    });

    testWidgets('a member with no on-chain index gets no artwork rather than '
        'piece zero', (tester) async {
      // `asset-collection-v0.md` section 3.2 names exactly one source for the
      // index. A wallet that fell back to 0 would hand every unindexed member
      // the first piece's picture — a wrong picture under a right id, which is
      // worse than an empty frame.
      await tester.binding.setSurfaceSize(const Size(460, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fake = _transport();
      final members = [
        for (final m in sparse) _piece(m),
      ];
      final unindexed = NightjarAssetDetailData(
        assetId:
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        name: 'Phases of One Night #?',
        collection: _collectionId,
        isPublic: true,
        balance: BigInt.zero,
        decimals: 0,
        issuedSupply: BigInt.one,
        maxSupply: BigInt.one,
        metadataUri: _documentUri,
      );
      expect(unindexed.index, isNull);

      final container = ProviderContainer(
        overrides: [
          appBootstrapProvider.overrideWithValue(
            _bootstrap(
              NightjarAssetAcceptance([
                for (final m in sparse) NightjarAcceptedAsset(assetId: m.$2),
                NightjarAcceptedAsset(assetId: unindexed.assetId),
              ]),
            ),
          ),
          nightjarAcceptanceStoreProvider.overrideWithValue(
            _MemoryAcceptanceStore(),
          ),
          nightjarMetadataFetcherProvider.overrideWithValue(
            NightjarAssetMetadataFetcher(transport: fake),
          ),
          nightjarViewLoaderProvider.overrideWithValue(
            () async => NightjarViewData(
              status: NightjarViewStatus.ready,
              assets: [...members, unindexed],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(nightjarAssetsViewProvider.future);

      final outcome = await container.read(
        nightjarAssetArtworkFetchProvider(unindexed.assetId).future,
      );
      expect(outcome!.hasImage, isFalse);
      expect(outcome.reason, NightjarMetadataAbandonReason.documentRefused);
      // It asked for the document — it is accepted — and for no image.
      expect(
        fake.requested.where((u) => u.toString() != _documentUri),
        isEmpty,
      );
    });
  });

  group('verified and unpinned are visibly different', () {
    testWidgets('four published digests: four verified, six unpinned, ten '
        'pictures', (tester) async {
      // Section 3.3's SHOULD, against the publisher's own array truncated.
      // Every tile still draws — unpinned is not invalid — and exactly the
      // pieces past the end of `digests` carry the badge.
      await _pump(
        tester,
        members: _members,
        transport: _transport(document: _documentWithDigests(4)),
      );

      expect(_tilePicturesDrawn(tester), 10);
      expect(_unpinnedBadges(tester), 6);
      for (final (index, assetId) in _members) {
        expect(
          _hasUnpinnedBadge(tester, assetId),
          index >= 4,
          reason: 'piece $index',
        );
        // The picture is the right picture either way: the pin is about who
        // can change it, never about which one it is.
        expect(_drawnBytes(tester, assetId), _imageBytes(index));
      }
    });

    testWidgets('a host serving piece 9 as piece 4 is refused, not drawn', (
      tester,
    ) async {
      // The attack `digests` exists for, built from real pieces: a perfectly
      // valid published PNG served at the wrong URL. Sniffing cannot catch it
      // — both are genuine 512×512 PNGs from the same publisher — so only the
      // digest can, and the tile must say refused rather than drawing it.
      final swapped = FakeNightjarTransport({
        Uri.parse(_documentUri): NightjarHttpReply(
          statusCode: 200,
          body: _documentBytes(),
        ),
        for (var i = 0; i < 10; i++)
          _imageUri(i): NightjarHttpReply(
            statusCode: 200,
            body: _imageBytes(i == 4 ? 9 : i),
          ),
      });
      await _pump(tester, members: _members, transport: swapped);

      expect(_tilePicturesDrawn(tester), 9);
      expect(_tilesSaying(tester, kNightjarArtworkRefusedTileText), 1);
      expect(_drawnBytes(tester, _members[4].$2), isNull);
      for (final (index, assetId) in _members) {
        if (index == 4) continue;
        expect(_drawnBytes(tester, assetId), _imageBytes(index));
      }
    });
  });
}
