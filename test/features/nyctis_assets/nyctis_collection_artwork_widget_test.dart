/// The rendered half of `spec/asset-collection-v0.md`: a grid of members
/// pointing at one shared collection document, and the five states a tile can
/// be in.
///
/// The end-to-end group is the one that matters. It serves the same shape of
/// document the devnet's `pon/c.json` is — `{index}` template, `digests`,
/// `max_supply` — over a fake transport, hands the members their **on-chain**
/// indices, and asserts that every tile draws its own piece. Before the
/// collection implementation existed, every one of those tiles said "Not
/// fetched", and nothing on screen distinguished that from a refusal.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_asset_acceptance_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_collection_artwork_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_collections_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_metadata_fetcher_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/nyctis_collection_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_digest.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_transport.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_artwork_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_logo.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_assets_feed.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_collection_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_collection_grid.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_collection_mapper.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_facts_card.dart';

import 'support/nyctis_metadata_fixtures.dart';

/// The value a facts card on screen carries under [label], or null.
String? _factValue(WidgetTester tester, String label) {
  for (final card in tester.widgetList<NyctisFactsCard>(
    find.byType(NyctisFactsCard),
  )) {
    for (final fact in card.facts) {
      if (fact.label == label) return fact.value;
    }
  }
  return null;
}

const _collectionId =
    'f48d439c3b9406edecd728efec22fd5c51475de252dc22b3bfec72daafb87500';
final _documentUri = Uri.parse('https://example.invalid/pon/c.json');

/// Ten pieces, which is what the devnet carries.
const int _memberCount = 10;

String _pieceId(int i) => 'pon${i.toString().padLeft(61, '0')}';

Uri _imageUri(int index) => Uri.parse('https://example.invalid/pon/$index.png');

/// The collection's own picture (`spec/asset-collection-v0.md` section 3.5).
/// A separate URL from every member's, and one that carries no index.
final _logoUri = Uri.parse('https://example.invalid/pon/logo.png');

/// One member, with the **on-chain** `index` the wallet read from the channel.
///
/// The index is the whole reason a shared document is safe
/// (`asset-collection-v0.md` section 1), so the fixture carries it explicitly
/// rather than letting a position in a list stand in for it.
NyctisAssetDetailData _piece(
  int i, {
  bool owned = false,
  int? collectionMaxSupply,
}) => NyctisAssetDetailData(
  assetId: _pieceId(i),
  name: 'Phases of one night #$i',
  symbol: 'PON',
  collection: _collectionId,
  index: i,
  // The cap bound into `collection_id` (`transition-v0.md` section 5).
  // Null is what the replay supplies today, so most of this suite runs
  // uncapped; the tests that pass one are the ones about the copy the cap
  // buys.
  collectionMaxSupply: collectionMaxSupply,
  isPublic: true,
  balance: owned ? BigInt.one : BigInt.zero,
  decimals: 0,
  issuedSupply: BigInt.one,
  maxSupply: BigInt.one,
  metadataUri: _documentUri.toString(),
);

List<NyctisAssetDetailData> _pieces({int? collectionMaxSupply}) => [
  for (var i = 0; i < _memberCount; i++)
    _piece(i, owned: i < 3, collectionMaxSupply: collectionMaxSupply),
];

/// The collection document, shaped like `pon/c.json`.
///
/// [logo] is section 3.5's member, absent by default because that is the
/// ordinary case: nothing obliges a publisher to have one and every document
/// published before revision 3 has none.
Uint8List _documentBytes({
  int digestCount = _memberCount,
  Map<String, Object?>? logo,
}) {
  final digest = nyctisB2Digest(kOnePixelPng);
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'schema': 'nyctis-collection-metadata/1',
        'revision': 0,
        'name': 'Phases of One Night',
        'description': 'The frame never changes; the light does.',
        'logo': ?logo,
        'max_supply': 100,
        'item': {
          'name': 'Phases of One Night #{index}',
          'image': 'https://example.invalid/pon/{index}.png',
        },
        'digests': [for (var i = 0; i < digestCount; i++) digest],
        'website': 'https://example.invalid/',
      }),
    ),
  );
}

FakeNyctisTransport _transport({
  int digestCount = _memberCount,
  Uint8List? image,
  Map<String, Object?>? logo,
  Uint8List? logoBytes,
}) => FakeNyctisTransport({
  _documentUri: NyctisHttpReply(
    statusCode: 200,
    body: _documentBytes(digestCount: digestCount, logo: logo),
  ),
  for (var i = 0; i < _memberCount; i++)
    _imageUri(i): NyctisHttpReply(statusCode: 200, body: image ?? kOnePixelPng),
  if (logoBytes != null)
    _logoUri: NyctisHttpReply(statusCode: 200, body: logoBytes),
});

/// The declared `logo` object, pinned to whatever bytes the host will serve
/// unless [pinTo] says otherwise.
Map<String, Object?> _logoMember({Uint8List? pinTo}) => {
  'uri': _logoUri.toString(),
  if (pinTo != null) 'b2': nyctisB2Digest(pinTo),
  // Advisory and never trusted (section 3.5, via `asset-metadata-v0.md`
  // section 4.2). Present so the parser has something it must ignore.
  'mime': 'image/png',
  'width': 512,
  'height': 512,
};

/// The collection's face, wherever the header drew one.
final _collectionFace = find.byKey(kNyctisCollectionArtworkImageKey);

/// One piece's artwork. Distinct from [_collectionFace] on purpose: a count of
/// "how many pieces drew a picture" must not include the heading.
final _tilePictures = find.byKey(const ValueKey('nyctis_logo_image'));

/// The sentence the header puts under the collection's name.
String _provenance(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('nyctis_collection_provenance')))
    .data!;

class _MemoryAcceptanceStore implements NyctisAcceptanceStore {
  String? value;

  @override
  Future<void> write(String encoded) async => value = encoded;

  @override
  Future<void> clear() async => value = null;
}

AppBootstrapState _bootstrap(NyctisAssetAcceptance acceptance) =>
    AppBootstrapState(
      initialLocation: '/',
      initialAccountState: AppBootstrapState.empty.initialAccountState,
      initialSyncSnapshot: AppBootstrapState.empty.initialSyncSnapshot,
      network: AppBootstrapState.empty.network,
      rpcEndpointConfig: AppBootstrapState.empty.rpcEndpointConfig,
      nyctisAcceptedAssets: acceptance,
      themeMode: AppBootstrapState.empty.themeMode,
      privacyModeEnabled: false,
      isPasswordConfigured: false,
      isUnlocked: false,
      passwordRotationRecoveryFailed: false,
    );

NyctisAssetAcceptance _acceptAll() => NyctisAssetAcceptance([
  for (var i = 0; i < _memberCount; i++)
    NyctisAcceptedAsset(assetId: _pieceId(i)),
]);

Future<FakeNyctisTransport> _pumpCollection(
  WidgetTester tester, {
  required NyctisAssetAcceptance acceptance,
  FakeNyctisTransport? transport,
  int? collectionMaxSupply,
}) async {
  // Tall enough that all ten tiles are inside the viewport: this suite is
  // about what a tile draws, and the laziness of the grid has its own test.
  await tester.binding.setSurfaceSize(const Size(460, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final fake = transport ?? _transport();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appBootstrapProvider.overrideWithValue(_bootstrap(acceptance)),
        nyctisAcceptanceStoreProvider.overrideWithValue(
          _MemoryAcceptanceStore(),
        ),
        nyctisMetadataFetcherProvider.overrideWithValue(
          NyctisAssetMetadataFetcher(transport: fake),
        ),
        nyctisViewLoaderProvider.overrideWithValue(
          () async => NyctisViewData(
            status: NyctisViewStatus.ready,
            assets: _pieces(collectionMaxSupply: collectionMaxSupply),
          ),
        ),
      ],
      child: MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: Consumer(
            builder: (context, ref, _) => CustomScrollView(
              slivers: buildNyctisCollectionSlivers(
                collectionId: _collectionId,
                collection: ref.watch(nyctisCollectionProvider(_collectionId)),
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

void main() {
  group('a collection document fills the grid', () {
    testWidgets('ten accepted pieces draw ten pictures from one document', (
      tester,
    ) async {
      final fake = await _pumpCollection(tester, acceptance: _acceptAll());

      // The bug this feature fixes: every tile used to say "Not fetched"
      // because nothing implemented `asset-collection-v0.md` at all.
      expect(
        find.byKey(const ValueKey('nyctis_logo_image')),
        findsNWidgets(_memberCount),
      );
      expect(find.text(kNyctisArtworkNotAcceptedTileText), findsNothing);

      // Section 2: one document for the collection, whatever it holds.
      expect(fake.requested.where((uri) => uri == _documentUri).length, 1);
      // One image per piece, each at its own on-chain index.
      expect(fake.requested.where((uri) => uri != _documentUri).toSet(), {
        for (var i = 0; i < _memberCount; i++) _imageUri(i),
      });
    });

    testWidgets('and nothing is requested before the user accepts', (
      tester,
    ) async {
      final fake = await _pumpCollection(
        tester,
        acceptance: const NyctisAssetAcceptance.empty(),
      );

      // `asset-collection-v0.md` section 5: a wallet **MUST NOT** fetch a
      // collection document because it holds a member. Three of these ten are
      // held; none of them is a reason to talk to a host.
      expect(fake.requested, isEmpty);
      expect(find.byKey(const ValueKey('nyctis_logo_image')), findsNothing);
      expect(find.text(kNyctisArtworkNotAcceptedTileText), findsWidgets);
    });

    testWidgets('a pinned piece shows no unpinned badge', (tester) async {
      await _pumpCollection(tester, acceptance: _acceptAll());

      expect(
        find.byKey(const ValueKey('nyctis_artwork_unpinned_badge')),
        findsNothing,
      );
    });

    testWidgets('a short digests array marks exactly the unpinned tiles', (
      tester,
    ) async {
      // Section 3.3: "a missing or short `digests` array means those pieces
      // are **unpinned**, not invalid", and a wallet SHOULD say so. Four
      // digests for ten pieces: four verified, six unpinned, ten pictures.
      await _pumpCollection(
        tester,
        acceptance: _acceptAll(),
        transport: _transport(digestCount: 4),
      );

      expect(
        find.byKey(const ValueKey('nyctis_logo_image')),
        findsNWidgets(_memberCount),
      );
      expect(
        find.byKey(const ValueKey('nyctis_artwork_unpinned_badge')),
        findsNWidgets(_memberCount - 4),
      );
    });

    testWidgets('a digest mismatch says so rather than saying nothing', (
      tester,
    ) async {
      // Every image is a real PNG and none of them hashes to the digest the
      // document pinned. Section 3.3: discarded, without retrying. The tile
      // must not read as "not fetched" — describing a host serving something
      // the issuer never signed for as a slow network is the whole reason the
      // single empty state was wrong.
      await _pumpCollection(
        tester,
        acceptance: _acceptAll(),
        transport: FakeNyctisTransport({
          _documentUri: NyctisHttpReply(
            statusCode: 200,
            body: _documentBytes(),
          ),
          for (var i = 0; i < _memberCount; i++)
            _imageUri(i): NyctisHttpReply(statusCode: 200, body: kOtherPng),
        }),
      );

      expect(find.byKey(const ValueKey('nyctis_logo_image')), findsNothing);
      expect(
        find.text(kNyctisArtworkRefusedTileText),
        findsNWidgets(_memberCount),
      );
      expect(find.text(kNyctisArtworkNotAcceptedTileText), findsNothing);
    });
  });

  group('the request set is a fact about the collection, not the wallet', () {
    testWidgets('accepting one piece warms every piece, accepted or not', (
      tester,
    ) async {
      // The hole `spec/asset-collection-v0.md` section 2 misses: the document
      // is shared but the images are per-piece URLs, so fetching only the
      // accepted ones tells the host which pieces the user accepted — and a
      // user accepts what they hold. Warming all ten makes the set a function
      // of the channel.
      final fake = await _pumpCollection(
        tester,
        acceptance: NyctisAssetAcceptance([
          NyctisAcceptedAsset(assetId: _pieceId(4)),
        ]),
      );

      expect(fake.requested.where((uri) => uri == _documentUri).length, 1);
      expect(fake.requested.where((uri) => uri != _documentUri).toSet(), {
        for (var i = 0; i < _memberCount; i++) _imageUri(i),
      });
    });

    testWidgets('and still draws only the piece that was accepted', (
      tester,
    ) async {
      // `asset-metadata-v0.md` section 5 forbids *displaying* an unaccepted
      // logo, not fetching one. Nine warmed pictures stay in the cache and one
      // reaches the screen.
      await _pumpCollection(
        tester,
        acceptance: NyctisAssetAcceptance([
          NyctisAcceptedAsset(assetId: _pieceId(4)),
        ]),
      );

      expect(find.byKey(const ValueKey('nyctis_logo_image')), findsOneWidget);
      expect(
        find.text(kNyctisArtworkNotAcceptedTileText),
        findsNWidgets(_memberCount - 1),
      );
    });

    testWidgets('nothing is warmed while no member is accepted', (
      tester,
    ) async {
      final fake = await _pumpCollection(
        tester,
        acceptance: const NyctisAssetAcceptance.empty(),
      );
      expect(fake.requested, isEmpty);
    });

    test(
      'the warm-up stops at its byte cap and says it is incomplete',
      () async {
        // Twenty quarter-megabyte images is 5 MiB, past
        // [kNyctisCollectionWarmupMaxBytes]. Past the cap the tail falls back
        // to per-tile fetching, which is the residual leak the provider's header
        // names rather than hides.
        const members = 20;
        final fat = Uint8List(250 * 1024)
          ..setRange(0, kOnePixelPng.length, kOnePixelPng);
        final assets = [for (var i = 0; i < members; i++) _piece(i)];
        final fake = FakeNyctisTransport({
          _documentUri: NyctisHttpReply(
            statusCode: 200,
            body: _documentBytes(digestCount: 0),
          ),
          for (var i = 0; i < members; i++)
            _imageUri(i): NyctisHttpReply(statusCode: 200, body: fat),
        });

        final container = ProviderContainer(
          overrides: [
            appBootstrapProvider.overrideWithValue(
              _bootstrap(
                NyctisAssetAcceptance([
                  NyctisAcceptedAsset(assetId: _pieceId(0)),
                ]),
              ),
            ),
            nyctisAcceptanceStoreProvider.overrideWithValue(
              _MemoryAcceptanceStore(),
            ),
            nyctisMetadataFetcherProvider.overrideWithValue(
              NyctisAssetMetadataFetcher(transport: fake),
            ),
            nyctisViewLoaderProvider.overrideWithValue(
              () async => NyctisViewData(
                status: NyctisViewStatus.ready,
                assets: assets,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(nyctisAssetsViewProvider.future);

        final warmup = await container.read(
          nyctisCollectionArtworkWarmupProvider(_collectionId).future,
        );

        expect(warmup.complete, isFalse);
        expect(warmup.requested, lessThan(members));
        expect(
          warmup.bytes,
          greaterThanOrEqualTo(kNyctisCollectionWarmupMaxBytes),
        );
      },
    );

    /// Builds a container over [assets] served by [fake], with member 0
    /// accepted — the gate the warm-up runs behind.
    Future<NyctisCollectionWarmup> warm(
      List<NyctisAssetDetailData> assets,
      FakeNyctisTransport fake,
    ) async {
      final container = ProviderContainer(
        overrides: [
          appBootstrapProvider.overrideWithValue(
            _bootstrap(
              NyctisAssetAcceptance([
                NyctisAcceptedAsset(assetId: _pieceId(0)),
              ]),
            ),
          ),
          nyctisAcceptanceStoreProvider.overrideWithValue(
            _MemoryAcceptanceStore(),
          ),
          nyctisMetadataFetcherProvider.overrideWithValue(
            NyctisAssetMetadataFetcher(transport: fake),
          ),
          nyctisViewLoaderProvider.overrideWithValue(
            () async =>
                NyctisViewData(status: NyctisViewStatus.ready, assets: assets),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(nyctisAssetsViewProvider.future);
      return container.read(
        nyctisCollectionArtworkWarmupProvider(_collectionId).future,
      );
    }

    test('a collection that grew is warmed across all its documents', () async {
      // Section 6 T3: members minted after the first table sign a *new*
      // document uri; the earlier ones keep theirs. The wallet finds the set
      // on-chain — which here is just the view — and must warm every member
      // through the document that member actually signed, not through the
      // first one it saw.
      final second = Uri.parse('https://example.invalid/pon/c2.json');
      final assets = [
        for (var i = 0; i < 4; i++) _piece(i),
        for (var i = 4; i < 8; i++)
          NyctisAssetDetailData(
            assetId: _pieceId(i),
            name: 'Phases of one night #$i',
            symbol: 'PON',
            collection: _collectionId,
            index: i,
            isPublic: true,
            balance: BigInt.zero,
            decimals: 0,
            issuedSupply: BigInt.one,
            maxSupply: BigInt.one,
            metadataUri: second.toString(),
          ),
      ];
      final fake = FakeNyctisTransport({
        _documentUri: NyctisHttpReply(
          statusCode: 200,
          body: _documentBytes(digestCount: 0),
        ),
        second: NyctisHttpReply(
          statusCode: 200,
          body: _documentBytes(digestCount: 0),
        ),
        for (var i = 0; i < 8; i++)
          _imageUri(i): NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
      });

      final warmup = await warm(assets, fake);

      expect(warmup.documents, 2, reason: 'a grown collection has two');
      expect(warmup.documentsExceeded, isFalse);
      expect(warmup.requested, 8, reason: 'every member, through its own uri');
      expect(warmup.complete, isTrue);
      // Two documents between eight members, not eight.
      expect(fake.requested.where((u) => u == _documentUri).length, 1);
      expect(fake.requested.where((u) => u == second).length, 1);
    });

    test('stops at the document bound and says which cap it hit', () async {
      // Section 6 T3b: a publisher who names every member with a document of
      // its own is section 4's per-piece form wearing section 3's clothes, and
      // a wallet that followed it would make one request per piece — the
      // disclosure the shared form exists to remove.
      final members = kNyctisCollectionMaxDocuments + 10;
      Uri docFor(int i) => Uri.parse('https://example.invalid/pon/c$i.json');
      final assets = [
        for (var i = 0; i < members; i++)
          NyctisAssetDetailData(
            assetId: _pieceId(i),
            name: 'Phases of one night #$i',
            symbol: 'PON',
            collection: _collectionId,
            index: i,
            isPublic: true,
            balance: BigInt.zero,
            decimals: 0,
            issuedSupply: BigInt.one,
            maxSupply: BigInt.one,
            metadataUri: docFor(i).toString(),
          ),
      ];
      final fake = FakeNyctisTransport({
        for (var i = 0; i < members; i++)
          docFor(i): NyctisHttpReply(
            statusCode: 200,
            body: _documentBytes(digestCount: 0),
          ),
        for (var i = 0; i < members; i++)
          _imageUri(i): NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
      });

      final warmup = await warm(assets, fake);

      expect(warmup.documents, kNyctisCollectionMaxDocuments);
      expect(warmup.documentsExceeded, isTrue);
      // It is a partial collection, not an error — the tail still renders,
      // it just was not warmed.
      expect(warmup.complete, isFalse);
      expect(warmup.requested, kNyctisCollectionMaxDocuments);
      expect(
        fake.requested.where((u) => u.path.endsWith('.json')).length,
        kNyctisCollectionMaxDocuments,
        reason: 'the bound is on requests, not only on the reported number',
      );
    });

    test('the bound is on documents, not on members', () async {
      // Once a document is in hand every further member of it is free, which
      // is the whole point of the shared form. A thousand members of one
      // document must not trip a bound counted in documents.
      const members = 200;
      final assets = [for (var i = 0; i < members; i++) _piece(i)];
      final fake = FakeNyctisTransport({
        _documentUri: NyctisHttpReply(
          statusCode: 200,
          body: _documentBytes(digestCount: 0),
        ),
        for (var i = 0; i < members; i++)
          _imageUri(i): NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
      });

      final warmup = await warm(assets, fake);

      expect(warmup.documents, 1);
      expect(warmup.documentsExceeded, isFalse);
      expect(warmup.requested, members);
      expect(warmup.complete, isTrue);
    });

    test('refused images are charged, so one acceptance cannot pull '
        'unbounded traffic', () async {
      // C4 scenario 2: every image is served one byte over the 256 KiB limit.
      // Each is refused as tooLarge, and a budget that counted only kept
      // bytes would warm all ten thousand members — 2.5 GB, thrown away,
      // because the user accepted one piece.
      const members = 10000;
      final overLimit = Uint8List(kNyctisLogoMaxBytes + 1)
        ..setRange(0, kOnePixelPng.length, kOnePixelPng);
      final assets = [for (var i = 0; i < members; i++) _piece(i)];
      final fake = FakeNyctisTransport({
        _documentUri: NyctisHttpReply(
          statusCode: 200,
          body: _documentBytes(digestCount: 0),
        ),
        for (var i = 0; i < members; i++)
          _imageUri(i): NyctisHttpReply(statusCode: 200, body: overLimit),
      });

      final warmup = await warm(assets, fake);

      expect(warmup.complete, isFalse);
      // Four MiB of refusals at a quarter mebibyte each, give or take one.
      expect(
        warmup.requested,
        lessThanOrEqualTo(
          kNyctisCollectionWarmupMaxBytes ~/ kNyctisLogoMaxBytes + 1,
        ),
      );
      expect(
        warmup.bytes,
        greaterThanOrEqualTo(kNyctisCollectionWarmupMaxBytes),
      );
      expect(
        fake.requested.where((u) => u.path.endsWith('.png')).length,
        warmup.requested,
      );
      // And each image request was told the cap it had to stream against.
      expect(
        fake.maxBytes.skip(1),
        everyElement(lessThanOrEqualTo(kNyctisLogoMaxBytes)),
      );
    });

    test('a host that refuses cheaply is stopped by the request cap', () async {
      // The other half of scenario 2: an empty 404 costs no bytes, so only a
      // bound on requests stops the walk.
      const members = kNyctisCollectionWarmupMaxRequests + 500;
      final assets = [for (var i = 0; i < members; i++) _piece(i)];
      final fake = FakeNyctisTransport({
        _documentUri: NyctisHttpReply(
          statusCode: 200,
          body: _documentBytes(digestCount: 0),
        ),
        // No images at all: every one answers 404 with an empty body.
      });

      final warmup = await warm(assets, fake);

      expect(warmup.complete, isFalse);
      expect(warmup.requests, kNyctisCollectionWarmupMaxRequests);
      expect(fake.requested.length, kNyctisCollectionWarmupMaxRequests);
    });
  });

  group('the collection has a face of its own (section 3.5)', () {
    testWidgets('a declared logo is drawn, pinned, and is not a tile', (
      tester,
    ) async {
      final fake = await _pumpCollection(
        tester,
        acceptance: _acceptAll(),
        transport: _transport(
          logo: _logoMember(pinTo: kOtherPng),
          logoBytes: kOtherPng,
        ),
      );

      // The gap this closes: the collection row and screen had a name, a
      // count and an id and nothing to look at, while every piece under them
      // had artwork.
      expect(_collectionFace, findsOneWidget);
      // And it is the collection's picture, not a member's: ten tiles still
      // draw ten pieces and the face is an eleventh image with its own key.
      expect(_tilePictures, findsNWidgets(_memberCount));

      // One request, and its URL carries no index — section 3.5: it discloses
      // interest in the collection and nothing about which member.
      expect(fake.requested.where((uri) => uri == _logoUri).length, 1);

      final text = _provenance(tester);
      expect(text, startsWith('Collection artwork from'));
      expect(text, contains('digest'));
      // Declared, so nothing may call it derived.
      expect(text, isNot(contains('piece #')));
    });

    testWidgets('an unpinned logo is drawn and says nothing pins it', (
      tester,
    ) async {
      // Section 3.5: a `logo` without a `b2` is **unpinned, not invalid**, on
      // the same terms as a piece with no `digests` entry — and a wallet
      // SHOULD say so where it says where the picture came from.
      await _pumpCollection(
        tester,
        acceptance: _acceptAll(),
        transport: _transport(logo: _logoMember(), logoBytes: kOtherPng),
      );

      expect(_collectionFace, findsOneWidget);
      expect(_provenance(tester), contains('nothing pins these bytes'));
    });

    testWidgets('a logo whose b2 does not match is discarded, and said so', (
      tester,
    ) async {
      // A genuinely valid PNG that is not the PNG the issuer pinned: the shape
      // of the attack section 3.3 and `asset-metadata-v0.md` section 2.1
      // exist for. Discarded without retrying, and the fallback must not
      // report it as the publisher having shipped nothing.
      await _pumpCollection(
        tester,
        acceptance: _acceptAll(),
        transport: _transport(
          logo: _logoMember(pinTo: kOnePixelPng),
          logoBytes: kOtherPng,
        ),
      );

      final text = _provenance(tester);
      expect(text, contains('would not keep it'));
      expect(text, contains('piece #0'));
      expect(text, isNot(contains('published no artwork')));
      // The face that is drawn is the fallback's, so there is still exactly
      // one of it and it is still not one of the ten tiles.
      expect(_collectionFace, findsOneWidget);
      expect(_tilePictures, findsNWidgets(_memberCount));
    });

    testWidgets('no logo falls back to member 0 and marks it derived', (
      tester,
    ) async {
      // Section 3.5.1. Nothing is published yet, so this is the ordinary case
      // rather than an edge one, and a collection that shows nothing until
      // somebody republishes a document is a wallet failing at something it
      // has the bytes in hand to do.
      final fake = await _pumpCollection(tester, acceptance: _acceptAll());

      expect(_collectionFace, findsOneWidget);
      final text = _provenance(tester);
      expect(text, contains('published no artwork of its own'));
      expect(text, contains('piece #0'));

      // It costs no request: section 2.1's warm-up already fetched every
      // member, so the face is bytes the wallet held.
      expect(fake.requested.contains(_logoUri), isFalse);
      expect(fake.requested.where((uri) => uri != _documentUri).toSet(), {
        for (var i = 0; i < _memberCount; i++) _imageUri(i),
      });
    });

    testWidgets('the derived face is the lowest *accepted* member, not 0', (
      tester,
    ) async {
      // The part of section 3.5.1 that is easy to get wrong. The user has
      // accepted piece 4 and not piece 0; piece 0's bytes are in the cache,
      // because section 2.1 says to fetch every member. Drawing them anyway
      // would display a logo for an `asset_id` the user never accepted, which
      // section 5 of `asset-metadata-v0.md` forbids — and the tempting excuse,
      // that accepting any member is a judgement about the one issuer key
      // `collection_id` is derived from, is exactly the excuse that section
      // refuses.
      await _pumpCollection(
        tester,
        acceptance: NyctisAssetAcceptance([
          NyctisAcceptedAsset(assetId: _pieceId(4)),
        ]),
      );

      final text = _provenance(tester);
      expect(text, contains('piece #4'));
      expect(text, isNot(contains('piece #0')));
      // One tile drawn, the other nine still empty (section 5 again), and the
      // face is the eleventh picture rather than a tenth tile.
      expect(_tilePictures, findsOneWidget);
      expect(_collectionFace, findsOneWidget);
    });

    testWidgets('no logo and nothing accepted draws the empty frame', (
      tester,
    ) async {
      // Not a broken image and not a hidden heading. Section 3.5: a wallet
      // **MUST NOT** fetch or display a collection's picture before the user
      // has accepted a member, so this is the answer rather than a loading
      // state.
      final fake = await _pumpCollection(
        tester,
        acceptance: const NyctisAssetAcceptance.empty(),
      );

      expect(_collectionFace, findsNothing);
      expect(_tilePictures, findsNothing);
      // The frame is still there — a collection with nothing accepted is not
      // a collection with nothing in it.
      expect(
        find.byKey(const ValueKey('nyctis_collection_artwork')),
        findsOneWidget,
      );
      // And nothing was said about where a picture came from, because there
      // is none.
      expect(
        find.byKey(const ValueKey('nyctis_collection_provenance')),
        findsNothing,
      );
      expect(fake.requested, isEmpty);
    });

    testWidgets('the collection id is beside the name, always', (tester) async {
      // Section 5, and it is not optional: two collections may share a `name`
      // and now a picture, and only one can share an id.
      await _pumpCollection(tester, acceptance: _acceptAll());
      expect(
        find.byKey(const ValueKey('nyctis_collection_header_id')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('nyctis_collection_header_id')),
            )
            .data,
        truncateNyctisAssetId(_collectionId),
      );
    });

    testWidgets('a collection row draws the face and marks it derived', (
      tester,
    ) async {
      // The list row is the other surface, and it says nothing about origins
      // or digests — so the marking there is a badge, on the same argument as
      // the unpinned one: a distinction the user cannot see is not a
      // distinction.
      await tester.binding.setSurfaceSize(const Size(420, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: AppTheme(
            data: AppThemeData.dark,
            child: Center(
              child: SizedBox(
                width: 396,
                child: NyctisCollectionRow(
                  row: NyctisCollectionRowData(
                    collectionId: _collectionId,
                    title: 'Phases of one night',
                    subtitle: truncateNyctisAssetId(_collectionId),
                    countText: '10 pieces · you hold 3',
                    ownedText: '3',
                    ownedLabel: 'held',
                    artwork: NyctisCollectionArtworkData(
                      artwork: NyctisArtworkData(
                        status: NyctisArtworkStatus.unpinned,
                        bytes: kOnePixelPng,
                        sourceOrigin: 'example.invalid',
                      ),
                      source: NyctisCollectionArtworkSource.derived,
                      derivedFromIndex: 0,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(_collectionFace, findsOneWidget);
      expect(
        find.byKey(const ValueKey('nyctis_collection_derived_badge')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('nyctis_collection_unpinned_badge')),
        findsOneWidget,
      );
      // Section 5 on the row too.
      expect(
        find.textContaining(truncateNyctisAssetId(_collectionId)),
        findsOneWidget,
      );
    });

    testWidgets('and a row with nothing accepted keeps its icon', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: AppTheme(
            data: AppThemeData.dark,
            child: Center(
              child: SizedBox(
                width: 396,
                child: NyctisCollectionRow(
                  row: NyctisCollectionRowData(
                    collectionId: _collectionId,
                    title: 'Phases of one night',
                    subtitle: truncateNyctisAssetId(_collectionId),
                    countText: '10 pieces · none held',
                    ownedText: '0',
                    ownedLabel: 'held',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(_collectionFace, findsNothing);
      expect(
        find.byKey(const ValueKey('nyctis_collection_derived_badge')),
        findsNothing,
      );
    });
  });

  group('the five tile states are five different tiles', () {
    Future<void> pumpTile(
      WidgetTester tester,
      NyctisArtworkData artwork,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: AppTheme(
            data: AppThemeData.dark,
            child: Center(
              child: SizedBox(
                width: 150,
                height: 220,
                child: NyctisCollectionTile(
                  member: _piece(7),
                  artwork: artwork,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('not accepted', (tester) async {
      await pumpTile(tester, const NyctisArtworkData.notAccepted());
      expect(find.text(kNyctisArtworkNotAcceptedTileText), findsOneWidget);
      expect(find.byKey(const ValueKey('nyctis_logo_image')), findsNothing);
    });

    testWidgets('pending', (tester) async {
      await pumpTile(tester, const NyctisArtworkData.pending());
      expect(find.text(kNyctisArtworkPendingTileText), findsOneWidget);
    });

    testWidgets('verified', (tester) async {
      await pumpTile(
        tester,
        NyctisArtworkData(
          status: NyctisArtworkStatus.verified,
          bytes: kOnePixelPng,
          sourceOrigin: 'example.invalid',
          documentPinned: true,
        ),
      );
      expect(find.byKey(const ValueKey('nyctis_logo_image')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nyctis_artwork_unpinned_badge')),
        findsNothing,
      );
    });

    testWidgets('unpinned draws the picture and says it is unpinned', (
      tester,
    ) async {
      await pumpTile(
        tester,
        NyctisArtworkData(
          status: NyctisArtworkStatus.unpinned,
          bytes: kOnePixelPng,
          sourceOrigin: 'example.invalid',
        ),
      );
      expect(find.byKey(const ValueKey('nyctis_logo_image')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nyctis_artwork_unpinned_badge')),
        findsOneWidget,
      );
    });

    testWidgets('refused', (tester) async {
      await pumpTile(
        tester,
        const NyctisArtworkData(
          status: NyctisArtworkStatus.refused,
          reason: NyctisMetadataAbandonReason.digestMismatch,
          sourceOrigin: 'example.invalid',
        ),
      );
      expect(find.text(kNyctisArtworkRefusedTileText), findsOneWidget);
      expect(find.byKey(const ValueKey('nyctis_logo_image')), findsNothing);
    });

    test('and their copy is all distinct', () {
      // The regression this guards is the original bug's shape: three states
      // sharing one string. A future edit that collapses two of them again
      // fails here rather than on a screenshot nobody takes.
      final texts = [
        for (final status in NyctisArtworkStatus.values)
          nyctisArtworkTileText(status),
      ].whereType<String>().toList();
      expect(texts.toSet().length, texts.length);
      expect(texts.length, 3);
    });
  });

  group('the document cap against the cap in the collection id', () {
    /// The footnote the facts card is carrying, whichever of the two it is.
    String footnote(WidgetTester tester) {
      final card = find.byKey(const ValueKey('nyctis_collection_facts'));
      return tester
          .widgetList<Text>(
            find.descendant(of: card, matching: find.byType(Text)),
          )
          .last
          .data!;
    }

    final disagreement = find.byKey(
      const ValueKey('nyctis_collection_cap_disagreement'),
    );

    testWidgets('an uncapped collection keeps the old footnote and says '
        'nothing about a cap', (tester) async {
      await _pumpCollection(tester, acceptance: _acceptAll());

      expect(footnote(tester), kNyctisCollectionCountNote);
      expect(disagreement, findsNothing);
      // Since transition-v0 revision 11 every collection id binds a cap and a
      // zero one is the collection saying it has none, so the cap row is always
      // listed — and for this collection it states "Uncapped", never a number.
      expect(_factValue(tester, kNyctisCollectionCapLabel), 'Uncapped');
      expect(find.text('Uncapped'), findsOneWidget);
      expect(find.textContaining('At most'), findsNothing);
      expect(find.textContaining('of at most'), findsNothing);
    });

    testWidgets('a capped collection counts against the cap', (tester) async {
      await _pumpCollection(
        tester,
        acceptance: _acceptAll(),
        collectionMaxSupply: 100,
      );

      expect(footnote(tester), kNyctisCappedCollectionCountNote);
      expect(find.text('10 of at most 100 · you hold 3'), findsOneWidget);
      expect(find.text('At most 100'), findsOneWidget);
      // The document says 100 and so does the chain, so there is nothing to
      // report — the comparison is silent when it agrees.
      expect(disagreement, findsNothing);
    });

    testWidgets('the wallet says so when the document and the chain disagree', (
      tester,
    ) async {
      // The document serves `max_supply: 100`; the cap hashed into
      // `collection_id` is 9,000. Section 3.1 makes comparing a MUST and
      // saying so a SHOULD, and a silent comparison would leave the user
      // reading a number the wallet already knows is wrong.
      await _pumpCollection(
        tester,
        acceptance: _acceptAll(),
        collectionMaxSupply: 9000,
      );

      expect(disagreement, findsOneWidget);
      final text = tester.widget<Text>(disagreement).data!;
      expect(text, contains('100'));
      expect(text, contains('9,000'));
      expect(text, contains('collection id'));

      // And the count still comes off the chain's number, not the document's.
      expect(find.text('10 of at most 9,000 · you hold 3'), findsOneWidget);
    });

    testWidgets('a member numbered past the cap still draws its own piece', (
      tester,
    ) async {
      // `asset-collection-v0.md` section 3.1: a wallet **MUST NOT** treat a
      // member whose index is at or above the cap as invalid. Every one of the
      // ten members here is at or above a cap of two, and all ten render.
      await _pumpCollection(
        tester,
        acceptance: _acceptAll(),
        collectionMaxSupply: 2,
      );

      expect(_tilePictures, findsNWidgets(_memberCount));
      expect(find.text(kNyctisArtworkNotAcceptedTileText), findsNothing);
      expect(find.text('10 of at most 2 · you hold 3'), findsOneWidget);
    });
  });

  group('provenance says where it came from and what pins it', () {
    test('a verified image names the digest', () {
      final text = nyctisArtworkProvenanceText(
        NyctisArtworkData(
          status: NyctisArtworkStatus.verified,
          bytes: kOnePixelPng,
          sourceOrigin: 'raw.githubusercontent.com',
        ),
      );
      expect(text, contains('raw.githubusercontent.com'));
      expect(text, contains('digest'));
    });

    test('an unpinned image says who can change it', () {
      final text = nyctisArtworkProvenanceText(
        NyctisArtworkData(
          status: NyctisArtworkStatus.unpinned,
          bytes: kOnePixelPng,
          sourceOrigin: 'raw.githubusercontent.com',
        ),
      );
      // Section 3.3's "SHOULD say so": the two sentences must not be the same
      // sentence, and the unpinned one must say what unpinned costs.
      expect(text, contains('Nothing pins these bytes'));
    });

    test('a state with no picture has nothing to say about its origin', () {
      expect(
        nyctisArtworkProvenanceText(const NyctisArtworkData.pending()),
        isNull,
      );
      expect(
        nyctisArtworkDocumentPinText(const NyctisArtworkData.notAccepted()),
        isNull,
      );
    });
  });
}
