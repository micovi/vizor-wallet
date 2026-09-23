@Tags(['mobile'])
library;

/// The mobile Nyctis message receipt: the same facts as desktop, rendered
/// through [MobileListRow] inside the mobile card, with the back nav carrying
/// the asset.
///
/// The refusals are asserted here too rather than left to the desktop file.
/// The two screens share a body, but the assertion that a "To" row never
/// appears is cheap and the day someone gives mobile its own body is exactly
/// the day it would stop being true.

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_top_nav.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/mobile_list_row.dart';
import 'package:zcash_wallet/src/core/widgets/review_list_row.dart';
import 'package:zcash_wallet/src/features/activity/nyctis_activity_message.dart';
import 'package:zcash_wallet/src/features/activity/screens/mobile/mobile_nyctis_activity_detail_screen.dart';
import 'package:zcash_wallet/src/features/activity/screens/nyctis_activity_detail_screen.dart';

const _assetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
const _messageId =
    '82852615a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c';
const _txid =
    '9f8e7d6c5b4a39281716059483726150f1e2d3c4b5a69788796a5b4c3d2e1f0a';

NyctisActivityDetailArgs _sent() => NyctisActivityDetailArgs(
  item: NyctisActivityItem(
    msgId: _messageId,
    assetId: _assetId,
    kind: NyctisActivityKind.sent,
    delta: -BigInt.from(1250000),
    moved: BigInt.from(2000000),
    decimals: 6,
    height: BigInt.from(1240),
    name: 'Harbour credit',
    symbol: 'HBC',
    ownedInputs: 1,
    totalInputs: 1,
    ownedOutputs: 1,
    totalOutputs: 2,
  ),
  txidHex: _txid,
  carrierZatoshi: BigInt.from(20000),
  notes: [
    NyctisActivityDetailNote(
      role: NyctisActivityNoteRole.spent,
      position: BigInt.from(41),
      amount: BigInt.from(2000000),
      decimals: 6,
      createdHeight: BigInt.from(1180),
      spentByMessageId: _messageId,
      spentHeight: BigInt.from(1240),
      policyText: 'pk(ak) && before(1300)',
    ),
    NyctisActivityDetailNote(
      role: NyctisActivityNoteRole.created,
      position: BigInt.from(58),
      amount: BigInt.from(750000),
      decimals: 6,
      createdHeight: BigInt.from(1240),
    ),
  ],
);

Future<void> _pumpScreen(
  WidgetTester tester,
  NyctisActivityDetailArgs? args,
) async {
  await tester.binding.setSurfaceSize(const Size(393, 3600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final router = GoRouter(
    initialLocation: '/activity',
    routes: [
      GoRoute(path: '/activity', builder: (_, _) => const Text('activity')),
      GoRoute(
        path: nyctisActivityDetailRoutePattern,
        builder: (_, _) => MobileNyctisActivityDetailScreen(args: args),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      // The screen reads privacy mode, which is seeded from the bootstrap
      // snapshot; without this the provider throws before a row is built.
      overrides: [
        appBootstrapProvider.overrideWithValue(AppBootstrapState.empty),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => AppTheme(data: AppThemeData.dark, child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  router.push(nyctisActivityDetailRouteFor(_messageId), extra: args);
  await tester.pumpAndSettle();
}

String? _valueFor(WidgetTester tester, String label) {
  for (final row in tester.widgetList<MobileListRow>(
    find.byType(MobileListRow),
  )) {
    if (row.label == label) return row.value;
  }
  return null;
}

void main() {
  testWidgets('the receipt renders through the mobile list rows', (
    tester,
  ) async {
    await _pumpScreen(tester, _sent());

    // The shared facts card branches on kAppFormFactor, so the mobile lane
    // must not be rendering the desktop row.
    expect(find.byType(MobileListRow), findsWidgets);
    expect(find.byType(ReviewListRow), findsNothing);

    expect(_valueFor(tester, 'Event'), 'Sent');
    expect(_valueFor(tester, 'State'), 'Applied');
    expect(_valueFor(tester, 'Amount'), '-1.25 HBC');
    expect(_valueFor(tester, 'Completed at height'), '1,240');
    expect(_valueFor(tester, 'Inputs owned'), '1 of 1');
    expect(_valueFor(tester, 'Outputs readable'), '1 of 2');
  });

  testWidgets('the top nav names the asset and goes back', (tester) async {
    await _pumpScreen(tester, _sent());

    expect(find.byType(MobileTopNav), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MobileTopNav),
        matching: find.text('Harbour credit'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.text('activity'), findsOneWidget);
  });

  testWidgets('the asset id is on screen beside the name', (tester) async {
    await _pumpScreen(tester, _sent());

    // spec/asset-metadata-v0.md section 5.
    expect(find.text('Asset id'), findsOneWidget);
    expect(find.text('Message id'), findsOneWidget);
  });

  testWidgets('both note cards render', (tester) async {
    await _pumpScreen(tester, _sent());

    expect(find.text('Note this message spent'), findsOneWidget);
    expect(find.text('Note this message created'), findsOneWidget);
    expect(_valueFor(tester, 'Policy'), 'pk(ak) && before(1300)');
  });

  testWidgets('no recipient, no completed, no fee', (tester) async {
    await _pumpScreen(tester, _sent());

    expect(find.text('To'), findsNothing);
    expect(find.text('Recipient'), findsNothing);
    expect(find.text('Completed'), findsNothing);
    expect(find.text('Status'), findsNothing);
    expect(find.text('Tx fee'), findsNothing);
    expect(find.text('Fee'), findsNothing);
    expect(find.text('Paid to the channel'), findsOneWidget);
  });

  testWidgets('a route reached without a message invents nothing', (
    tester,
  ) async {
    await _pumpScreen(tester, null);

    expect(find.text(kNyctisActivityDetailNoMessageText), findsOneWidget);
    expect(find.text(kNyctisActivityDetailTitle), findsOneWidget);
    expect(find.byType(MobileListRow), findsNothing);
  });
}
