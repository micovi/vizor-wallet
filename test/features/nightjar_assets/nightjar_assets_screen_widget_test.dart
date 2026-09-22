import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/nightjar_asset_detail_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/nightjar_assets_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/nightjar_receive_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_mapper.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_assets_feed.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_collection_mapper.dart';

const _assetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
const _unnamedAssetId = '0f1e2d3c4b5a69788796a5b4c3d2e1f0';
const _address =
    'njreg1qqxvz8k3m7ph2j6ldu4cwesa9r0tg5y7n2q4v8xz3m6k9p2r5t8w1c4f7h0j3l6';

NightjarViewData _readyView({int pendingMessageCount = 0}) => NightjarViewData(
  status: NightjarViewStatus.ready,
  identity: const NightjarIdentityData(
    address: _address,
    networkLabel: 'Regtest',
  ),
  pendingMessageCount: pendingMessageCount,
  assets: [
    NightjarAssetDetailData(
      assetId: _assetId,
      name: 'Harbour credit',
      symbol: 'HBC',
      collection: 'Harbour',
      isPublic: true,
      balance: BigInt.from(1250000),
      decimals: 6,
      issuedSupply: BigInt.from(500000000000),
      maxSupply: BigInt.from(1000000000000),
      declaredMetadata: const [
        NightjarAssetFactData(label: 'Issuer note', value: 'Port of call'),
      ],
      notes: [
        NightjarNoteRowData(
          position: BigInt.from(41),
          amount: BigInt.from(1250000),
          decimals: 6,
          createdHeight: BigInt.from(1240),
          policyText: 'Spendable after height 1,300',
        ),
      ],
    ),
    NightjarAssetDetailData(
      assetId: _unnamedAssetId,
      balance: BigInt.from(3),
      decimals: 0,
      notes: [
        NightjarNoteRowData(
          position: BigInt.from(7),
          amount: BigInt.from(3),
          decimals: 0,
          createdHeight: BigInt.from(1199),
        ),
      ],
    ),
  ],
);

Future<void> _pumpPane(
  WidgetTester tester,
  Widget pane, {
  NightjarViewLoader? loader,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final router = GoRouter(
    initialLocation: '/nightjar',
    routes: [
      GoRoute(path: '/nightjar', builder: (_, _) => pane),
      GoRoute(
        path: '/nightjar/receive',
        builder: (_, _) => const Text('nightjar receive route'),
      ),
      GoRoute(
        path: '/nightjar/collection/:collectionId',
        builder: (_, state) =>
            Text('collection route ${state.pathParameters['collectionId']}'),
      ),
      GoRoute(
        path: '/nightjar/:assetId',
        builder: (_, state) =>
            Text('detail route ${state.pathParameters['assetId']}'),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (loader != null)
          nightjarViewLoaderProvider.overrideWithValue(loader),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => AppTheme(data: AppThemeData.dark, child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _collectionId =
    'c0113c710490aaaabbbbccccddddeeeeffff00001111222233334444555566667';

NightjarAssetDetailData _piece(int i, {bool owned = false}) =>
    NightjarAssetDetailData(
      assetId: 'pon${i.toString().padLeft(61, '0')}',
      name: 'Phases of one night #$i',
      symbol: 'PON',
      collection: _collectionId,
      isPublic: true,
      balance: owned ? BigInt.one : BigInt.zero,
      decimals: 0,
      issuedSupply: BigInt.one,
      maxSupply: BigInt.one,
    );

/// The devnet's real shape: two ordinary tokens sharing one `collection_id`,
/// plus a hundred unique items in another.
NightjarViewData _mixedView() => NightjarViewData(
  status: NightjarViewStatus.ready,
  assets: [
    ..._readyView().assets,
    for (var i = 0; i < 100; i++) _piece(i, owned: i < 3),
  ],
);

void main() {
  testWidgets('the shipped default loader says Nightjar is not configured', (
    tester,
  ) async {
    await _pumpPane(tester, const NightjarAssetsPane());

    expect(find.text('Nightjar assets'), findsOneWidget);
    expect(find.text(kNightjarNotConfiguredText), findsOneWidget);
    // No fabricated balance anywhere on an unconfigured wallet.
    expect(find.text('0'), findsNothing);
  });

  testWidgets('a ready view lists assets and routes to the detail screen', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetsPane(),
      loader: () async => _readyView(),
    );

    expect(find.text('Harbour credit'), findsOneWidget);
    expect(find.text('1.25'), findsOneWidget);
    expect(find.text('Unnamed asset'), findsOneWidget);
    expect(find.byKey(const ValueKey('nightjar_assets_notice')), findsNothing);

    await tester.tap(find.text('Harbour credit'));
    await tester.pumpAndSettle();
    expect(find.text('detail route $_assetId'), findsOneWidget);
  });

  testWidgets('a hundred unique items are one collection entry, not a hundred '
      'rows', (tester) async {
    await _pumpPane(
      tester,
      const NightjarAssetsPane(),
      loader: () async => _mixedView(),
    );

    // One entry for the collection, carrying both counts.
    expect(find.text('Phases of one night'), findsOneWidget);
    expect(find.textContaining('100 pieces · you hold 3'), findsOneWidget);

    // And not one member row: no piece's own name, and no row saying "1".
    expect(find.text('Phases of one night #0'), findsNothing);
    expect(find.text('Phases of one night #7'), findsNothing);

    await tester.tap(find.text('Phases of one night'));
    await tester.pumpAndSettle();
    expect(find.text('collection route $_collectionId'), findsOneWidget);
  });

  testWidgets('a fungible asset beside a collection still renders a balance', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetsPane(),
      loader: () async => _mixedView(),
    );

    // The regression guard: grouping must not swallow ordinary tokens.
    expect(find.text('Harbour credit'), findsOneWidget);
    expect(find.text('1.25'), findsOneWidget);
    // Both ungrouped rows keep a note count; a unique item would say
    // 'Unique item' instead, and neither of these does.
    expect(find.text('1 note'), findsNWidgets(2));
    expect(find.text(kNightjarUniqueItemLabel), findsNothing);
    expect(find.text(kNightjarCollectionsSectionTitle), findsOneWidget);
    expect(find.text('Public assets'), findsOneWidget);
  });

  testWidgets('messages above the cut-off are explained, not hidden', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetsPane(),
      loader: () async => _readyView(pendingMessageCount: 2),
    );

    final notice = find.byKey(const ValueKey('nightjar_assets_notice'));
    expect(notice, findsOneWidget);
    expect(
      find.textContaining('2 channel messages are waiting'),
      findsOneWidget,
      reason: 'a balance that omits a fresh receive has to say why',
    );
    expect(
      find.textContaining('notes are waiting'),
      findsNothing,
      reason:
          'the count is of channel messages from anyone; claiming they are '
          'this wallet\'s incoming notes is the false sentence',
    );
  });

  testWidgets('an unreachable indexer is distinct from an unconfigured one', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetsPane(),
      loader: () async =>
          const NightjarViewData(status: NightjarViewStatus.unreachable),
    );

    expect(find.text(kNightjarUnreachableText), findsOneWidget);
    expect(find.text(kNightjarNotConfiguredText), findsNothing);
  });

  testWidgets('a thrown loader failure degrades to the unreachable state', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetsPane(),
      loader: () async => throw StateError('indexer exploded'),
    );

    expect(find.text(kNightjarUnreachableText), findsOneWidget);
  });

  testWidgets('a stale indexer keeps the list and warns above it', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetsPane(),
      loader: () async {
        final ready = _readyView();
        return NightjarViewData(
          status: NightjarViewStatus.stale,
          identity: ready.identity,
          assets: ready.assets,
        );
      },
    );

    expect(find.text(kNightjarStaleText), findsOneWidget);
    expect(find.text('Harbour credit'), findsOneWidget);
  });

  testWidgets('the receive button routes to the Nightjar receive screen', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetsPane(),
      loader: () async => _readyView(),
    );

    await tester.tap(
      find.byKey(const ValueKey('nightjar_assets_receive_button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('nightjar receive route'), findsOneWidget);
  });

  testWidgets('the detail pane states what is public and what is not', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetDetailPane(assetId: _assetId),
      loader: () async => _readyView(),
    );

    expect(find.text('Harbour credit'), findsWidgets);
    expect(find.text('Harbour'), findsOneWidget);
    expect(find.text('Issued supply'), findsOneWidget);
    expect(find.text('500,000'), findsOneWidget);
    expect(find.text('Max supply'), findsOneWidget);
    expect(find.text(kNightjarSupplyPrivacyNote), findsOneWidget);
    // The wallet's own holding is labelled as the wallet's own.
    expect(find.text('Your balance'), findsOneWidget);
    expect(find.text('Your notes'), findsOneWidget);
    // The note facts.
    expect(find.text('Note 1'), findsOneWidget);
    expect(find.text('Position'), findsOneWidget);
    expect(find.text('Created at height'), findsOneWidget);
    expect(find.text('Spendable after height 1,300'), findsOneWidget);
    expect(find.text('Issuer note'), findsOneWidget);
  });

  testWidgets('a private asset is not told its supply is public', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetDetailPane(assetId: 'private-asset'),
      loader: () async => NightjarViewData(
        status: NightjarViewStatus.ready,
        assets: [
          NightjarAssetDetailData(
            assetId: 'private-asset',
            name: 'Crew pass',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
      ),
    );

    expect(find.text(kNightjarPrivateSupplyNote), findsOneWidget);
    expect(
      find.text(kNightjarSupplyPrivacyNote),
      findsNothing,
      reason:
          '"Issued supply is public" directly under "Issued supply: Private" '
          'contradicts the row it is a footnote to',
    );
  });

  testWidgets('a verification failure is not a network failure', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetsPane(),
      loader: () async => const NightjarViewData(
        status: NightjarViewStatus.unverified,
        statusMessage: kNightjarChannelMismatchText,
        statusDetail: 'The indexer serves channel ff, not ee.',
      ),
    );

    expect(find.text(kNightjarChannelMismatchText), findsOneWidget);
    expect(
      find.text(kNightjarUnreachableText),
      findsNothing,
      reason: 'the fix is in settings, and the copy has to point there',
    );
    expect(
      find.byKey(const ValueKey('nightjar_assets_notice')),
      findsNothing,
      reason: 'nothing to caveat when there is no view to show',
    );
  });

  testWidgets('a channel nothing verified on says which two things it is', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetsPane(),
      loader: () async => const NightjarViewData(
        status: NightjarViewStatus.unverified,
        statusMessage: kNightjarNothingVerifiedText,
        ignoredMessageCount: 343,
      ),
    );

    expect(find.text(kNightjarNothingVerifiedText), findsOneWidget);
    expect(
      find.text(kNightjarEmptyText),
      findsNothing,
      reason: 'a wrong verifying key must not render as an empty wallet',
    );
  });

  testWidgets('a borrowed chain tip is disclosed above the list', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetsPane(),
      loader: () async {
        final ready = _readyView();
        return NightjarViewData(
          status: NightjarViewStatus.ready,
          assets: ready.assets,
          chainTipSource: NightjarChainTipSource.indexer,
        );
      },
    );

    expect(find.textContaining(kNightjarBorrowedChainTipText), findsOneWidget);
    expect(find.text('Harbour credit'), findsOneWidget);
  });

  testWidgets('a private asset shows no issued-supply figure', (tester) async {
    await _pumpPane(
      tester,
      const NightjarAssetDetailPane(assetId: 'private-asset'),
      loader: () async => NightjarViewData(
        status: NightjarViewStatus.ready,
        assets: [
          NightjarAssetDetailData(
            assetId: 'private-asset',
            name: 'Crew pass',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
      ),
    );

    expect(find.text('Issued supply'), findsOneWidget);
    expect(
      find.text('Private'),
      findsNWidgets(2),
      reason: 'the Supply identity row and the issued-supply row both say so',
    );
    expect(
      find.text('Max supply'),
      findsNothing,
      reason: 'an unknowable supply must not be rendered as a number',
    );
  });

  testWidgets('an asset id the view does not hold says so plainly', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarAssetDetailPane(assetId: 'missing-asset'),
      loader: () async => _readyView(),
    );

    expect(
      find.text(nightjarUnknownAssetText('missing-asset')),
      findsOneWidget,
    );
  });

  testWidgets('the receive pane shows the address and where it came from', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      const NightjarReceivePane(),
      loader: () async => _readyView(),
    );

    expect(find.text('Receive Nightjar assets'), findsOneWidget);
    expect(find.text(_address), findsOneWidget);
    expect(find.text(kNightjarAddressDerivationNote), findsOneWidget);
  });

  testWidgets('the receive pane refuses to show an address before setup', (
    tester,
  ) async {
    await _pumpPane(tester, const NightjarReceivePane());

    expect(find.text(kNightjarNotConfiguredText), findsOneWidget);
    expect(find.text(_address), findsNothing);
  });
}
