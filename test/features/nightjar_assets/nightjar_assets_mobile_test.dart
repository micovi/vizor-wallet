@Tags(['mobile'])
library;

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/src/core/layout/app_form_factor.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_tab_bar.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_bottom_safe_area.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_top_nav.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/mobile_list_row.dart';
import 'package:zcash_wallet/src/core/widgets/review_list_row.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/mobile/mobile_nightjar_asset_detail_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/mobile/mobile_nightjar_assets_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/mobile/mobile_nightjar_receive_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_mapper.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_assets_feed.dart';

const _assetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
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
      isPublic: true,
      balance: BigInt.from(1250000),
      decimals: 6,
      issuedSupply: BigInt.from(500000000000),
      notes: [
        NightjarNoteRowData(
          position: BigInt.from(41),
          amount: BigInt.from(1250000),
          decimals: 6,
          createdHeight: BigInt.from(1240),
        ),
      ],
    ),
    NightjarAssetDetailData(
      assetId: '0f1e2d3c4b5a69788796a5b4c3d2e1f0',
      balance: BigInt.from(3),
      decimals: 0,
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  NightjarViewLoader? loader,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final router = GoRouter(
    initialLocation: '/nightjar',
    routes: [
      GoRoute(path: '/nightjar', builder: (_, _) => screen),
      GoRoute(
        path: '/nightjar/receive',
        builder: (_, _) => const Text('mobile nightjar receive route'),
      ),
      GoRoute(
        path: '/nightjar/:assetId',
        builder: (_, state) =>
            Text('mobile detail route ${state.pathParameters['assetId']}'),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      // The override list length must stay constant across pumps inside one
      // test, so the default loader is injected rather than omitted.
      overrides: [
        nightjarViewLoaderProvider.overrideWithValue(
          loader ?? loadNotConfiguredNightjarView,
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => AppTheme(data: AppThemeData.dark, child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the mobile lane really compiles the mobile token set', (
    tester,
  ) async {
    expect(kAppFormFactor, AppFormFactor.mobile);
    expect(nightjarRowSupportingStyle, AppTypography.labelLarge);
  });

  testWidgets('the assets screen renders under the mobile top nav', (
    tester,
  ) async {
    await _pump(
      tester,
      const MobileNightjarAssetsScreen(),
      loader: () async => _readyView(),
    );

    expect(find.byType(MobileTopNav), findsOneWidget);
    expect(find.text('Nightjar assets'), findsOneWidget);
    expect(find.text('Harbour credit'), findsOneWidget);
    expect(find.text('Unnamed asset'), findsOneWidget);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('mobile_nightjar_assets_feed')))
          .dy,
      greaterThanOrEqualTo(kMobileTopNavHeight),
    );
  });

  testWidgets('tapping an asset routes to its detail path', (tester) async {
    await _pump(
      tester,
      const MobileNightjarAssetsScreen(),
      loader: () async => _readyView(),
    );

    await tester.tap(find.text('Harbour credit'));
    await tester.pumpAndSettle();
    expect(find.text('mobile detail route $_assetId'), findsOneWidget);
  });

  testWidgets('the receive action routes to the Nightjar receive path', (
    tester,
  ) async {
    await _pump(
      tester,
      const MobileNightjarAssetsScreen(),
      loader: () async => _readyView(),
    );

    await tester.tap(
      find.byKey(const ValueKey('mobile_nightjar_receive_button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('mobile nightjar receive route'), findsOneWidget);
  });

  testWidgets('the three degraded states keep their own copy on mobile', (
    tester,
  ) async {
    await _pump(tester, const MobileNightjarAssetsScreen());
    expect(find.text(kNightjarNotConfiguredText), findsOneWidget);

    await _pump(
      tester,
      const MobileNightjarAssetsScreen(),
      loader: () async =>
          const NightjarViewData(status: NightjarViewStatus.unreachable),
    );
    expect(find.text(kNightjarUnreachableText), findsOneWidget);

    await _pump(
      tester,
      const MobileNightjarAssetsScreen(),
      loader: () async => NightjarViewData(
        status: NightjarViewStatus.stale,
        assets: _readyView().assets,
      ),
    );
    expect(find.text(kNightjarStaleText), findsOneWidget);
    expect(find.text('Harbour credit'), findsOneWidget);
  });

  testWidgets('all three mobile screens clear the bottom edge', (tester) async {
    for (final screen in const <Widget>[
      MobileNightjarAssetsScreen(),
      MobileNightjarAssetDetailScreen(assetId: _assetId),
      MobileNightjarReceiveScreen(),
    ]) {
      await _pump(tester, screen, loader: () async => _readyView());

      final safeArea = find.byType(MobileBottomSafeArea);
      expect(safeArea, findsOneWidget, reason: '${screen.runtimeType}');
      expect(
        tester.widget<MobileBottomSafeArea>(safeArea).bottomPadding,
        kMobileTabBarHeight + AppSpacing.lg,
        reason: '${screen.runtimeType}',
      );
    }
  });

  testWidgets('the finality gap is explained on mobile too', (tester) async {
    await _pump(
      tester,
      const MobileNightjarAssetsScreen(),
      loader: () async => _readyView(pendingMessageCount: 1),
    );

    expect(
      find.byKey(const ValueKey('mobile_nightjar_assets_notice')),
      findsOneWidget,
    );
    expect(find.textContaining('1 channel message is waiting'), findsOneWidget);
  });

  testWidgets(
    'the detail screen uses the mobile list row, not the review row',
    (tester) async {
      await _pump(
        tester,
        const MobileNightjarAssetDetailScreen(assetId: _assetId),
        loader: () async => _readyView(),
      );

      expect(find.byType(MobileListRow), findsWidgets);
      expect(
        find.byType(ReviewListRow),
        findsNothing,
        reason: 'the desktop fact row must not leak into the mobile lane',
      );
      expect(find.text('Issued supply'), findsOneWidget);
      expect(find.text(kNightjarSupplyPrivacyNote), findsOneWidget);
      expect(find.text('Your balance'), findsOneWidget);
      // Once in the top nav, once as the declared `Name` fact.
      expect(find.text('Harbour credit'), findsNWidgets(2));
    },
  );

  testWidgets('the receive screen shows the address and its origin', (
    tester,
  ) async {
    await _pump(
      tester,
      const MobileNightjarReceiveScreen(),
      loader: () async => _readyView(),
    );

    expect(find.text('Receive Nightjar assets'), findsOneWidget);
    expect(find.text(_address), findsOneWidget);
    expect(find.text(kNightjarAddressDerivationNote), findsOneWidget);
  });
}
