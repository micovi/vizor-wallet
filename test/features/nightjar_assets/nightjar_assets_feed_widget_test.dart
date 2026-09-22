import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_mapper.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_assets_feed.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_facts_card.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_receive_panel.dart';

const _fullAssetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  AppThemeData theme = AppThemeData.dark,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: AppTheme(
        data: theme,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(child: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

TextStyle _styleOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!;

void main() {
  testWidgets('renders one card per section with rows in order', (
    tester,
  ) async {
    final sections = buildNightjarAssetSections(
      buildNightjarAssetRows(
        assets: [
          NightjarAssetDetailData(
            assetId: _fullAssetId,
            name: 'Harbour credit',
            symbol: 'HBC',
            isPublic: true,
            balance: BigInt.from(1250000),
            decimals: 6,
            notes: [
              NightjarNoteRowData(
                position: BigInt.one,
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
      ),
    );

    await _pump(tester, NightjarAssetsFeed(sections: sections));

    expect(find.text('Public assets'), findsOneWidget);
    expect(find.text('Private assets'), findsOneWidget);
    expect(find.text('Harbour credit'), findsOneWidget);
    expect(find.text('HBC'), findsOneWidget);
    expect(find.text('1.25'), findsOneWidget);
    expect(find.text('1 note'), findsOneWidget);
    // The unnamed asset is a normal row, not an error state.
    expect(find.text('Unnamed asset'), findsOneWidget);
    expect(find.text('0f1e2d…c4b5a6'), findsNothing);
    expect(
      find.text(truncateNightjarAssetId('0f1e2d3c4b5a69788796a5b4c3d2e1f0')),
      findsOneWidget,
    );
    expect(find.byType(NightjarAssetRow), findsNWidgets(2));
  });

  testWidgets('a tappable row exposes a button and fires its callback', (
    tester,
  ) async {
    var tapped = '';
    final sections = buildNightjarAssetSections(
      buildNightjarAssetRows(
        assets: [
          NightjarAssetDetailData(
            assetId: _fullAssetId,
            name: 'Harbour credit',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
        onAssetTap: (assetId) => tapped = assetId,
      ),
    );

    await _pump(tester, NightjarAssetsFeed(sections: sections));
    await tester.tap(find.text('Harbour credit'));
    await tester.pumpAndSettle();

    expect(tapped, _fullAssetId);
  });

  testWidgets('the loading, empty, and three degraded states are distinct', (
    tester,
  ) async {
    await _pump(
      tester,
      const NightjarAssetsFeed(sections: [], isLoading: true),
    );
    expect(find.text('Loading Nightjar assets...'), findsOneWidget);

    await _pump(
      tester,
      const NightjarAssetsFeed(sections: [], emptyText: kNightjarEmptyText),
    );
    expect(find.text(kNightjarEmptyText), findsOneWidget);

    await _pump(
      tester,
      const NightjarAssetsFeed(
        sections: [],
        errorText: kNightjarNotConfiguredText,
        errorTone: NightjarMessageTone.neutral,
      ),
    );
    expect(find.text(kNightjarNotConfiguredText), findsOneWidget);

    await _pump(
      tester,
      const NightjarAssetsFeed(
        sections: [],
        errorText: kNightjarUnreachableText,
        errorTone: NightjarMessageTone.error,
      ),
    );
    expect(find.text(kNightjarUnreachableText), findsOneWidget);

    await _pump(
      tester,
      const NightjarAssetsFeed(
        sections: [],
        errorText: kNightjarStaleText,
        errorTone: NightjarMessageTone.warning,
      ),
    );
    expect(find.text(kNightjarStaleText), findsOneWidget);
  });

  testWidgets('each message tone resolves to its own theme token', (
    tester,
  ) async {
    const colors = AppThemeData.dark;
    await _pump(
      tester,
      const Column(
        children: [
          NightjarMessageCard(text: 'neutral'),
          NightjarMessageCard(
            text: 'warning',
            tone: NightjarMessageTone.warning,
          ),
          NightjarMessageCard(text: 'error', tone: NightjarMessageTone.error),
        ],
      ),
    );

    expect(_styleOf(tester, 'neutral').color, colors.colors.text.secondary);
    expect(_styleOf(tester, 'warning').color, colors.colors.text.warning);
    expect(_styleOf(tester, 'error').color, colors.colors.text.destructive);
  });

  testWidgets('feed text uses design-token styles in either lane', (
    tester,
  ) async {
    final sections = buildNightjarAssetSections(
      buildNightjarAssetRows(
        assets: [
          NightjarAssetDetailData(
            assetId: _fullAssetId,
            name: 'Harbour credit',
            symbol: 'HBC',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
      ),
    );
    await _pump(tester, NightjarAssetsFeed(sections: sections));

    expect(
      _styleOf(tester, 'Harbour credit').fontSize,
      AppTypography.bodyMediumStrong.fontSize,
    );
    expect(
      _styleOf(tester, 'HBC').fontSize,
      nightjarRowSupportingStyle.fontSize,
    );
  });

  testWidgets('the detail facts card copies the full id behind a short one', (
    tester,
  ) async {
    final facts = buildNightjarAssetIdentityFacts(
      NightjarAssetDetailData(
        assetId: _fullAssetId,
        isPublic: true,
        balance: BigInt.zero,
        decimals: 0,
      ),
    );

    await _pump(
      tester,
      NightjarFactsCard(
        title: 'Identity',
        facts: facts,
        footnote: kNightjarSupplyPrivacyNote,
      ),
    );

    expect(find.text('Identity'), findsOneWidget);
    expect(find.text('Asset id'), findsOneWidget);
    expect(find.text(truncateNightjarAssetId(_fullAssetId)), findsOneWidget);
    expect(find.text(_fullAssetId), findsNothing);
    // The privacy statement is on the card, not buried in a tooltip.
    expect(find.text(kNightjarSupplyPrivacyNote), findsOneWidget);
  });

  testWidgets('the receive panel shows the whole address and its origin', (
    tester,
  ) async {
    const address =
        'njreg1qqxvz8k3m7ph2j6ldu4cwesa9r0tg5y7n2q4v8xz3m6k9p2r5t8w1c4f7h0j3l6';
    await _pump(
      tester,
      const NightjarReceivePanel(address: address, networkLabel: 'Regtest'),
    );

    expect(find.byKey(const ValueKey('nightjar_receive_qr')), findsOneWidget);
    expect(find.text(address), findsOneWidget);
    expect(find.text('Regtest'), findsOneWidget);
    expect(find.text('Copy address'), findsOneWidget);
    expect(find.text(kNightjarAddressDerivationNote), findsOneWidget);
  });

  testWidgets('the receive panel says so when there is no identity yet', (
    tester,
  ) async {
    await _pump(tester, const NightjarReceivePanel(address: null));

    expect(find.text(kNightjarNoIdentityText), findsOneWidget);
    expect(find.byKey(const ValueKey('nightjar_receive_qr')), findsNothing);
  });

  testWidgets('renders in the light theme without exceptions', (tester) async {
    await _pump(
      tester,
      const NightjarAssetsFeed(sections: [], errorText: kNightjarStaleText),
      theme: AppThemeData.light,
    );
    expect(tester.takeException(), isNull);
    expect(find.text(kNightjarStaleText), findsOneWidget);
  });
}
