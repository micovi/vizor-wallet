/// The rendered half of collections: what a grid builds, what it fetches, and
/// what an unaccepted piece shows.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_asset_acceptance_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_collections_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_metadata_fetcher_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/nightjar_collection_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_transport.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_artwork_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_logo.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_collection_grid.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_collection_mapper.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_collection_sections.dart';

import 'support/nightjar_metadata_fixtures.dart';

const _collectionId =
    'c0113c7104900000000000000000000000000000000000000000000000000000';
final _documentUri = Uri.parse('https://example.invalid/pon.json');
final _logoUri = Uri.parse('https://example.invalid/pon.png');

String _pieceId(int i) => 'pon${i.toString().padLeft(61, '0')}';

NightjarAssetDetailData _piece(int i, {bool owned = false}) =>
    NightjarAssetDetailData(
      assetId: _pieceId(i),
      name: 'Phases of one night #$i',
      symbol: 'PON',
      collection: _collectionId,
      isPublic: true,
      balance: owned ? BigInt.one : BigInt.zero,
      decimals: 0,
      issuedSupply: BigInt.one,
      maxSupply: BigInt.one,
      metadataUri: _documentUri.toString(),
    );

List<NightjarAssetDetailData> _pieces(int count) => [
  for (var i = 0; i < count; i++) _piece(i, owned: i < 3),
];

Uint8List _documentBytes() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'schema': 'nightjar-asset-metadata/1',
      'description': 'One night, in a hundred phases.',
      'logo': {'uri': _logoUri.toString()},
    }),
  ),
);

/// Records every request, so a test can assert on the ones not made.
FakeNightjarTransport _transport() => FakeNightjarTransport({
  _documentUri: NightjarHttpReply(statusCode: 200, body: _documentBytes()),
  _logoUri: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
});

class _MemoryAcceptanceStore implements NightjarAcceptanceStore {
  String? value;
  var writes = 0;
  var clears = 0;

  @override
  Future<void> write(String encoded) async {
    writes++;
    value = encoded;
  }

  @override
  Future<void> clear() async {
    clears++;
    value = null;
  }
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

Future<({FakeNightjarTransport transport, _MemoryAcceptanceStore store})>
_pumpCollection(
  WidgetTester tester, {
  int memberCount = 100,
  NightjarAssetAcceptance acceptance = const NightjarAssetAcceptance.empty(),
  Size surface = const Size(460, 1600),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final transport = _transport();
  final store = _MemoryAcceptanceStore();
  final members = _pieces(memberCount);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appBootstrapProvider.overrideWithValue(_bootstrap(acceptance)),
        nightjarAcceptanceStoreProvider.overrideWithValue(store),
        nightjarMetadataFetcherProvider.overrideWithValue(
          NightjarAssetMetadataFetcher(transport: transport),
        ),
        nightjarViewLoaderProvider.overrideWithValue(
          () async => NightjarViewData(
            status: NightjarViewStatus.ready,
            assets: members,
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
  return (transport: transport, store: store);
}

void main() {
  group('the grid is lazy', () {
    testWidgets('a hundred-piece collection does not build a hundred tiles', (
      tester,
    ) async {
      await _pumpCollection(tester);

      final built = tester
          .widgetList(find.byType(NightjarCollectionTile))
          .length;

      // The assertion is "bounded by the viewport, not by the collection".
      // The exact number moves with tile geometry and with the cache extent,
      // so the bound is deliberately loose; the contrast with 100 is what is
      // being pinned. Before this change the same screen built all of them.
      expect(built, greaterThan(0));
      expect(built, lessThan(50));
    });

    testWidgets('and decodes no images at all while nothing is accepted', (
      tester,
    ) async {
      await _pumpCollection(tester);

      // Not one `Image.memory`: every tile draws the empty frame.
      expect(find.byKey(const ValueKey('nightjar_logo_image')), findsNothing);
      expect(find.text(kNightjarArtworkNotAcceptedTileText), findsWidgets);
    });

    testWidgets('an accepted hundred still decodes only what is on screen', (
      tester,
    ) async {
      final harness = await _pumpCollection(
        tester,
        acceptance: NightjarAssetAcceptance([
          for (var i = 0; i < 100; i++)
            NightjarAcceptedAsset(assetId: _pieceId(i)),
        ]),
      );
      await tester.pumpAndSettle();

      final images = find.byKey(const ValueKey('nightjar_logo_image'));
      final decoded = tester.widgetList(images).length;

      expect(decoded, greaterThan(0));
      expect(decoded, lessThan(50));

      // The decode stays bounded by the viewport; the *fetch* deliberately is
      // not, and this assertion used to say the opposite. Bounding the fetch
      // by what was on screen made the set of images the host saw equal to the
      // set of pieces the user looked at, which is the holdings disclosure
      // `spec/asset-collection-v0.md` section 5 exists to prevent — see
      // `nightjar_collection_artwork_provider.dart`. Bytes are not bitmaps:
      // warming a hundred images costs a few hundred KiB of cache and still
      // decodes a dozen pictures.
      final documentRequests = harness.transport.requested
          .where((uri) => uri == _documentUri)
          .length;
      // Section 2: one document for the whole collection, whatever it holds.
      expect(documentRequests, 1);
      // Every member's artwork, so the request set is a fact about the
      // collection rather than about the wallet.
      expect(harness.transport.requested.length, 101);
    });
  });

  group('acceptance', () {
    testWidgets('an unaccepted piece shows no artwork and fetches nothing', (
      tester,
    ) async {
      final harness = await _pumpCollection(tester, memberCount: 4);

      expect(find.byKey(const ValueKey('nightjar_logo_image')), findsNothing);
      expect(harness.transport.requested, isEmpty);
    });

    testWidgets('the card says what one press grants before it is pressed', (
      tester,
    ) async {
      await _pumpCollection(tester, memberCount: 4);

      expect(
        find.byKey(const ValueKey('nightjar_collection_explainer')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('nightjar_collection_per_asset')),
        findsOneWidget,
      );
      expect(find.text('Accept 4 pieces'), findsOneWidget);
    });

    testWidgets('accepting a collection writes once and per asset', (
      tester,
    ) async {
      final harness = await _pumpCollection(tester, memberCount: 100);

      await tester.tap(
        find.byKey(const ValueKey('nightjar_collection_accept_button')),
      );
      await tester.pumpAndSettle();

      // One keychain write for a hundred pieces, not a hundred.
      expect(harness.store.writes, 1);

      // And a hundred per-`asset_id` records underneath it, which is what
      // section 5 requires and what makes forgetting one piece possible.
      final stored = jsonDecode(harness.store.value!) as List;
      expect(stored, hasLength(100));
      expect((stored.first as Map)['id'], anyOf(_pieceId(0), isA<String>()));

      // The picture appears for the pieces on screen and the copy flips.
      expect(
        find.byKey(const ValueKey('nightjar_collection_accept_button')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('nightjar_collection_forget_button')),
        findsOneWidget,
      );
    });

    testWidgets('forgetting a collection clears every piece in one write', (
      tester,
    ) async {
      final harness = await _pumpCollection(
        tester,
        memberCount: 4,
        acceptance: NightjarAssetAcceptance([
          for (var i = 0; i < 4; i++)
            NightjarAcceptedAsset(assetId: _pieceId(i)),
        ]),
      );

      await tester.tap(
        find.byKey(const ValueKey('nightjar_collection_forget_button')),
      );
      await tester.pumpAndSettle();

      expect(harness.store.clears, 1);
      expect(harness.store.writes, 0);
      expect(find.byKey(const ValueKey('nightjar_logo_image')), findsNothing);
    });
  });

  group('the collection screen itself', () {
    testWidgets('names the collection by id and counts what it has read', (
      tester,
    ) async {
      await _pumpCollection(tester, memberCount: 100);

      expect(find.text(truncateNightjarAssetId(_collectionId)), findsWidgets);
      expect(find.text('100'), findsWidgets);
      expect(find.text(kNightjarCollectionCountNote), findsOneWidget);
    });

    testWidgets('an unknown collection says so rather than showing nothing', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: AppTheme(
              data: AppThemeData.dark,
              child: CustomScrollView(
                slivers: buildNightjarCollectionSlivers(
                  collectionId: _collectionId,
                  collection: null,
                  onMemberTap: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('nightjar_collection_missing')),
        findsOneWidget,
      );
    });
  });

  group('a piece on its own screen', () {
    Future<FakeNightjarTransport> pumpPiece(
      WidgetTester tester, {
      required NightjarAssetAcceptance acceptance,
    }) async {
      await tester.binding.setSurfaceSize(const Size(460, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final transport = _transport();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appBootstrapProvider.overrideWithValue(_bootstrap(acceptance)),
            nightjarAcceptanceStoreProvider.overrideWithValue(
              _MemoryAcceptanceStore(),
            ),
            nightjarMetadataFetcherProvider.overrideWithValue(
              NightjarAssetMetadataFetcher(transport: transport),
            ),
            nightjarViewLoaderProvider.overrideWithValue(
              () async => NightjarViewData(
                status: NightjarViewStatus.ready,
                assets: _pieces(4),
              ),
            ),
          ],
          child: MaterialApp(
            home: AppTheme(
              data: AppThemeData.dark,
              child: SingleChildScrollView(
                child: NightjarUniqueItemSection(asset: _piece(1, owned: true)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return transport;
    }

    testWidgets(
      'an unaccepted piece shows an empty frame and fetches nothing',
      (tester) async {
        final transport = await pumpPiece(
          tester,
          acceptance: const NightjarAssetAcceptance.empty(),
        );

        expect(find.byKey(const ValueKey('nightjar_logo_image')), findsNothing);
        expect(find.text(kNightjarUniqueArtworkNotFetchedText), findsOneWidget);
        expect(transport.requested, isEmpty);
        // The id is there whether or not a picture is.
        expect(
          find.byKey(const ValueKey('nightjar_unique_item_asset_id')),
          findsOneWidget,
        );
      },
    );

    testWidgets('an accepted piece draws artwork with its id beside it', (
      tester,
    ) async {
      await pumpPiece(
        tester,
        acceptance: NightjarAssetAcceptance([
          NightjarAcceptedAsset(assetId: _pieceId(1)),
        ]),
      );

      final image = tester.widget<Image>(
        find.byKey(const ValueKey('nightjar_logo_image')),
      );
      expect(image.width, kNightjarUniqueArtworkSize);
      // Section 4.2: bounded, but not bounded to a thumbnail.
      expect(
        (image.image as ResizeImage).width,
        lessThanOrEqualTo(kNightjarArtworkMaxDecodePixels),
      );
      expect(
        (image.image as ResizeImage).width,
        greaterThan(kNightjarLogoMaxDecodePixels),
      );

      expect(find.text('Phases of one night #1'), findsOneWidget);
      expect(find.text(truncateNightjarAssetId(_pieceId(1))), findsOneWidget);
      expect(find.text(kNightjarUniqueItemOwnedHeadline), findsOneWidget);
      // Never a quantity.
      expect(find.text('1'), findsNothing);
    });
  });

  group('the tile', () {
    testWidgets('carries the asset id under every picture it draws', (
      tester,
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
                child: NightjarCollectionTile(
                  member: _piece(7, owned: true),
                  artwork: NightjarArtworkData(
                    status: NightjarArtworkStatus.verified,
                    bytes: kOnePixelPng,
                    sourceOrigin: 'example.invalid',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Section 5: the id is beside the logo, always.
      expect(find.byKey(const ValueKey('nightjar_logo_image')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nightjar_collection_tile_asset_id')),
        findsOneWidget,
      );
      expect(find.text(truncateNightjarAssetId(_pieceId(7))), findsOneWidget);
      expect(find.text(kNightjarUniqueOwnedBadgeText), findsOneWidget);
    });

    testWidgets('bounds its decode at tile scale', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: AppTheme(
            data: AppThemeData.dark,
            child: MediaQuery(
              // A 3x phone: 160 logical pixels would ask for 480 without the
              // clamp, and a compression bomb would ask for whatever its
              // header claims.
              data: const MediaQueryData(devicePixelRatio: 3),
              child: Center(
                child: SizedBox(
                  width: 160,
                  height: 240,
                  child: NightjarCollectionTile(
                    member: _piece(7),
                    artwork: NightjarArtworkData(
                      status: NightjarArtworkStatus.verified,
                      bytes: kOnePixelPng,
                      sourceOrigin: 'example.invalid',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final image = tester.widget<Image>(
        find.byKey(const ValueKey('nightjar_logo_image')),
      );
      expect(image.width, 160);
      expect((image.image as ResizeImage).width, kNightjarLogoMaxDecodePixels);
    });
  });
}
