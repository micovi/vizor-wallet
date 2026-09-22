/// What the Nightjar activity receipt says, and — the point of most of these
/// — what it refuses to say.
///
/// The refusals are pinned as hard as the assertions: a recipient row, a
/// "Completed" status and a fee label are each a thing the wallet cannot know,
/// and each of them is one careless copy edit away from reappearing.
library;

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/review_list_row.dart';
import 'package:zcash_wallet/src/features/activity/nightjar_activity_message.dart';
import 'package:zcash_wallet/src/features/activity/screens/nightjar_activity_detail_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';

const _assetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
const _otherAssetId =
    '77aa11bb22cc33dd44ee55ff6600778899aabbccddeeff001122334455667788';
const _messageId =
    '82852615a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c';
const _otherMessageId =
    'ea47c855f0e1d2c3b4a596877869504132231415f6e7d8c9bab1a29384756617';
const _txid =
    '9f8e7d6c5b4a39281716059483726150f1e2d3c4b5a69788796a5b4c3d2e1f0a';

NightjarActivityItem _sentItem() => NightjarActivityItem(
  msgId: _messageId,
  assetId: _assetId,
  kind: NightjarActivityKind.sent,
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
);

NightjarActivityItem _receivedItem() => NightjarActivityItem(
  msgId: _messageId,
  assetId: _assetId,
  kind: NightjarActivityKind.received,
  delta: BigInt.from(3),
  moved: BigInt.zero,
  decimals: 0,
  height: BigInt.from(1199),
  ownedInputs: 0,
  totalInputs: 0,
  ownedOutputs: 1,
  totalOutputs: 1,
);

NightjarActivityDetailArgs _sent() => NightjarActivityDetailArgs(
  item: _sentItem(),
  txidHex: _txid,
  carrierZatoshi: BigInt.from(20000),
  notes: [
    NightjarActivityDetailNote(
      role: NightjarActivityNoteRole.spent,
      position: BigInt.from(41),
      amount: BigInt.from(2000000),
      decimals: 6,
      createdHeight: BigInt.from(1180),
      spentByMessageId: _messageId,
      spentHeight: BigInt.from(1240),
      policyText: 'pk(ak) && before(1300)',
    ),
    NightjarActivityDetailNote(
      role: NightjarActivityNoteRole.created,
      position: BigInt.from(58),
      amount: BigInt.from(750000),
      decimals: 6,
      createdHeight: BigInt.from(1240),
    ),
  ],
);

NightjarActivityDetailArgs _received() => NightjarActivityDetailArgs(
  item: _receivedItem(),
  notes: [
    NightjarActivityDetailNote(
      role: NightjarActivityNoteRole.created,
      position: BigInt.from(7),
      amount: BigInt.from(3),
      decimals: 0,
      createdHeight: BigInt.from(1199),
    ),
  ],
);

Future<void> _pumpBody(
  WidgetTester tester,
  NightjarActivityDetailArgs? args, {
  bool privacyModeEnabled = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 3200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: SingleChildScrollView(
            child: NightjarActivityDetailBody(
              args: args,
              privacyModeEnabled: privacyModeEnabled,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The value rendered beside [label], or null when no such row exists.
String? _valueFor(WidgetTester tester, String label) {
  for (final row in tester.widgetList<ReviewListRow>(
    find.byType(ReviewListRow),
  )) {
    if (row.label == label) return row.value;
  }
  return null;
}

void main() {
  group('what the receipt shows', () {
    testWidgets('a sent message names the event, the state and the amount', (
      tester,
    ) async {
      await _pumpBody(tester, _sent());

      // The verb and the amount come from the row's own functions, so the
      // receipt cannot disagree with the feed about one message.
      expect(_valueFor(tester, 'Event'), 'Sent');
      expect(_valueFor(tester, 'State'), 'Applied');
      expect(_valueFor(tester, 'Amount'), '-1.25 HBC');
      expect(_valueFor(tester, 'Completed at height'), '1,240');
    });

    testWidgets('the message id and the carrying txid are both copyable', (
      tester,
    ) async {
      await _pumpBody(tester, _sent());

      final rows = tester.widgetList<ReviewListRow>(find.byType(ReviewListRow));
      final messageRow = rows.firstWhere((row) => row.label == 'Message id');
      final txRow = rows.firstWhere((row) => row.label == 'Zcash tx id');
      // Truncated on screen, whole on the clipboard: two ids that share six
      // characters must not become indistinguishable once copied.
      expect(messageRow.copyText, _messageId);
      expect(txRow.copyText, _txid);
      expect(messageRow.value, isNot(_messageId));
    });

    testWidgets('a message with no known carrier shows no tx row', (
      tester,
    ) async {
      await _pumpBody(tester, _received());

      // This cut is handed message bodies, not transactions, so an absent
      // carrier is the ordinary case and not a failure to report.
      expect(find.text('Zcash tx id'), findsNothing);
    });

    testWidgets('the asset id is shown even when a name is', (tester) async {
      await _pumpBody(tester, _sent());

      expect(_valueFor(tester, 'Name'), 'Harbour credit');
      expect(_valueFor(tester, 'Symbol'), 'HBC');
      // spec/asset-metadata-v0.md section 5: the id is the identity and has to
      // be visible wherever a name is.
      expect(find.text('Asset id'), findsOneWidget);
      final rows = tester.widgetList<ReviewListRow>(find.byType(ReviewListRow));
      expect(
        rows.firstWhere((row) => row.label == 'Asset id').copyText,
        _assetId,
      );
    });

    testWidgets('an unnamed asset is identified by its id alone', (
      tester,
    ) async {
      await _pumpBody(tester, _received());

      expect(find.text('Name'), findsNothing);
      expect(find.text('Symbol'), findsNothing);
      expect(find.text('Asset id'), findsOneWidget);
      expect(find.textContaining('has published no name'), findsOneWidget);
    });

    testWidgets('each side of the message is a count, never an amount', (
      tester,
    ) async {
      await _pumpBody(tester, _sent());

      expect(_valueFor(tester, 'Inputs owned'), '1 of 1');
      expect(_valueFor(tester, 'Outputs readable'), '1 of 2');
    });

    testWidgets('both sides of the message get a note card', (tester) async {
      await _pumpBody(tester, _sent());

      expect(find.text('Note this message spent'), findsOneWidget);
      expect(find.text('Note this message created'), findsOneWidget);
      expect(_valueFor(tester, 'Position'), isNotNull);
      expect(find.text('Created at height'), findsNWidgets(2));
      expect(_valueFor(tester, 'Spent at height'), '1,240');
      expect(_valueFor(tester, 'Policy'), 'pk(ak) && before(1300)');
      expect(
        tester
            .widgetList<ReviewListRow>(find.byType(ReviewListRow))
            .firstWhere((row) => row.label == 'Spent by')
            .copyText,
        _messageId,
      );
    });

    testWidgets('a note with no policy shows no policy row', (tester) async {
      await _pumpBody(tester, _received());

      expect(find.text('Policy'), findsNothing);
      expect(find.text('Spent by'), findsNothing);
    });

    testWidgets('the carrier ZEC row says where the ZEC went', (tester) async {
      await _pumpBody(tester, _sent());

      expect(find.text('Paid to the channel'), findsOneWidget);
      expect(find.textContaining('not a network fee'), findsOneWidget);
    });

    testWidgets('no carrier value means no ZEC row at all', (tester) async {
      await _pumpBody(tester, _received());

      expect(find.text('Paid to the channel'), findsNothing);
      expect(find.textContaining('not a network fee'), findsNothing);
    });

    testWidgets('privacy mode masks the amount here as it does in the feed', (
      tester,
    ) async {
      await _pumpBody(tester, _sent(), privacyModeEnabled: true);

      expect(find.text('-1.25 HBC'), findsNothing);
      expect(find.text('2 HBC'), findsNothing);
      expect(_valueFor(tester, 'Amount'), '*** HBC');
    });

    testWidgets('a message reached without arguments invents nothing', (
      tester,
    ) async {
      await _pumpBody(tester, null);

      expect(find.text(kNightjarActivityDetailNoMessageText), findsOneWidget);
      expect(find.byType(ReviewListRow), findsNothing);
    });

    testWidgets('a message this wallet holds no note of says so', (
      tester,
    ) async {
      await _pumpBody(tester, NightjarActivityDetailArgs(item: _sentItem()));

      expect(
        find.byKey(const ValueKey('nightjar_activity_detail_no_notes')),
        findsOneWidget,
      );
    });
  });

  group('what the receipt must never claim', () {
    testWidgets('there is no counterparty row on a sent message', (
      tester,
    ) async {
      await _pumpBody(tester, _sent());

      // Outputs addressed to anyone else are ciphertexts this wallet cannot
      // open, so nothing may stand where a ZEC receipt puts the counterparty.
      expect(find.text('To'), findsNothing);
      expect(find.text('Recipient'), findsNothing);
      expect(find.text('From'), findsNothing);
      expect(find.text('Sender'), findsNothing);
      expect(find.textContaining('no recipient to show'), findsOneWidget);
    });

    testWidgets('the unreadable outputs never become an amount', (
      tester,
    ) async {
      await _pumpBody(tester, _sent());

      // totalOutputs 2 − ownedOutputs 1 = 1 output nobody on this side can
      // name. It appears as part of a count and never as a figure of value.
      final values = tester
          .widgetList<ReviewListRow>(find.byType(ReviewListRow))
          .map((row) => row.value)
          .toList();
      expect(values, contains('1 of 2'));
      expect(values, isNot(contains('1.25')));
      expect(values, isNot(contains('0.5 HBC')));
    });

    testWidgets('no ZEC status vocabulary appears anywhere', (tester) async {
      for (final args in [_sent(), _received()]) {
        await _pumpBody(tester, args);
        expect(find.text('Completed'), findsNothing);
        expect(find.text('Confirmed'), findsNothing);
        expect(find.text('In progress'), findsNothing);
        expect(find.text('Status'), findsNothing);
      }
    });

    testWidgets('nothing on the screen is labelled a fee', (tester) async {
      await _pumpBody(tester, _sent());

      expect(find.text('Tx fee'), findsNothing);
      expect(find.text('Fee'), findsNothing);
      expect(find.text('Network fee'), findsNothing);
    });
  });

  group('the copy the state carries', () {
    test('every state has its own word and none of them is ZEC\'s', () {
      expect(
        nightjarActivityStateLabel(NightjarActivityMessageState.applied),
        'Applied',
      );
      expect(
        nightjarActivityStateLabel(NightjarActivityMessageState.ignored),
        'Ignored',
      );
      expect(
        nightjarActivityStateLabel(NightjarActivityMessageState.belowFinality),
        'Below finality',
      );
    });

    test('an ignored message carries the state machine\'s own reason', () {
      final facts = buildNightjarActivityMessageFacts(
        NightjarActivityDetailArgs(
          item: _receivedItem(),
          state: NightjarActivityMessageState.ignored,
          stateReason: 'message already applied',
        ),
      );
      expect(
        facts.firstWhere((fact) => fact.label == 'Reason').value,
        'message already applied',
      );
      expect(
        facts.firstWhere((fact) => fact.label == 'State').value,
        'Ignored',
      );
    });

    test('a reason is not shown for an applied message', () {
      final facts = buildNightjarActivityMessageFacts(
        NightjarActivityDetailArgs(
          item: _receivedItem(),
          stateReason: 'leftover',
        ),
      );
      expect(facts.where((fact) => fact.label == 'Reason'), isEmpty);
    });

    test('a below-finality message says none of it counts yet', () {
      final text = nightjarActivityMessageFootnote(
        NightjarActivityDetailArgs(
          item: _receivedItem(),
          state: NightjarActivityMessageState.belowFinality,
        ),
      );
      expect(text, contains('not deep enough yet'));
    });

    test('a self transfer says the money did not leave', () {
      final text = nightjarActivityMessageFootnote(
        NightjarActivityDetailArgs(
          item: NightjarActivityItem(
            msgId: _messageId,
            assetId: _assetId,
            kind: NightjarActivityKind.selfTransfer,
            delta: BigInt.zero,
            moved: BigInt.from(10),
            decimals: 0,
            height: BigInt.from(1199),
          ),
        ),
      );
      expect(text, contains('nothing left'));
    });

    test('a net names itself a net rather than a payment', () {
      final text = nightjarActivityMessageFootnote(
        NightjarActivityDetailArgs(
          item: NightjarActivityItem(
            msgId: _messageId,
            assetId: _assetId,
            kind: NightjarActivityKind.netChange,
            delta: -BigInt.from(5),
            moved: BigInt.from(5),
            decimals: 0,
            height: BigInt.from(1199),
          ),
        ),
      );
      expect(text, contains('net change'));
      expect(text, contains('not a payment it made'));
    });
  });

  group('integers all the way down', () {
    test('heights and positions are grouped, never rounded', () {
      expect(
        nightjarActivityHeightText(BigInt.parse('12345678901234567890')),
        '12,345,678,901,234,567,890',
      );
    });

    test('a note amount carries no sign — its role does', () {
      final note = NightjarActivityDetailNote(
        role: NightjarActivityNoteRole.spent,
        position: BigInt.from(41),
        amount: BigInt.from(2000000),
        decimals: 6,
        createdHeight: BigInt.from(1180),
        spentByMessageId: _otherMessageId,
      );
      expect(nightjarActivityNoteAmountText(note, 'HBC'), '2 HBC');
      expect(nightjarActivityNoteAmountText(note, ''), '2');
    });

    test('a share is a count', () {
      expect(nightjarActivityShareText(1, 2), '1 of 2');
    });
  });

  group('note cards', () {
    test('a single note of a side is not numbered', () {
      expect(
        nightjarActivityNoteCardTitle(NightjarActivityNoteRole.spent, 0, 1),
        'Note this message spent',
      );
    });

    test('several notes of a side are numbered within it', () {
      expect(
        nightjarActivityNoteCardTitle(NightjarActivityNoteRole.created, 1, 3),
        'Note this message created 2 of 3',
      );
    });
  });

  group('selecting the notes of one message', () {
    NightjarViewData view() => NightjarViewData(
      status: NightjarViewStatus.ready,
      assets: [
        NightjarAssetDetailData(
          assetId: _assetId,
          balance: BigInt.from(750000),
          decimals: 6,
          notes: [
            // Spent by the message: an input of it.
            NightjarNoteRowData(
              position: BigInt.from(41),
              amount: BigInt.from(2000000),
              decimals: 6,
              createdHeight: BigInt.from(1180),
              spent: true,
              createdBy: _otherMessageId,
              spentBy: _messageId,
              spentHeight: BigInt.from(1240),
              spentInputs: 1,
              spentOutputs: 2,
            ),
            // Created by it: the change.
            NightjarNoteRowData(
              position: BigInt.from(58),
              amount: BigInt.from(750000),
              decimals: 6,
              createdHeight: BigInt.from(1240),
              createdBy: _messageId,
              createdInputs: 1,
              createdOutputs: 2,
            ),
            // Nothing to do with it.
            NightjarNoteRowData(
              position: BigInt.from(12),
              amount: BigInt.from(1),
              decimals: 6,
              createdHeight: BigInt.from(1100),
              createdBy: _otherMessageId,
            ),
          ],
        ),
        NightjarAssetDetailData(
          assetId: _otherAssetId,
          balance: BigInt.from(4),
          decimals: 0,
          notes: [
            // The other half of a two-asset message.
            NightjarNoteRowData(
              position: BigInt.from(77),
              amount: BigInt.from(4),
              decimals: 0,
              createdHeight: BigInt.from(1240),
              createdBy: _messageId,
              createdInputs: 1,
              createdOutputs: 2,
            ),
          ],
        ),
      ],
    );

    test('inputs come first, then outputs, each by tree position', () {
      final notes = buildNightjarActivityDetailNotes(
        view: view(),
        msgId: _messageId,
        assetId: _assetId,
      );

      expect(notes, hasLength(2));
      expect(notes.first.role, NightjarActivityNoteRole.spent);
      expect(notes.first.position, BigInt.from(41));
      expect(notes.last.role, NightjarActivityNoteRole.created);
      expect(notes.last.position, BigInt.from(58));
    });

    test('a row about one asset does not pull in the other asset\'s note', () {
      final notes = buildNightjarActivityDetailNotes(
        view: view(),
        msgId: _messageId,
        assetId: _assetId,
      );
      expect(notes.where((note) => note.position == BigInt.from(77)), isEmpty);
    });

    test('no asset filter takes every asset the message touched', () {
      final notes = buildNightjarActivityDetailNotes(
        view: view(),
        msgId: _messageId,
      );
      expect(notes, hasLength(3));
    });

    test('a settling row names no message and selects nothing', () {
      expect(
        buildNightjarActivityDetailNotes(view: view(), msgId: ''),
        isEmpty,
      );
    });
  });

  group('routing', () {
    test('the route lives under /activity, not under /nightjar', () {
      expect(
        nightjarActivityDetailRoutePattern,
        '/activity/nightjar/:messageId',
      );
      expect(
        nightjarActivityDetailRouteFor(_messageId),
        '/activity/nightjar/$_messageId',
      );
      // A message id is 32-byte hex, exactly like an asset id, so this path
      // must not be able to match `/nightjar/:assetId`.
      expect(
        nightjarActivityDetailRouteFor(_messageId).startsWith('/nightjar/'),
        isFalse,
      );
    });
  });
}
