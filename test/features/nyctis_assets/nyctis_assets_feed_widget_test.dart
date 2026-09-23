import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_icon.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_mapper.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_assets_feed.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_facts_card.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_receive_panel.dart';

const _fullAssetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  AppThemeData theme = AppThemeData.dark,
  bool settle = true,
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
  // The shared loader repeats for as long as it is on screen, so a loading
  // state never settles; it is pumped one frame instead.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

TextStyle _styleOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!;

void main() {
  testWidgets('renders one card per section with rows in order', (
    tester,
  ) async {
    final sections = buildNyctisAssetSections(
      buildNyctisAssetRows(
        assets: [
          NyctisAssetDetailData(
            assetId: _fullAssetId,
            name: 'Harbour credit',
            symbol: 'HBC',
            isPublic: true,
            balance: BigInt.from(1250000),
            decimals: 6,
            notes: [
              NyctisNoteRowData(
                position: BigInt.one,
                amount: BigInt.from(1250000),
                decimals: 6,
                createdHeight: BigInt.from(1240),
              ),
            ],
          ),
          NyctisAssetDetailData(
            assetId: '0f1e2d3c4b5a69788796a5b4c3d2e1f0',
            balance: BigInt.from(3),
            decimals: 0,
          ),
        ],
      ),
    );

    await _pump(tester, NyctisAssetsFeed(sections: sections));

    // Each card is named for what is public about the asset — its supply —
    // and says under the heading that the balance is private in both.
    expect(find.text(kNyctisPublicSupplySectionTitle), findsOneWidget);
    expect(find.text(kNyctisPrivateSupplySectionTitle), findsOneWidget);
    expect(find.text(kNyctisPublicSupplySectionSubtitle), findsOneWidget);
    expect(find.text(kNyctisPrivateSupplySectionSubtitle), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(kNyctisPublicSupplySectionTitle)).dy,
      lessThan(
        tester.getTopLeft(find.text(kNyctisPrivateSupplySectionTitle)).dy,
      ),
    );
    expect(find.text('Harbour credit'), findsOneWidget);
    expect(find.text('HBC'), findsOneWidget);
    expect(find.text('1.25'), findsOneWidget);
    expect(find.text('1 note'), findsOneWidget);
    // The unnamed asset is a normal row, not an error state.
    expect(find.text('Unnamed asset'), findsOneWidget);
    expect(find.text('0f1e2d…c4b5a6'), findsNothing);
    expect(
      find.text(truncateNyctisAssetId('0f1e2d3c4b5a69788796a5b4c3d2e1f0')),
      findsOneWidget,
    );
    expect(find.byType(NyctisAssetRow), findsNWidgets(2));
  });

  testWidgets('a tappable row exposes a button and fires its callback', (
    tester,
  ) async {
    var tapped = '';
    final sections = buildNyctisAssetSections(
      buildNyctisAssetRows(
        assets: [
          NyctisAssetDetailData(
            assetId: _fullAssetId,
            name: 'Harbour credit',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
        onAssetTap: (assetId) => tapped = assetId,
      ),
    );

    await _pump(tester, NyctisAssetsFeed(sections: sections));
    await tester.tap(find.text('Harbour credit'));
    await tester.pumpAndSettle();

    expect(tapped, _fullAssetId);
  });

  testWidgets('the loading, empty, and three degraded states are distinct', (
    tester,
  ) async {
    await _pump(
      tester,
      const NyctisAssetsFeed(sections: [], isLoading: true),
      settle: false,
    );
    expect(find.text(kNyctisAssetsLoadingText), findsOneWidget);
    expect(find.byKey(const ValueKey('nyctis_message_loader')), findsOneWidget);

    await _pump(
      tester,
      const NyctisAssetsFeed(sections: [], emptyText: kNyctisEmptyText),
    );
    expect(find.text(kNyctisEmptyText), findsOneWidget);

    await _pump(
      tester,
      const NyctisAssetsFeed(
        sections: [],
        errorText: kNyctisNotConfiguredText,
        errorTone: NyctisMessageTone.neutral,
      ),
    );
    expect(find.text(kNyctisNotConfiguredText), findsOneWidget);

    await _pump(
      tester,
      const NyctisAssetsFeed(
        sections: [],
        errorText: kNyctisUnreachableText,
        errorTone: NyctisMessageTone.error,
      ),
    );
    expect(find.text(kNyctisUnreachableText), findsOneWidget);

    await _pump(
      tester,
      const NyctisAssetsFeed(
        sections: [],
        errorText: kNyctisStaleText,
        errorTone: NyctisMessageTone.warning,
      ),
    );
    expect(find.text(kNyctisStaleText), findsOneWidget);
  });

  testWidgets('each message tone resolves to its own theme token', (
    tester,
  ) async {
    const colors = AppThemeData.dark;
    await _pump(
      tester,
      const Column(
        children: [
          NyctisMessageCard(text: 'neutral'),
          NyctisMessageCard(text: 'warning', tone: NyctisMessageTone.warning),
          NyctisMessageCard(text: 'error', tone: NyctisMessageTone.error),
        ],
      ),
    );

    // Warning and error copy stays in text.primary for contrast (the utility
    // warning and destructive colours fall under WCAG AA on the card); the
    // tone is carried by a glyph of its own beside the words, never by colour
    // alone.
    expect(_styleOf(tester, 'neutral').color, colors.colors.text.secondary);
    expect(_styleOf(tester, 'warning').color, colors.colors.text.primary);
    expect(_styleOf(tester, 'error').color, colors.colors.text.primary);

    AppIcon? glyphOf(String text) {
      final icons = tester.widgetList<AppIcon>(
        find.descendant(
          of: find.ancestor(
            of: find.text(text),
            matching: find.byType(NyctisMessageCard),
          ),
          matching: find.byType(AppIcon),
        ),
      );
      return icons.isEmpty ? null : icons.single;
    }

    expect(glyphOf('neutral'), isNull);
    expect(glyphOf('warning')!.name, AppIcons.warning);
    expect(glyphOf('warning')!.color, colors.colors.icon.regular);
    expect(glyphOf('error')!.name, AppIcons.warningCircle);
    expect(glyphOf('error')!.color, colors.colors.icon.destructive);
  });

  testWidgets('feed text uses design-token styles in either lane', (
    tester,
  ) async {
    final sections = buildNyctisAssetSections(
      buildNyctisAssetRows(
        assets: [
          NyctisAssetDetailData(
            assetId: _fullAssetId,
            name: 'Harbour credit',
            symbol: 'HBC',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
      ),
    );
    await _pump(tester, NyctisAssetsFeed(sections: sections));

    expect(
      _styleOf(tester, 'Harbour credit').fontSize,
      AppTypography.bodyMediumStrong.fontSize,
    );
    expect(_styleOf(tester, 'HBC').fontSize, nyctisRowSupportingStyle.fontSize);
  });

  testWidgets('the detail facts card copies the full id behind a short one', (
    tester,
  ) async {
    final facts = buildNyctisAssetIdentityFacts(
      NyctisAssetDetailData(
        assetId: _fullAssetId,
        isPublic: true,
        balance: BigInt.zero,
        decimals: 0,
      ),
    );

    await _pump(
      tester,
      NyctisFactsCard(
        title: 'Identity',
        facts: facts,
        footnote: kNyctisSupplyPrivacyNote,
      ),
    );

    expect(find.text('Identity'), findsOneWidget);
    expect(find.text('Asset id'), findsOneWidget);
    expect(find.text(truncateNyctisAssetId(_fullAssetId)), findsOneWidget);
    expect(find.text(_fullAssetId), findsNothing);
    // The privacy statement is on the card, not buried in a tooltip.
    expect(find.text(kNyctisSupplyPrivacyNote), findsOneWidget);
  });

  testWidgets('the receive panel shows the whole address and its origin', (
    tester,
  ) async {
    const address =
        'nyreg1qqxvz8k3m7ph2j6ldu4cwesa9r0tg5y7n2q4v8xz3m6k9p2r5t8w1c4f7h0j3l6';
    await _pump(
      tester,
      const NyctisReceivePanel(address: address, networkLabel: 'Regtest'),
    );

    expect(find.byKey(const ValueKey('nyctis_receive_qr')), findsOneWidget);
    expect(find.text(address), findsOneWidget);
    expect(find.text('Regtest'), findsOneWidget);
    expect(find.text('Copy address'), findsOneWidget);
    expect(find.text(kNyctisAddressDerivationNote), findsOneWidget);
  });

  testWidgets('the receive panel says so when there is no identity yet', (
    tester,
  ) async {
    await _pump(tester, const NyctisReceivePanel(address: null));

    expect(find.text(kNyctisNoIdentityText), findsOneWidget);
    expect(find.byKey(const ValueKey('nyctis_receive_qr')), findsNothing);
  });

  testWidgets('renders in the light theme without exceptions', (tester) async {
    await _pump(
      tester,
      const NyctisAssetsFeed(sections: [], errorText: kNyctisStaleText),
      theme: AppThemeData.light,
    );
    expect(tester.takeException(), isNull);
    expect(find.text(kNyctisStaleText), findsOneWidget);
  });
}
