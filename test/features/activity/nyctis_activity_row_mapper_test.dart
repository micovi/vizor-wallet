/// What the Nyctis activity feed is allowed to say about a message.
///
/// The shape under test throughout is the one the devnet actually produced and
/// the one the old feed got wrong: a 1 000 NC receipt at height 7 246, spent at
/// 7 257, leaving 988 NC of change. A feed built from surviving notes showed
/// `+988` — money arriving, for the remainder of money leaving — and lost the
/// receipt entirely the moment it was spent. Both halves are asserted here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_icon.dart';
import 'package:zcash_wallet/src/features/activity/activity_feed_sections.dart';
import 'package:zcash_wallet/src/features/activity/nyctis_activity_row_mapper.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';

const _ncAssetId =
    'a3f1c0d29b8e47a5f6031d8c2b7e4906aa11bb22cc33dd44ee55ff6600778899';
const _unnamedAssetId =
    '00ff11ee22dd33cc44bb55aa6699778800112233445566778899aabbccddeeff';

/// The message that paid this wallet 1 000 NC at height 7 246.
const _receiptMsgId =
    '1111111111111111111111111111111111111111111111111111111111111111';

/// The message this wallet signed at height 7 257, which consumed that note.
const _sendMsgId =
    '2222222222222222222222222222222222222222222222222222222222222222';

NyctisNoteRowData _note({
  required int amount,
  required int position,
  required int createdHeight,
  required String createdBy,
  int decimals = 0,
  int createdInputs = 1,
  int createdOutputs = 1,
  bool spent = false,
  String? spentBy,
  int? spentHeight,
  int? spentInputs,
  int? spentOutputs,
}) {
  return NyctisNoteRowData(
    position: BigInt.from(position),
    amount: BigInt.from(amount),
    decimals: decimals,
    createdHeight: BigInt.from(createdHeight),
    spent: spent,
    createdBy: createdBy,
    createdInputs: createdInputs,
    createdOutputs: createdOutputs,
    spentBy: spentBy,
    spentHeight: spentHeight == null ? null : BigInt.from(spentHeight),
    spentInputs: spentInputs,
    spentOutputs: spentOutputs,
  );
}

NyctisViewData _view(
  List<NyctisAssetDetailData> assets, {
  int pendingMessageCount = 0,
  int viewHeight = 7258,
  int finalityDepth = 10,
}) {
  return NyctisViewData(
    status: NyctisViewStatus.ready,
    assets: assets,
    pendingMessageCount: pendingMessageCount,
    finalityDepth: finalityDepth,
    viewHeight: BigInt.from(viewHeight),
  );
}

NyctisAssetDetailData _nightcash(List<NyctisNoteRowData> notes) {
  return NyctisAssetDetailData(
    assetId: _ncAssetId,
    name: 'Nightcash',
    symbol: 'NC',
    balance: BigInt.from(988),
    decimals: 0,
    notes: notes,
  );
}

/// The devnet pair: 1 000 NC in at 7 246, spent at 7 257, 988 NC of change.
NyctisViewData _sendAndReceiptView({int pendingMessageCount = 0}) {
  return _view([
    _nightcash([
      _note(
        amount: 1000,
        position: 10,
        createdHeight: 7246,
        createdBy: _receiptMsgId,
        createdOutputs: 2,
        spent: true,
        spentBy: _sendMsgId,
        spentHeight: 7257,
        spentInputs: 1,
        spentOutputs: 2,
      ),
      _note(
        amount: 988,
        position: 20,
        createdHeight: 7257,
        createdBy: _sendMsgId,
        createdInputs: 1,
        createdOutputs: 2,
      ),
    ]),
  ], pendingMessageCount: pendingMessageCount);
}

/// Renders [body] under the app theme so a mapper that needs `context.colors`
/// can be exercised without a screen.
Future<void> _withContext(
  WidgetTester tester,
  void Function(BuildContext context) body,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AppTheme(
        data: AppThemeData.dark,
        child: Builder(
          builder: (context) {
            body(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
}

void main() {
  group('a payment this wallet authored', () {
    test('is one row for what left, and its change is not a row', () {
      final items = buildNyctisActivityItems(view: _sendAndReceiptView());

      expect(items, hasLength(2));
      final send = items.first;
      expect(send.kind, NyctisActivityKind.sent);
      expect(send.msgId, _sendMsgId);
      // 1 000 in, 988 back: 12 left. Never 988, and never 1 000.
      expect(send.delta, BigInt.from(-12));
      expect(send.height, BigInt.from(7257));

      // The receipt the old feed threw away when the note was spent.
      final receipt = items.last;
      expect(receipt.kind, NyctisActivityKind.received);
      expect(receipt.msgId, _receiptMsgId);
      expect(receipt.delta, BigInt.from(1000));
      expect(receipt.height, BigInt.from(7246));

      // The change note produced no row of its own at all.
      expect(
        items.where((item) => item.delta == BigInt.from(988)),
        isEmpty,
        reason: 'change is not a receipt',
      );
    });

    testWidgets('renders as a send, and never as `+988`', (tester) async {
      late List<ActivityEntry> entries;
      await _withContext(tester, (context) {
        entries = buildNyctisActivityEntries(
          context: context,
          items: buildNyctisActivityItems(view: _sendAndReceiptView()),
        );
      });

      expect(entries.first.row.title, kNyctisActivitySentTitle);
      expect(entries.first.row.amountText, '-12 NC');
      expect(entries.first.row.subtitle, 'Nightcash · block 7,257');
      expect(entries.last.row.title, kNyctisActivityReceivedTitle);
      expect(entries.last.row.amountText, '+1,000 NC');

      for (final entry in entries) {
        expect(
          entry.row.amountText,
          isNot(contains('988')),
          reason: 'the change of a send is never rendered as an arrival',
        );
      }
    });

    test('owning only some of the inputs is a net, not a send', () {
      // A `buy`: this wallet's note and somebody else's in one transition, so
      // `spentInputs` is 2 and this wallet owns one of them.
      final items = buildNyctisActivityItems(
        view: _view([
          _nightcash([
            _note(
              amount: 100,
              position: 10,
              createdHeight: 7100,
              createdBy: _receiptMsgId,
              spent: true,
              spentBy: _sendMsgId,
              spentHeight: 7200,
              spentInputs: 2,
              spentOutputs: 2,
            ),
            _note(
              amount: 150,
              position: 21,
              createdHeight: 7200,
              createdBy: _sendMsgId,
              createdInputs: 2,
              createdOutputs: 2,
            ),
          ]),
        ]),
      );

      final fill = items.first;
      expect(fill.kind, NyctisActivityKind.netChange);
      expect(fill.ownedInputs, 1);
      expect(fill.totalInputs, 2);
      expect(fill.delta, BigInt.from(50));
    });

    test('a missing input count is never read as authorship', () {
      // `spentInputs` absent: the producer did not say how many inputs the
      // message had. Owning one input is then not evidence of owning all.
      final items = buildNyctisActivityItems(
        view: _view([
          _nightcash([
            _note(
              amount: 100,
              position: 10,
              createdHeight: 7100,
              createdBy: _receiptMsgId,
              spent: true,
              spentBy: _sendMsgId,
              spentHeight: 7200,
            ),
          ]),
        ]),
      );

      expect(items.first.kind, NyctisActivityKind.netChange);
    });
  });

  group('paying yourself', () {
    test('is not a payment of nothing', () {
      // Two notes in, one note back: every output is this wallet's, so the
      // difference is zero and the money did not leave.
      final view = _view([
        _nightcash([
          _note(
            amount: 500,
            position: 10,
            createdHeight: 7000,
            createdBy: _receiptMsgId,
            spent: true,
            spentBy: _sendMsgId,
            spentHeight: 7100,
            spentInputs: 2,
            spentOutputs: 1,
          ),
          _note(
            amount: 500,
            position: 11,
            createdHeight: 7050,
            createdBy: _receiptMsgId,
            spent: true,
            spentBy: _sendMsgId,
            spentHeight: 7100,
            spentInputs: 2,
            spentOutputs: 1,
          ),
          _note(
            amount: 1000,
            position: 30,
            createdHeight: 7100,
            createdBy: _sendMsgId,
            createdInputs: 2,
            createdOutputs: 1,
          ),
        ]),
      ]);

      final consolidation = buildNyctisActivityItems(
        view: view,
      ).firstWhere((item) => item.msgId == _sendMsgId);
      expect(consolidation.kind, NyctisActivityKind.selfTransfer);
      expect(consolidation.delta, BigInt.zero);
      expect(consolidation.moved, BigInt.from(1000));
    });

    testWidgets('renders the amount that moved, with no sign and no zero', (
      tester,
    ) async {
      late ActivityEntry entry;
      await _withContext(tester, (context) {
        entry = nyctisActivityEntry(
          context: context,
          item: NyctisActivityItem(
            msgId: _sendMsgId,
            assetId: _ncAssetId,
            name: 'Nightcash',
            symbol: 'NC',
            kind: NyctisActivityKind.selfTransfer,
            delta: BigInt.zero,
            moved: BigInt.from(1000),
            decimals: 0,
            height: BigInt.from(7100),
            ownedInputs: 2,
            totalInputs: 2,
            ownedOutputs: 1,
            totalOutputs: 1,
          ),
        );
      });

      expect(entry.row.title, kNyctisActivitySelfTransferTitle);
      expect(entry.row.amountText, '1,000 NC');
      expect(entry.row.amountText, isNot(startsWith('+')));
      expect(entry.row.amountText, isNot(startsWith('-')));
      expect(entry.row.amountText, isNot('0 NC'));
    });
  });

  group('outputs this wallet cannot open', () {
    test('are a count, and never an amount', () {
      final send = buildNyctisActivityItems(
        view: _sendAndReceiptView(),
      ).first;

      // Two outputs, one of them this wallet's change. The other one exists —
      // that is why "sent" can be said — and what is in it is unknowable.
      expect(send.totalOutputs, 2);
      expect(send.ownedOutputs, 1);
      expect(send.hasUnreadableOutputs, isTrue);
      // The only figure derived from it is the difference between this
      // wallet's own inputs and its own outputs.
      expect(send.delta, BigInt.from(-12));
    });

    testWidgets('leave no recipient anywhere on the row', (tester) async {
      late ActivityEntry entry;
      await _withContext(tester, (context) {
        entry = nyctisActivityEntry(
          context: context,
          item: buildNyctisActivityItems(view: _sendAndReceiptView()).first,
        );
      });

      expect(entry.row.amountText, '-12 NC');
      expect(entry.row.subtitle, isNot(contains('to')));
      expect(entry.row.statusText, '');
      expect(entry.row.childRows, isEmpty);
    });
  });

  group('a receipt', () {
    test('sums every note the message gave this wallet', () {
      final items = buildNyctisActivityItems(
        view: _view([
          _nightcash([
            _note(
              amount: 40,
              position: 10,
              createdHeight: 7000,
              createdBy: _receiptMsgId,
              createdOutputs: 2,
            ),
            _note(
              amount: 60,
              position: 11,
              createdHeight: 7000,
              createdBy: _receiptMsgId,
              createdOutputs: 2,
            ),
          ]),
        ]),
      );

      expect(items, hasLength(1));
      expect(items.single.kind, NyctisActivityKind.received);
      expect(items.single.delta, BigInt.from(100));
    });

    test('an issuance is a receipt with nothing consumed', () {
      final items = buildNyctisActivityItems(
        view: _view([
          _nightcash([
            _note(
              amount: 1000,
              position: 1,
              createdHeight: 2201,
              createdBy: _receiptMsgId,
              createdInputs: 0,
            ),
          ]),
        ]),
      );

      expect(items.single.isIssuance, isTrue);
      expect(items.single.kind, NyctisActivityKind.received);
    });

    test('a note with no provenance claims only that it arrived', () {
      // A fixture, or any producer that does not fill the provenance in: the
      // note is grouped with nothing and renders as an arrival, which is
      // everything a bare note supports.
      final items = buildNyctisActivityItems(
        view: _view([
          _nightcash([
            NyctisNoteRowData(
              position: BigInt.from(9),
              amount: BigInt.from(5),
              decimals: 0,
              createdHeight: BigInt.from(7030),
            ),
          ]),
        ]),
      );

      expect(items.single.kind, NyctisActivityKind.received);
      expect(items.single.delta, BigInt.from(5));
    });
  });

  group('ordering', () {
    test(
      'is by block height, and a send is dated by the block it spent in',
      () {
        final items = buildNyctisActivityItems(view: _sendAndReceiptView());
        expect(items.map((item) => item.height.toInt()), [7257, 7246]);
      },
    );

    test('is total for two messages sharing a block', () {
      final items = buildNyctisActivityItems(
        view: _view([
          _nightcash([
            _note(
              amount: 1,
              position: 4,
              createdHeight: 100,
              createdBy: _sendMsgId,
            ),
            _note(
              amount: 2,
              position: 7,
              createdHeight: 100,
              createdBy: _receiptMsgId,
            ),
          ]),
        ]),
      );

      expect(items.map((item) => item.msgId), [_receiptMsgId, _sendMsgId]);
    });

    test('a row carries its height, because the devnet times cannot', () {
      final send = buildNyctisActivityItems(
        view: _sendAndReceiptView(),
      ).first;
      expect(send.blockLabel, 'block 7,257');
    });
  });

  group('nyctisActivityMessageHeights', () {
    test('asks for both ends of a note: created, and spent', () {
      expect(nyctisActivityMessageHeights(_sendAndReceiptView()), [
        7246,
        7257,
      ]);
    });

    test('is the distinct set, ascending', () {
      final heights = nyctisActivityMessageHeights(
        _view([
          _nightcash([
            _note(
              amount: 1,
              position: 4,
              createdHeight: 7164,
              createdBy: _receiptMsgId,
            ),
            _note(
              amount: 1,
              position: 5,
              createdHeight: 7164,
              createdBy: _receiptMsgId,
            ),
            _note(
              amount: 1,
              position: 6,
              createdHeight: 2201,
              createdBy: _sendMsgId,
            ),
          ]),
        ]),
      );

      expect(heights, [2201, 7164]);
    });
  });

  group('the ten-block window', () {
    test('is a row of its own while the channel is settling', () {
      final items = buildNyctisActivityItems(
        view: _sendAndReceiptView(pendingMessageCount: 2),
        settlingTimestamp: DateTime(2026, 9, 21, 12),
      );

      expect(items.first.kind, NyctisActivityKind.settling);
      expect(items.first.settlingMessageCount, 2);
      expect(items.first.settlingFinalityDepth, 10);
      // Sorted first: a payment just made is what the user is looking for.
      expect(items.map((item) => item.kind).skip(1), [
        NyctisActivityKind.sent,
        NyctisActivityKind.received,
      ]);
    });

    test('is absent when nothing is above the cut-off', () {
      final items = buildNyctisActivityItems(view: _sendAndReceiptView());
      expect(
        items.where((item) => item.kind == NyctisActivityKind.settling),
        isEmpty,
      );
    });

    test('is absent for a wallet with no Nyctis history of its own', () {
      // The messages above the cut-off are the channel's, and on a public
      // channel they are usually strangers'. Announcing them to a wallet that
      // holds nothing here would be noise about other people.
      final items = buildNyctisActivityItems(
        view: _view(const [], pendingMessageCount: 3),
      );
      expect(items, isEmpty);
    });

    testWidgets('says what is missing and offers nothing to open', (
      tester,
    ) async {
      late ActivityEntry entry;
      final at = DateTime(2026, 9, 21, 12);
      await _withContext(tester, (context) {
        entry = nyctisActivityEntry(
          context: context,
          item: buildNyctisActivityItems(
            view: _sendAndReceiptView(pendingMessageCount: 2),
            settlingTimestamp: at,
          ).first,
          onTap: () {},
        );
      });

      expect(entry.row.title, kNyctisActivitySettlingTitle);
      expect(
        entry.row.subtitle,
        'A payment from the last 10 blocks is not shown yet · 2 messages '
        'above block 7,258',
      );
      expect(entry.row.amountText, '--');
      expect(entry.row.statusText, kNyctisActivitySettlingStatus);
      expect(entry.row.statusIconName, AppIcons.loader);
      expect(entry.row.leadingIconName, AppIcons.loader);
      // Not a message, so there is no receipt behind it.
      expect(entry.row.onTap, isNull);
      expect(entry.timestamp, at);
    });
  });

  group('nyctisActivityAmountText', () {
    test('renders base units at the asset decimals with the symbol', () {
      expect(
        nyctisActivityAmountText(
          NyctisActivityItem(
            msgId: _receiptMsgId,
            assetId: _ncAssetId,
            symbol: 'DMT',
            kind: NyctisActivityKind.received,
            delta: BigInt.from(123456),
            moved: BigInt.zero,
            decimals: 2,
            height: BigInt.from(7164),
          ),
        ),
        '+1,234.56 DMT',
      );
    });

    test('omits the ticker when the issuer declared no symbol', () {
      expect(
        nyctisActivityAmountText(
          NyctisActivityItem(
            msgId: _receiptMsgId,
            assetId: _unnamedAssetId,
            kind: NyctisActivityKind.received,
            delta: BigInt.from(5),
            moved: BigInt.zero,
            decimals: 0,
            height: BigInt.from(7030),
          ),
        ),
        '+5',
      );
    });

    test('a net keeps its sign, and the title says it is a net', () {
      final gained = NyctisActivityItem(
        msgId: _sendMsgId,
        assetId: _ncAssetId,
        symbol: 'NC',
        kind: NyctisActivityKind.netChange,
        delta: BigInt.from(50),
        moved: BigInt.from(100),
        decimals: 0,
        height: BigInt.from(7200),
      );
      expect(nyctisActivityAmountText(gained), '+50 NC');
      expect(nyctisActivityTitle(gained), kNyctisActivityNetChangeTitle);
    });

    test('privacy mode hides the number and keeps the ticker', () {
      expect(
        nyctisActivityAmountText(
          NyctisActivityItem(
            msgId: _sendMsgId,
            assetId: _ncAssetId,
            symbol: 'NC',
            kind: NyctisActivityKind.sent,
            delta: BigInt.from(-12),
            moved: BigInt.from(1000),
            decimals: 0,
            height: BigInt.from(7257),
          ),
          privacyModeEnabled: true,
        ),
        '*** NC',
      );
    });
  });

  group('nyctisActivityEntry', () {
    testWidgets('never says "Completed", and names the asset and the block', (
      tester,
    ) async {
      late ActivityEntry entry;
      final mined = DateTime(2026, 9, 20, 13, 40);
      await _withContext(tester, (context) {
        entry = nyctisActivityEntry(
          context: context,
          item: buildNyctisActivityItems(
            view: _sendAndReceiptView(),
            blockTimes: {7257: mined},
          ).first,
        );
      });

      expect(entry.timestamp, mined);
      expect(entry.row.title, kNyctisActivitySentTitle);
      expect(entry.row.subtitle, 'Nightcash · block 7,257');
      expect(entry.row.statusText, '');
      expect(entry.row.leadingIconName, AppIcons.plane);
      expect(entry.row.stableId, 'nyctis-msg:$_sendMsgId:$_ncAssetId');
    });

    testWidgets('an undated message carries a null timestamp and "--" text', (
      tester,
    ) async {
      late ActivityEntry entry;
      await _withContext(tester, (context) {
        entry = nyctisActivityEntry(
          context: context,
          item: buildNyctisActivityItems(view: _sendAndReceiptView()).last,
        );
      });

      expect(entry.timestamp, isNull);
      expect(entry.row.timestampText, '--');
    });

    testWidgets('undated entries sort last and group under "Earlier"', (
      tester,
    ) async {
      late List<ActivityEntry> entries;
      await _withContext(tester, (context) {
        entries = buildNyctisActivityEntries(
          context: context,
          items: buildNyctisActivityItems(
            view: _sendAndReceiptView(),
            blockTimes: {
              7257: DateTime.now().subtract(const Duration(hours: 2)),
            },
          ),
        );
      });

      final sections = buildActivityFeedSections(entries);
      expect(sections.first.title, 'This week');
      expect(sections.first.rows.single.title, kNyctisActivitySentTitle);
      expect(sections.last.title, 'Earlier');
      expect(sections.last.rows.single.title, kNyctisActivityReceivedTitle);
    });
  });
}
