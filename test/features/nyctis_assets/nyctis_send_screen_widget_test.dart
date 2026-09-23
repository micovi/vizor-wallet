/// The three Nyctis send screens, rendered.
///
/// What is pinned here is the part a user can act on: the composer refuses to
/// offer a payment this wallet cannot prove or pay for and says why — before a
/// proof is started — the review states the whole ZEC cost, an expired or
/// already-sent plan cannot be sent from it, and the receipt says the
/// transaction is on the network rather than that the recipient has been paid,
/// and never leads back to a live Send.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/src/core/config/nyctis_config.dart';
import 'package:zcash_wallet/src/core/widgets/full_address_viewer.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_in_flight_send_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/nyctis_asset_detail_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/nyctis_send_review_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/nyctis_send_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/nyctis_send_status_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_send_flow.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';

import 'support/nyctis_send_harness.dart';

Future<void> _fillValid(WidgetTester tester, {String amount = '0.5'}) async {
  await tester.enterText(
    find.byKey(const ValueKey('nyctis_send_recipient_field')),
    kHarnessRecipient,
  );
  await tester.enterText(
    find.byKey(const ValueKey('nyctis_send_amount_field')),
    amount,
  );
  await tester.pump();
}

NyctisInFlightSend _inFlight({
  String msgId = 'aa11',
  int anchorHeight = 6913,
}) => NyctisInFlightSend(
  msgId: msgId,
  assetId: kHarnessAssetId,
  accountUuid: kHarnessAccountUuid,
  anchorHeight: anchorHeight,
  recordedAt: DateTime(2026, 9, 22),
);

void main() {
  group('the composer', () {
    testWidgets('without a proving key it says why and links to settings', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        provingKey: const NyctisProvingKeyStatus(
          state: NyctisProvingKeyState.notSet,
          message: kNyctisProvingKeyNotSetText,
        ),
      );

      expect(
        find.byKey(const ValueKey('nyctis_send_unavailable')),
        findsOneWidget,
      );
      expect(find.text(kNyctisProvingKeyNotSetText), findsOneWidget);
      expect(reviewButton(tester).onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('nyctis_send_open_settings')));
      await tester.pumpAndSettle();
      expect(find.text('nyctis settings route'), findsOneWidget);
    });

    testWidgets('a key from another ceremony disables sending by name', (
      tester,
    ) async {
      const message = 'The proving keys in /keys belong to a different key set';
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        provingKey: const NyctisProvingKeyStatus(
          state: NyctisProvingKeyState.wrongKeySet,
          dir: '/keys',
          message: message,
        ),
      );

      expect(find.text(message), findsOneWidget);
      expect(reviewButton(tester).onPressed, isNull);
    });

    testWidgets('a hardware account is told before it starts, not after', (
      tester,
    ) async {
      final builder = HarnessPlanBuilder();
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        hardware: true,
        planBuilder: builder.build,
      );
      await _fillValid(tester);

      expect(find.text(kNyctisHardwareAccountText), findsOneWidget);
      expect(reviewButton(tester).onPressed, isNull);
      // Not a settings problem, so no settings link.
      expect(
        find.byKey(const ValueKey('nyctis_send_open_settings')),
        findsNothing,
      );
      expect(builder.calls, 0);
    });

    testWidgets('too little ZEC to carry any message is refused up front', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        spendableZatoshi: BigInt.from(15000),
      );
      await _fillValid(tester);

      expect(find.textContaining('costs at least 0.0002 ZEC'), findsOneWidget);
      expect(find.textContaining('0.00015 ZEC spendable'), findsOneWidget);
      expect(reviewButton(tester).onPressed, isNull);
    });

    testWidgets('enough ZEC for the smallest message does not block', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        spendableZatoshi: BigInt.from(20000),
      );
      await _fillValid(tester);

      expect(reviewButton(tester).onPressed, isNotNull);
    });

    testWidgets('an amount above the balance names the balance', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
      );
      await _fillValid(tester, amount: '99');

      // The holding card above says 1.25, so "too much" on its own would read
      // as a bug. The message repeats the number it is refusing against.
      expect(find.textContaining('This wallet holds 1.25 HBC'), findsOneWidget);
      expect(reviewButton(tester).onPressed, isNull);
    });

    testWidgets('more decimal places than the asset has is refused', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
      );

      await tester.enterText(
        find.byKey(const ValueKey('nyctis_send_amount_field')),
        '0.1234567',
      );
      await tester.pump();

      expect(find.text('This asset has 6 decimal places.'), findsOneWidget);
    });

    testWidgets('a decimal comma is a decimal point, not a grouping (C7)', (
      tester,
    ) async {
      BigInt? amountSeen;
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        // Two HBC held, so 1.5 is sendable and the review button is live —
        // while 15, the grouping misreading, is not and would never reach
        // the plan builder.
        loader: () async => harnessReadyView(balance: BigInt.from(2000000)),
        planBuilder:
            ({
              required String assetId,
              required BigInt amount,
              required String recipient,
              String assetName = '',
              void Function(NyctisBuildPhase phase)? onPhase,
            }) async {
              amountSeen = amount;
              return const NyctisPayPlanResult.failed(error: 'stop here');
            },
      );
      await _fillValid(tester, amount: '1,5');

      expect(find.text('1.5'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nyctis_send_review_button')));
      await tester.pumpAndSettle();

      // 1.5 at six decimals, not 15.
      expect(amountSeen, BigInt.from(1500000));
    });

    testWidgets('the address hint is the configured network\'s own', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
      );
      expect(find.text('nyreg1…'), findsOneWidget);
      expect(find.text('nyreg1...'), findsNothing);
    });

    testWidgets('a malformed address is refused before any proof', (
      tester,
    ) async {
      final builder = HarnessPlanBuilder();
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        planBuilder: builder.build,
      );
      await tester.enterText(
        find.byKey(const ValueKey('nyctis_send_recipient_field')),
        'nyreg1recipient',
      );
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.enterText(
        find.byKey(const ValueKey('nyctis_send_amount_field')),
        '0.5',
      );
      await tester.pump();

      expect(find.textContaining('Check it for typos'), findsOneWidget);
      expect(reviewButton(tester).onPressed, isNull);
      expect(builder.calls, 0);
    });

    testWidgets('Paste fills the recipient from the clipboard', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': '  $kHarnessRecipient \n'};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
      );

      await tester.tap(find.byKey(const ValueKey('nyctis_send_paste_button')));
      await tester.pumpAndSettle();

      expect(find.text(kHarnessRecipient), findsOneWidget);
    });

    testWidgets('Use max fills the most one payment can move', (tester) async {
      NyctisNoteRowData note(int amount, int position) => NyctisNoteRowData(
        position: BigInt.from(position),
        amount: BigInt.from(amount),
        decimals: 6,
        createdHeight: BigInt.from(1240),
      );
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(
          balance: BigInt.from(1250000),
          notes: [note(500000, 1), note(250000, 2), note(500000, 3)],
        ),
      );

      // Three notes, two inputs: the ceiling is 0.5 + 0.5, not the 1.25 held.
      expect(
        find.byKey(const ValueKey('nyctis_send_two_note_limit')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('nyctis_send_max_button')));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('a valid amount and recipient enable review', (tester) async {
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
      );
      await _fillValid(tester);

      expect(reviewButton(tester).onPressed, isNotNull);
    });

    testWidgets('an unconfigured wallet says so instead of proving', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        // Turned off: nothing can be read or built.
        config: harnessConfig.copyWith(enabled: false),
      );
      await _fillValid(tester);
      await tester.tap(find.byKey(const ValueKey('nyctis_send_review_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('nyctis_send_error')), findsOneWidget);
    });

    testWidgets('while proving: one proof, no back link, and it is announced', (
      tester,
    ) async {
      final gate = Completer<void>();
      final builder = HarnessPlanBuilder(gate: gate);
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        planBuilder: builder.build,
      );
      await _fillValid(tester);

      final said = await captureAnnouncements(tester, () async {
        await tester.tap(
          find.byKey(const ValueKey('nyctis_send_review_button')),
        );
        await tester.pump();
        // A second submit before the first finishes starts nothing.
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
      });

      expect(builder.calls, 1);
      expect(said, contains(nyctisBuildPhaseText(NyctisBuildPhase.proving)));
      expect(
        find.byKey(const ValueKey('nyctis_send_back_hidden')),
        findsOneWidget,
      );
      expect(find.text(kNyctisSendPreparingLabel), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('review route'), findsOneWidget);
    });

    testWidgets('a failed build is announced with its reason', (tester) async {
      final builder = HarnessPlanBuilder(
        result: const NyctisPayPlanResult.failed(
          error: 'Not enough of this asset can be spent right now.',
        ),
      );
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        planBuilder: builder.build,
      );
      await _fillValid(tester);

      final said = await captureAnnouncements(tester, () async {
        await tester.tap(
          find.byKey(const ValueKey('nyctis_send_review_button')),
        );
        await tester.pumpAndSettle();
      });

      expect(
        said.last,
        'Payment not prepared. Not enough of this asset can be spent right '
        'now.',
      );
      expect(find.byKey(const ValueKey('nyctis_send_error')), findsOneWidget);
    });
  });

  group('a payment still settling', () {
    testWidgets('blocks a new payment of the same asset (C5)', (tester) async {
      final builder = HarnessPlanBuilder();
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        planBuilder: builder.build,
        inFlight: MemoryNyctisInFlightSendStore([_inFlight()]),
      );
      await tester.pumpAndSettle();
      await _fillValid(tester);

      expect(
        find.textContaining('Your last payment of HBC is not final yet'),
        findsOneWidget,
      );
      expect(reviewButton(tester).onPressed, isNull);
      expect(builder.calls, 0);
    });

    testWidgets('unblocks once the view shows the message applied', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(
          notes: [
            NyctisNoteRowData(
              position: BigInt.from(41),
              amount: BigInt.from(1250000),
              decimals: 6,
              createdHeight: BigInt.from(1240),
              spent: true,
              spentBy: 'aa11',
            ),
            NyctisNoteRowData(
              position: BigInt.from(58),
              amount: BigInt.from(1250000),
              decimals: 6,
              createdHeight: BigInt.from(1250),
              createdBy: 'aa11',
            ),
          ],
        ),
        inFlight: MemoryNyctisInFlightSendStore([_inFlight()]),
      );
      await tester.pumpAndSettle();
      await _fillValid(tester);

      expect(find.textContaining('is not final yet'), findsNothing);
      expect(reviewButton(tester).onPressed, isNotNull);
    });

    testWidgets('unblocks once the anchor window has passed', (tester) async {
      await pumpNyctisSend(
        tester,
        const NyctisSendPane(assetId: kHarnessAssetId),
        loader: () async =>
            harnessReadyView(viewHeight: BigInt.from(6913 + 200)),
        inFlight: MemoryNyctisInFlightSendStore([_inFlight()]),
      );
      await tester.pumpAndSettle();
      await _fillValid(tester);

      expect(reviewButton(tester).onPressed, isNotNull);
    });
  });

  group('the asset detail entry point', () {
    testWidgets('offers Send and routes to the composer', (tester) async {
      await pumpNyctisSend(
        tester,
        const NyctisAssetDetailPane(assetId: kHarnessAssetId),
      );

      await tester.tap(
        find.byKey(const ValueKey('nyctis_asset_detail_send_button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('send route $kHarnessAssetId'), findsOneWidget);
    });

    testWidgets('disables Send with the reason when there is no key', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisAssetDetailPane(assetId: kHarnessAssetId),
        provingKey: const NyctisProvingKeyStatus(
          state: NyctisProvingKeyState.notSet,
          message: kNyctisProvingKeyNotSetText,
        ),
      );

      expect(
        find.byKey(const ValueKey('nyctis_asset_detail_send_unavailable')),
        findsOneWidget,
      );
      final button = appButtonWithKey(
        tester,
        'nyctis_asset_detail_send_button',
      );
      expect(button.onPressed, isNull);
    });

    // The detail screen reads the same gate as the composer, so every reason
    // that would block Review blocks Send here first, with the same words.
    Future<void> expectDetailSendBlocked(WidgetTester tester) async {
      expect(
        find.byKey(const ValueKey('nyctis_asset_detail_send_unavailable')),
        findsOneWidget,
      );
      expect(
        appButtonWithKey(tester, 'nyctis_asset_detail_send_button').onPressed,
        isNull,
      );
    }

    testWidgets('disables Send for a hardware account, before the composer', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisAssetDetailPane(assetId: kHarnessAssetId),
        hardware: true,
      );

      await expectDetailSendBlocked(tester);
      expect(find.text(kNyctisHardwareAccountText), findsOneWidget);
    });

    testWidgets('disables Send while a payment of this asset settles', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisAssetDetailPane(assetId: kHarnessAssetId),
        inFlight: MemoryNyctisInFlightSendStore([_inFlight()]),
      );
      await tester.pumpAndSettle();

      await expectDetailSendBlocked(tester);
      expect(find.textContaining('is not final yet'), findsOneWidget);
    });

    testWidgets('disables Send without enough ZEC to carry a message', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisAssetDetailPane(assetId: kHarnessAssetId),
        spendableZatoshi: BigInt.from(15000),
      );

      await expectDetailSendBlocked(tester);
      expect(
        find.text(nyctisZecShortfallText(BigInt.from(15000))!),
        findsOneWidget,
      );
    });

    testWidgets('a missing key still offers the way to settings', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisAssetDetailPane(assetId: kHarnessAssetId),
        provingKey: const NyctisProvingKeyStatus(
          state: NyctisProvingKeyState.notSet,
          message: kNyctisProvingKeyNotSetText,
        ),
      );

      expect(
        find.byKey(const ValueKey('nyctis_send_open_settings')),
        findsOneWidget,
      );
    });

    testWidgets('an empty holding is not offered a Send button', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        const NyctisAssetDetailPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(balance: BigInt.zero),
      );

      expect(
        find.byKey(const ValueKey('nyctis_asset_detail_send_button')),
        findsNothing,
      );
    });
  });

  group('the review', () {
    testWidgets('states the channel ZEC, the network fee and the total', (
      tester,
    ) async {
      final args = harnessReviewArgs(memoCount: 3);
      await pumpNyctisSend(
        tester,
        NyctisSendReviewPane(args: args),
        chainTip: 6923,
      );

      expect(find.text('ZEC to the channel'), findsOneWidget);
      expect(find.text('0.0003 ZEC'), findsOneWidget);
      expect(find.text('Network fee'), findsOneWidget);
      expect(find.text('0.00015 ZEC'), findsOneWidget);
      expect(find.text('Total ZEC'), findsOneWidget);
      expect(find.text('0.00045 ZEC'), findsOneWidget);
      expect(
        find.textContaining('paid to the channel, not to the recipient'),
        findsOneWidget,
      );
      expect(find.text('Memos'), findsOneWidget);
    });

    testWidgets('shows the whole recipient address for checking', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        NyctisSendReviewPane(args: harnessReviewArgs()),
        chainTip: 6923,
      );

      final full = tester.widget<Text>(
        find.descendant(
          of: find.byType(FullAddressText),
          matching: find.byType(Text),
        ),
      );
      expect(full.data!.replaceAll(RegExp(r'\s'), ''), kHarnessRecipient);
    });

    testWidgets('Send waits for the fee quote', (tester) async {
      final gate = Completer<NyctisZecQuote>();
      await pumpNyctisSend(
        tester,
        NyctisSendReviewPane(args: harnessReviewArgs()),
        chainTip: 6923,
        quoter: harnessQuoter(gate: gate),
      );

      expect(find.text(kNyctisReviewQuotingText), findsNWidgets(2));
      expect(
        appButtonWithKey(tester, 'nyctis_review_send_button').onPressed,
        isNull,
      );
    });

    testWidgets('an account that cannot pay is told before Send', (
      tester,
    ) async {
      const error = 'This account does not have enough ZEC to carry this.';
      await pumpNyctisSend(
        tester,
        NyctisSendReviewPane(args: harnessReviewArgs()),
        chainTip: 6923,
        quoter: harnessQuoter(error: error),
      );

      expect(find.text(error), findsOneWidget);
      expect(
        appButtonWithKey(tester, 'nyctis_review_send_button').onPressed,
        isNull,
      );
    });

    testWidgets('confirming replaces the review and carries the quoted fee', (
      tester,
    ) async {
      Object? extra;
      await pumpNyctisSend(
        tester,
        NyctisSendReviewPane(args: harnessReviewArgs()),
        chainTip: 6923,
        extraRoutes: [
          GoRoute(
            path: nyctisSendStatusRoute,
            builder: (_, state) {
              extra = state.extra;
              return const Text('status route');
            },
          ),
        ],
      );

      expect(find.text(kNyctisReviewSendLabel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nyctis_review_send_button')));
      await tester.pumpAndSettle();

      expect(find.text('status route'), findsOneWidget);
      expect(
        (extra! as NyctisSendReviewArgs).quotedFeeZatoshi,
        BigInt.from(15000),
      );
      // `go`, not `push`: nothing is left underneath to go back to.
      final router = GoRouter.of(tester.element(find.text('status route')));
      expect(router.canPop(), isFalse);
    });

    testWidgets('Cancel leaves for the asset without sending', (tester) async {
      await pumpNyctisSend(
        tester,
        NyctisSendReviewPane(args: harnessReviewArgs()),
        chainTip: 6923,
      );

      await tester.tap(find.text(kNyctisReviewCancelLabel));
      await tester.pumpAndSettle();

      expect(find.text('asset route $kHarnessAssetId'), findsOneWidget);
    });

    testWidgets('an already-sent plan cannot be sent again (U2)', (
      tester,
    ) async {
      final args = harnessReviewArgs();
      await pumpNyctisSend(
        tester,
        NyctisSendReviewPane(args: args),
        chainTip: 6923,
        inFlight: MemoryNyctisInFlightSendStore([_inFlight(msgId: args.msgId)]),
      );
      await tester.pumpAndSettle();

      expect(find.text(kNyctisReviewAlreadySentText), findsOneWidget);
      expect(
        appButtonWithKey(tester, 'nyctis_review_send_button').onPressed,
        isNull,
      );
    });

    testWidgets('another payment of the asset still settling blocks Send', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        NyctisSendReviewPane(args: harnessReviewArgs()),
        chainTip: 6923,
        inFlight: MemoryNyctisInFlightSendStore([_inFlight()]),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('nyctis_review_blocked')),
        findsOneWidget,
      );
      expect(
        appButtonWithKey(tester, 'nyctis_review_send_button').onPressed,
        isNull,
      );
    });

    testWidgets('an expired plan offers Rebuild, not Send', (tester) async {
      final args = harnessReviewArgs();
      await pumpNyctisSend(
        tester,
        NyctisSendReviewPane(args: args),
        // Past the channel's anchor window.
        chainTip: args.anchorHeight + 260,
      );

      expect(
        find.byKey(const ValueKey('nyctis_review_freshness')),
        findsOneWidget,
      );
      expect(find.textContaining('spend the ZEC'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nyctis_review_send_button')),
        findsNothing,
      );
      expect(
        appButtonWithKey(tester, 'nyctis_review_rebuild_button').onPressed,
        isNotNull,
      );
    });

    testWidgets('an ageing plan warns but is still sendable', (tester) async {
      final args = harnessReviewArgs();
      await pumpNyctisSend(
        tester,
        NyctisSendReviewPane(args: args),
        chainTip: args.anchorHeight + 180,
      );

      expect(find.textContaining('more blocks'), findsOneWidget);
      final send = appButtonWithKey(tester, 'nyctis_review_send_button');
      expect(send.onPressed, isNotNull);
      expect(
        find.byKey(const ValueKey('nyctis_review_rebuild_button')),
        findsOneWidget,
      );
    });

    testWidgets('a channel changed since the build blocks the send', (
      tester,
    ) async {
      final args = harnessReviewArgs();
      await pumpNyctisSend(
        tester,
        NyctisSendReviewPane(args: args),
        chainTip: 6923,
        config: harnessConfig.copyWith(channelAddress: 'uregtestsomewhereelse'),
      );

      expect(
        find.byKey(const ValueKey('nyctis_review_channel_changed')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('nyctis_review_send_button')),
        findsNothing,
      );
    });

    testWidgets('no plan is an explanation, not an empty review', (
      tester,
    ) async {
      await pumpNyctisSend(tester, const NyctisSendReviewPane(args: null));

      expect(find.text(kNyctisReviewNoPlanText), findsOneWidget);
      expect(find.byKey(const ValueKey('nyctis_review_payment')), findsNothing);
    });
  });

  group('the receipt', () {
    testWidgets('says the transaction is on the network, not that it arrived', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        NyctisSendStatusPane(
          args: harnessReviewArgs(),
          broadcastRunner: harnessRunner(
            const NyctisSendOutcome(
              phase: NyctisSendOutcomePhase.succeeded,
              proposalConsumed: true,
              txid: 'abc123',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(kNyctisStatusSentTitle), findsOneWidget);
      expect(
        find.textContaining('applies it once that transaction is 10 blocks'),
        findsOneWidget,
      );
      // Regtest moves when blocks are mined, so no clock time is invented.
      expect(
        find.textContaining('once 10 more blocks are mined'),
        findsOneWidget,
      );
      expect(find.text('Transaction'), findsOneWidget);
      // One way to copy the hash: its row.
      expect(find.text('Copy transaction hash'), findsNothing);
    });

    testWidgets('records the payment as in flight, with its txid', (
      tester,
    ) async {
      final store = MemoryNyctisInFlightSendStore();
      final args = harnessReviewArgs();
      await pumpNyctisSend(
        tester,
        NyctisSendStatusPane(
          args: args,
          broadcastRunner: harnessRunner(
            const NyctisSendOutcome(
              phase: NyctisSendOutcomePhase.succeeded,
              proposalConsumed: true,
              txid: 'abc123',
            ),
          ),
        ),
        inFlight: store,
      );
      await tester.pumpAndSettle();

      expect(store.sends.single.msgId, args.msgId);
      expect(store.sends.single.txid, 'abc123');
    });

    testWidgets('a broadcast that did not land warns rather than celebrates', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        NyctisSendStatusPane(
          args: harnessReviewArgs(),
          broadcastRunner: harnessRunner(
            const NyctisSendOutcome(
              phase: NyctisSendOutcomePhase.pendingBroadcast,
              proposalConsumed: true,
              txid: 'abc123',
              statusMessage: 'It will retry automatically.',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(kNyctisStatusPendingTitle), findsOneWidget);
      expect(find.text('It will retry automatically.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nyctis_status_retry_button')),
        findsNothing,
      );
    });

    testWidgets('a failure before broadcast offers a safe retry (U26)', (
      tester,
    ) async {
      final store = MemoryNyctisInFlightSendStore();
      final args = harnessReviewArgs();
      await pumpNyctisSend(
        tester,
        NyctisSendStatusPane(
          args: args,
          broadcastRunner: harnessRunner(
            const NyctisSendOutcome(
              phase: NyctisSendOutcomePhase.failed,
              proposalConsumed: false,
              error: 'Insufficient shielded balance to cover the memos.',
            ),
          ),
        ),
        chainTip: 6923,
        inFlight: store,
      );
      await tester.pumpAndSettle();

      expect(find.text(kNyctisStatusFailedTitle), findsOneWidget);
      expect(
        find.textContaining('Insufficient shielded balance to cover'),
        findsOneWidget,
      );
      expect(find.textContaining('Nothing was broadcast'), findsOneWidget);
      expect(find.text('Transaction'), findsNothing);
      // Nothing reached the network, so the plan is not "in flight".
      expect(store.sends, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('nyctis_status_retry_button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('review route'), findsOneWidget);
    });

    testWidgets('a failure after the broadcast started offers no retry', (
      tester,
    ) async {
      final store = MemoryNyctisInFlightSendStore();
      await pumpNyctisSend(
        tester,
        NyctisSendStatusPane(
          args: harnessReviewArgs(),
          broadcastRunner: harnessRunner(
            const NyctisSendOutcome(
              phase: NyctisSendOutcomePhase.failed,
              proposalConsumed: true,
              txid: 'abc123',
              error: 'This payment was split across 2 transactions.',
            ),
          ),
        ),
        chainTip: 6923,
        inFlight: store,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('nyctis_status_retry_button')),
        findsNothing,
      );
      expect(store.sends, hasLength(1));
    });

    testWidgets('while sending: no back link, back refused, Done disabled', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        NyctisSendStatusPane(
          args: harnessReviewArgs(),
          broadcastRunner: harnessRunner(null),
        ),
        // The broadcast never finishes, so the loader never stops.
        settle: false,
      );
      await tester.pump();

      final done = appButtonWithKey(tester, 'nyctis_status_done_button');
      expect(done.onPressed, isNull);
      expect(find.text(kNyctisStatusSendingTitle), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nyctis_send_back_hidden')),
        findsOneWidget,
      );

      // System back (Android, Escape) does nothing while the send is live.
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text(kNyctisStatusSendingTitle), findsOneWidget);
    });

    testWidgets('back after the send leaves for the assets, not the review', (
      tester,
    ) async {
      await pumpNyctisSend(
        tester,
        NyctisSendStatusPane(
          args: harnessReviewArgs(),
          broadcastRunner: harnessRunner(
            const NyctisSendOutcome(
              phase: NyctisSendOutcomePhase.succeeded,
              proposalConsumed: true,
              txid: 'abc123',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('nyctis assets route'), findsOneWidget);
    });

    testWidgets('the outcome is announced to a screen reader (U11)', (
      tester,
    ) async {
      final said = await captureAnnouncements(tester, () async {
        await pumpNyctisSend(
          tester,
          NyctisSendStatusPane(
            args: harnessReviewArgs(),
            broadcastRunner: harnessRunner(
              const NyctisSendOutcome(
                phase: NyctisSendOutcomePhase.succeeded,
                proposalConsumed: true,
                txid: 'abc123',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      });

      expect(said, contains(nyctisSendPhaseText(NyctisSendPhase.proposing)));
      expect(said.last, startsWith(kNyctisStatusSentTitle));
    });

    testWidgets('no plan is an explanation, not a broadcast', (tester) async {
      await pumpNyctisSend(tester, const NyctisSendStatusPane(args: null));
      await tester.pumpAndSettle();

      expect(find.text(kNyctisStatusNoPlanText), findsOneWidget);
    });
  });

  test('the unconfigured default is not usable', () {
    expect(defaultNyctisConfig('main').isUsable, isFalse);
  });
}
