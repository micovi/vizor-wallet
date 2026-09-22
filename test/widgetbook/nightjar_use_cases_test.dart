import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_mapper.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_assets_feed.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_facts_card.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_receive_panel.dart';
import 'package:zcash_wallet/widgetbook/nightjar_use_cases.dart';

Future<void> _pump(
  WidgetTester tester,
  WidgetBuilder builder,
  AppThemeData theme,
) async {
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: AppTheme(
        data: theme,
        child: Builder(builder: builder),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const themes = [AppThemeData.dark, AppThemeData.light];

  testWidgets('every Nightjar use case renders in both themes', (tester) async {
    const builders = <WidgetBuilder>[
      buildNightjarAssetsFeedUseCase,
      buildNightjarAssetsFeedLoadingUseCase,
      buildNightjarAssetsFeedEmptyUseCase,
      buildNightjarAssetsFeedNotConfiguredUseCase,
      buildNightjarAssetsFeedUnreachableUseCase,
      buildNightjarAssetsFeedStaleUseCase,
      buildNightjarPendingNoticeUseCase,
      buildNightjarAssetDetailUseCase,
      buildNightjarUnnamedAssetDetailUseCase,
      buildNightjarPrivateAssetDetailUseCase,
      buildNightjarFactsCardUseCase,
      buildNightjarReceiveUseCase,
      buildNightjarReceiveNotConfiguredUseCase,
      buildNightjarReceivePanelUseCase,
    ];

    for (final theme in themes) {
      for (final builder in builders) {
        await _pump(tester, builder, theme);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('the feed use case shows a named and an unnamed asset', (
    tester,
  ) async {
    await _pump(tester, buildNightjarAssetsFeedUseCase, AppThemeData.dark);

    expect(find.byType(NightjarAssetsFeed), findsOneWidget);
    expect(find.text('Harbour credit'), findsOneWidget);
    expect(find.text('HBC'), findsOneWidget);
    expect(find.text('Unnamed asset'), findsOneWidget);
    expect(find.text('Public assets'), findsOneWidget);
    expect(find.text('Private assets'), findsOneWidget);
  });

  testWidgets('each degraded use case carries its own sentence', (
    tester,
  ) async {
    await _pump(
      tester,
      buildNightjarAssetsFeedNotConfiguredUseCase,
      AppThemeData.dark,
    );
    expect(find.text(kNightjarNotConfiguredText), findsOneWidget);

    await _pump(
      tester,
      buildNightjarAssetsFeedUnreachableUseCase,
      AppThemeData.dark,
    );
    expect(find.text(kNightjarUnreachableText), findsOneWidget);

    await _pump(tester, buildNightjarAssetsFeedStaleUseCase, AppThemeData.dark);
    expect(find.text(kNightjarStaleText), findsOneWidget);

    await _pump(tester, buildNightjarAssetsFeedEmptyUseCase, AppThemeData.dark);
    expect(find.text(kNightjarEmptyText), findsOneWidget);
  });

  testWidgets('the detail use cases state the supply privacy rule', (
    tester,
  ) async {
    await _pump(tester, buildNightjarAssetDetailUseCase, AppThemeData.dark);
    expect(find.text(kNightjarSupplyPrivacyNote), findsOneWidget);
    expect(find.text('Issued supply'), findsOneWidget);
    expect(find.text('Your balance'), findsOneWidget);

    await _pump(
      tester,
      buildNightjarPrivateAssetDetailUseCase,
      AppThemeData.dark,
    );
    expect(
      find.text(kNightjarSupplyPrivacyNote),
      findsNothing,
      reason:
          'the public-supply footnote directly under "Issued supply: Private" '
          'asserts the opposite of the row above it',
    );
    expect(find.text(kNightjarPrivateSupplyNote), findsOneWidget);
    expect(
      find.text('Max supply'),
      findsNothing,
      reason: 'a private asset has no knowable supply to print',
    );
  });

  testWidgets('the facts card and receive panel use cases render', (
    tester,
  ) async {
    await _pump(tester, buildNightjarFactsCardUseCase, AppThemeData.dark);
    expect(find.byType(NightjarFactsCard), findsOneWidget);
    expect(find.text('Identity'), findsOneWidget);

    await _pump(tester, buildNightjarReceivePanelUseCase, AppThemeData.dark);
    expect(find.byType(NightjarReceivePanel), findsOneWidget);
    expect(find.text('Copy address'), findsOneWidget);
    expect(find.text(kNightjarAddressDerivationNote), findsOneWidget);
  });
}
