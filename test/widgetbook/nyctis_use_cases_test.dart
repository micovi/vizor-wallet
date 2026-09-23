import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_mapper.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_assets_feed.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_facts_card.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_receive_panel.dart';
import 'package:zcash_wallet/widgetbook/nyctis_use_cases.dart';

Future<void> _pump(
  WidgetTester tester,
  WidgetBuilder builder,
  AppThemeData theme, {
  bool settle = true,
}) async {
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
  // The shared loader repeats for as long as it is on screen, so a loading use
  // case never settles; it is pumped one frame instead.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  const themes = [AppThemeData.dark, AppThemeData.light];

  testWidgets('every Nyctis use case renders in both themes', (tester) async {
    const builders = <WidgetBuilder>[
      buildNyctisAssetsFeedUseCase,
      buildNyctisAssetsFeedLoadingUseCase,
      buildNyctisAssetsFeedEmptyUseCase,
      buildNyctisAssetsFeedNotConfiguredUseCase,
      buildNyctisAssetsFeedUnreachableUseCase,
      buildNyctisAssetsFeedStaleUseCase,
      buildNyctisPendingNoticeUseCase,
      buildNyctisAssetDetailUseCase,
      buildNyctisUnnamedAssetDetailUseCase,
      buildNyctisPrivateAssetDetailUseCase,
      buildNyctisFactsCardUseCase,
      buildNyctisReceiveUseCase,
      buildNyctisReceiveNotConfiguredUseCase,
      buildNyctisReceivePanelUseCase,
    ];

    for (final theme in themes) {
      for (final builder in builders) {
        await _pump(
          tester,
          builder,
          theme,
          settle: builder != buildNyctisAssetsFeedLoadingUseCase,
        );
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('the feed use case shows a named and an unnamed asset', (
    tester,
  ) async {
    await _pump(tester, buildNyctisAssetsFeedUseCase, AppThemeData.dark);

    expect(find.byType(NyctisAssetsFeed), findsOneWidget);
    expect(find.text('Harbour credit'), findsOneWidget);
    expect(find.text('HBC'), findsOneWidget);
    expect(find.text('Unnamed asset'), findsOneWidget);
    expect(find.text(kNyctisPublicSupplySectionTitle), findsOneWidget);
    expect(find.text(kNyctisPrivateSupplySectionTitle), findsOneWidget);
  });

  testWidgets('the loading use case draws the loader and its sentence', (
    tester,
  ) async {
    await _pump(
      tester,
      buildNyctisAssetsFeedLoadingUseCase,
      AppThemeData.dark,
      settle: false,
    );
    expect(find.text(kNyctisAssetsLoadingText), findsOneWidget);
    expect(find.byKey(const ValueKey('nyctis_message_loader')), findsOneWidget);
  });

  testWidgets('each degraded use case carries its own sentence', (
    tester,
  ) async {
    await _pump(
      tester,
      buildNyctisAssetsFeedNotConfiguredUseCase,
      AppThemeData.dark,
    );
    expect(find.text(kNyctisNotConfiguredText), findsOneWidget);

    await _pump(
      tester,
      buildNyctisAssetsFeedUnreachableUseCase,
      AppThemeData.dark,
    );
    expect(find.text(kNyctisUnreachableText), findsOneWidget);

    await _pump(tester, buildNyctisAssetsFeedStaleUseCase, AppThemeData.dark);
    expect(find.text(kNyctisStaleText), findsOneWidget);

    await _pump(tester, buildNyctisAssetsFeedEmptyUseCase, AppThemeData.dark);
    expect(find.text(kNyctisEmptyText), findsOneWidget);
  });

  testWidgets('the detail use cases state the supply privacy rule', (
    tester,
  ) async {
    await _pump(tester, buildNyctisAssetDetailUseCase, AppThemeData.dark);
    expect(find.text(kNyctisSupplyPrivacyNote), findsOneWidget);
    expect(find.text('Issued supply'), findsOneWidget);
    expect(find.text('Your balance'), findsOneWidget);

    await _pump(
      tester,
      buildNyctisPrivateAssetDetailUseCase,
      AppThemeData.dark,
    );
    expect(
      find.text(kNyctisSupplyPrivacyNote),
      findsNothing,
      reason:
          'the public-supply footnote directly under "Issued supply: Private" '
          'asserts the opposite of the row above it',
    );
    expect(find.text(kNyctisPrivateSupplyNote), findsOneWidget);
    expect(
      find.text('Max supply'),
      findsNothing,
      reason: 'a private asset has no knowable supply to print',
    );
  });

  testWidgets('the facts card and receive panel use cases render', (
    tester,
  ) async {
    await _pump(tester, buildNyctisFactsCardUseCase, AppThemeData.dark);
    expect(find.byType(NyctisFactsCard), findsOneWidget);
    expect(find.text('Identity'), findsOneWidget);

    await _pump(tester, buildNyctisReceivePanelUseCase, AppThemeData.dark);
    expect(find.byType(NyctisReceivePanel), findsOneWidget);
    expect(find.text('Copy address'), findsOneWidget);
    expect(find.text(kNyctisAddressDerivationNote), findsOneWidget);
  });
}
