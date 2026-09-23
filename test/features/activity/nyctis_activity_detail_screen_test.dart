/// What the Nyctis activity receipt says, and — the point of most of these
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
import 'package:zcash_wallet/src/features/activity/nyctis_activity_message.dart';
import 'package:zcash_wallet/src/features/activity/screens/nyctis_activity_detail_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_facts_card.dart';

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

NyctisActivityItem _sentItem() => NyctisActivityItem(
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
);

NyctisActivityItem _receivedItem() => NyctisActivityItem(
  msgId: _messageId,
  assetId: _assetId,
  kind: NyctisActivityKind.received,
  delta: BigInt.from(3),
  moved: BigInt.zero,
  decimals: 0,
  height: BigInt.from(1199),
  ownedInputs: 0,
  totalInputs: 0,
  ownedOutputs: 1,
  totalOutputs: 1,
);

NyctisActivityDetailArgs _sent() => NyctisActivityDetailArgs(
  item: _sentItem(),
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

NyctisActivityDetailArgs _received() => NyctisActivityDetailArgs(
  item: _receivedItem(),
  notes: [
    NyctisActivityDetailNote(
      role: NyctisActivityNoteRole.created,
      position: BigInt.from(7),
      amount: BigInt.from(3),
      decimals: 0,
      createdHeight: BigInt.from(1199),
    ),
  ],
);

Future<void> _pumpBody(
  WidgetTester tester,
  NyctisActivityDetailArgs? args, {
  bool privacyModeEnabled = false,
  bool openTechnical = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 3200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: SingleChildScrollView(
            child: NyctisActivityDetailBody(
              args: args,
              privacyModeEnabled: privacyModeEnabled,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (openTechnical) {
    // Message ids, heights, the input and output counts and the note cards
    // live in the folded "Technical details" section.
    await tester.tap(
      find.byKey(const ValueKey('nyctis_activity_detail_technical_toggle')),
    );
    await tester.pumpAndSettle();
  }
}

/// The fact rendered under [label] by any facts card on screen, or null when
/// no such row exists. The copy target lives on the fact (the whole row is
/// one pressable), not on the [ReviewListRow] it draws.
NyctisAssetFactData? _factFor(WidgetTester tester, String label) {
  for (final card in tester.widgetList<NyctisFactsCard>(
    find.byType(NyctisFactsCard),
  )) {
    for (final fact in card.facts) {
      if (fact.label == label) return fact;
    }
  }
  return null;
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
      await _pumpBody(tester, _sent(), openTechnical: true);

      // The verb and the amount are the headline, built from the row's own
      // item, so the receipt cannot disagree with the feed about one message.
      final headline = tester.widget<Text>(
        find.byKey(const ValueKey('nyctis_activity_detail_title')),
      );
      expect(headline.data, 'Sent 1.25 HBC');
      expect(headline.data, nyctisActivityHeadline(_sentItem()));
      // The state sits under the headline, as a word beside its icon.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nyctis_activity_detail_state')),
          matching: find.text('Final'),
        ),
        findsOneWidget,
      );
      expect(_valueFor(tester, 'Final at block'), '1,240');
    });

    testWidgets('the message id and the carrying txid are both copyable', (
      tester,
    ) async {
      await _pumpBody(tester, _sent(), openTechnical: true);

      final messageFact = _factFor(tester, 'Message id')!;
      final txFact = _factFor(tester, 'Zcash transaction')!;
      // Truncated on screen, whole on the clipboard: two ids that share six
      // characters must not become indistinguishable once copied.
      expect(messageFact.copyText, _messageId);
      expect(txFact.copyText, _txid);
      expect(messageFact.value, isNot(_messageId));
      expect(_valueFor(tester, 'Message id'), messageFact.value);
      // And each is an actual copy control on screen, not only data.
      expect(
        find.byKey(const ValueKey('nyctis_fact_copy_Message id')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('nyctis_fact_copy_Zcash transaction')),
        findsOneWidget,
      );
    });

    testWidgets('a message with no known carrier shows no tx row', (
      tester,
    ) async {
      await _pumpBody(tester, _received(), openTechnical: true);

      // This cut is handed message bodies, not transactions, so an absent
      // carrier is the ordinary case and not a failure to report.
      expect(find.text('Message id'), findsOneWidget);
      expect(find.text('Zcash transaction'), findsNothing);
    });

    testWidgets('the asset id is shown even when a name is', (tester) async {
      await _pumpBody(tester, _sent());

      expect(_valueFor(tester, 'Name'), 'Harbour credit');
      expect(_valueFor(tester, 'Symbol'), 'HBC');
      // spec/asset-metadata-v0.md section 5: the id is the identity and has to
      // be visible wherever a name is.
      expect(find.text('Asset id'), findsOneWidget);
      expect(_factFor(tester, 'Asset id')!.copyText, _assetId);
      expect(
        find.byKey(const ValueKey('nyctis_fact_copy_Asset id')),
        findsOneWidget,
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
      await _pumpBody(tester, _sent(), openTechnical: true);

      expect(_valueFor(tester, 'Inputs from this wallet'), '1 of 1');
      expect(_valueFor(tester, 'Outputs this wallet can read'), '1 of 2');
    });

    testWidgets('both sides of the message get a note card', (tester) async {
      await _pumpBody(tester, _sent(), openTechnical: true);

      expect(find.text('Note this message spent'), findsOneWidget);
      expect(find.text('Note this message created'), findsOneWidget);
      expect(_valueFor(tester, 'Tree position'), isNotNull);
      expect(find.text('Created at block'), findsNWidgets(2));
      expect(_valueFor(tester, 'Spent at block'), '1,240');
      expect(_valueFor(tester, 'Spend condition'), 'pk(ak) && before(1300)');
      expect(_factFor(tester, 'Spent by message')!.copyText, _messageId);
    });

    testWidgets('a note with no policy shows no policy row', (tester) async {
      await _pumpBody(tester, _received(), openTechnical: true);

      // The note card is open, so an absent row is really absent.
      expect(find.text('Note this message created'), findsOneWidget);
      expect(find.text('Spend condition'), findsNothing);
      expect(find.text('Spent by message'), findsNothing);
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
      await _pumpBody(
        tester,
        _sent(),
        privacyModeEnabled: true,
        openTechnical: true,
      );

      expect(find.textContaining('1.25'), findsNothing);
      expect(find.text('2 HBC'), findsNothing);
      expect(find.text('0.75 HBC'), findsNothing);
      final headline = tester.widget<Text>(
        find.byKey(const ValueKey('nyctis_activity_detail_title')),
      );
      expect(headline.data, 'Sent *** HBC');
      // Every note amount on the open note cards is masked too.
      final amounts = tester
          .widgetList<ReviewListRow>(find.byType(ReviewListRow))
          .where((row) => row.label == 'Amount')
          .map((row) => row.value)
          .toList();
      expect(amounts, ['*** HBC', '*** HBC']);
    });

    testWidgets('a message reached without arguments invents nothing', (
      tester,
    ) async {
      await _pumpBody(tester, null);

      expect(find.text(kNyctisActivityDetailNoMessageText), findsOneWidget);
      expect(find.byType(ReviewListRow), findsNothing);
    });

    testWidgets('a message this wallet holds no note of says so', (
      tester,
    ) async {
      await _pumpBody(
        tester,
        NyctisActivityDetailArgs(item: _sentItem()),
        openTechnical: true,
      );

      expect(
        find.byKey(const ValueKey('nyctis_activity_detail_no_notes')),
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
      await _pumpBody(tester, _sent(), openTechnical: true);

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
        await _pumpBody(tester, args, openTechnical: true);
        expect(find.text('Completed'), findsNothing);
        expect(find.text('Confirmed'), findsNothing);
        expect(find.text('In progress'), findsNothing);
        expect(find.text('Status'), findsNothing);
      }
    });

    testWidgets('nothing on the screen is labelled a fee', (tester) async {
      await _pumpBody(tester, _sent(), openTechnical: true);

      expect(find.text('Tx fee'), findsNothing);
      expect(find.text('Fee'), findsNothing);
      expect(find.text('Network fee'), findsNothing);
    });
  });

  group('the copy the state carries', () {
    test('every state has its own word and none of them is ZEC\'s', () {
      expect(
        nyctisActivityStateLabel(NyctisActivityMessageState.applied),
        'Final',
      );
      expect(
        nyctisActivityStateLabel(NyctisActivityMessageState.ignored),
        'Rejected by the channel',
      );
      expect(
        nyctisActivityStateLabel(NyctisActivityMessageState.belowFinality),
        'Not final yet',
      );
      final labels = NyctisActivityMessageState.values
          .map(nyctisActivityStateLabel)
          .toSet();
      expect(labels, hasLength(NyctisActivityMessageState.values.length));
      for (final zecWord in ['Completed', 'Confirmed', 'In progress']) {
        expect(labels, isNot(contains(zecWord)));
      }
    });

    testWidgets('an ignored message carries the state machine\'s own reason', (
      tester,
    ) async {
      final args = NyctisActivityDetailArgs(
        item: _receivedItem(),
        state: NyctisActivityMessageState.ignored,
        stateReason: 'message already applied',
      );
      final facts = buildNyctisActivityMessageFacts(args);
      expect(
        facts.firstWhere((fact) => fact.label == 'Reason').value,
        'message already applied',
      );

      // On screen: the reason row, and the state word under the headline.
      await _pumpBody(tester, args);
      expect(_valueFor(tester, 'Reason'), 'message already applied');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nyctis_activity_detail_state')),
          matching: find.text('Rejected by the channel'),
        ),
        findsOneWidget,
      );
    });

    test('a reason is not shown for an applied message', () {
      final facts = buildNyctisActivityMessageFacts(
        NyctisActivityDetailArgs(
          item: _receivedItem(),
          stateReason: 'leftover',
        ),
      );
      expect(facts.where((fact) => fact.label == 'Reason'), isEmpty);
    });

    test('a below-finality message says none of it counts yet', () {
      final text = nyctisActivityMessageFootnote(
        NyctisActivityDetailArgs(
          item: _receivedItem(),
          state: NyctisActivityMessageState.belowFinality,
        ),
      );
      expect(text, contains('not deep enough yet'));
    });

    test('a self transfer says the money did not leave', () {
      final text = nyctisActivityMessageFootnote(
        NyctisActivityDetailArgs(
          item: NyctisActivityItem(
            msgId: _messageId,
            assetId: _assetId,
            kind: NyctisActivityKind.selfTransfer,
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
      final text = nyctisActivityMessageFootnote(
        NyctisActivityDetailArgs(
          item: NyctisActivityItem(
            msgId: _messageId,
            assetId: _assetId,
            kind: NyctisActivityKind.netChange,
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
        nyctisActivityHeightText(BigInt.parse('12345678901234567890')),
        '12,345,678,901,234,567,890',
      );
    });

    test('a note amount carries no sign — its role does', () {
      final note = NyctisActivityDetailNote(
        role: NyctisActivityNoteRole.spent,
        position: BigInt.from(41),
        amount: BigInt.from(2000000),
        decimals: 6,
        createdHeight: BigInt.from(1180),
        spentByMessageId: _otherMessageId,
      );
      expect(nyctisActivityNoteAmountText(note, 'HBC'), '2 HBC');
      expect(nyctisActivityNoteAmountText(note, ''), '2');
    });

    test('a share is a count', () {
      expect(nyctisActivityShareText(1, 2), '1 of 2');
    });
  });

  group('note cards', () {
    test('a single note of a side is not numbered', () {
      expect(
        nyctisActivityNoteCardTitle(NyctisActivityNoteRole.spent, 0, 1),
        'Note this message spent',
      );
    });

    test('several notes of a side are numbered within it', () {
      expect(
        nyctisActivityNoteCardTitle(NyctisActivityNoteRole.created, 1, 3),
        'Note this message created 2 of 3',
      );
    });
  });

  group('selecting the notes of one message', () {
    NyctisViewData view() => NyctisViewData(
      status: NyctisViewStatus.ready,
      assets: [
        NyctisAssetDetailData(
          assetId: _assetId,
          balance: BigInt.from(750000),
          decimals: 6,
          notes: [
            // Spent by the message: an input of it.
            NyctisNoteRowData(
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
            NyctisNoteRowData(
              position: BigInt.from(58),
              amount: BigInt.from(750000),
              decimals: 6,
              createdHeight: BigInt.from(1240),
              createdBy: _messageId,
              createdInputs: 1,
              createdOutputs: 2,
            ),
            // Nothing to do with it.
            NyctisNoteRowData(
              position: BigInt.from(12),
              amount: BigInt.from(1),
              decimals: 6,
              createdHeight: BigInt.from(1100),
              createdBy: _otherMessageId,
            ),
          ],
        ),
        NyctisAssetDetailData(
          assetId: _otherAssetId,
          balance: BigInt.from(4),
          decimals: 0,
          notes: [
            // The other half of a two-asset message.
            NyctisNoteRowData(
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
      final notes = buildNyctisActivityDetailNotes(
        view: view(),
        msgId: _messageId,
        assetId: _assetId,
      );

      expect(notes, hasLength(2));
      expect(notes.first.role, NyctisActivityNoteRole.spent);
      expect(notes.first.position, BigInt.from(41));
      expect(notes.last.role, NyctisActivityNoteRole.created);
      expect(notes.last.position, BigInt.from(58));
    });

    test('a row about one asset does not pull in the other asset\'s note', () {
      final notes = buildNyctisActivityDetailNotes(
        view: view(),
        msgId: _messageId,
        assetId: _assetId,
      );
      expect(notes.where((note) => note.position == BigInt.from(77)), isEmpty);
    });

    test('no asset filter takes every asset the message touched', () {
      final notes = buildNyctisActivityDetailNotes(
        view: view(),
        msgId: _messageId,
      );
      expect(notes, hasLength(3));
    });

    test('a settling row names no message and selects nothing', () {
      expect(buildNyctisActivityDetailNotes(view: view(), msgId: ''), isEmpty);
    });
  });

  group('routing', () {
    test('the route lives under /activity, not under /nyctis', () {
      expect(nyctisActivityDetailRoutePattern, '/activity/nyctis/:messageId');
      expect(
        nyctisActivityDetailRouteFor(_messageId),
        '/activity/nyctis/$_messageId',
      );
      // A message id is 32-byte hex, exactly like an asset id, so this path
      // must not be able to match `/nyctis/:assetId`.
      expect(
        nyctisActivityDetailRouteFor(_messageId).startsWith('/nyctis/'),
        isFalse,
      );
    });
  });
}
