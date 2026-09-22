/// The three Nightjar send screens, rendered.
///
/// What is pinned here is the part a user can act on: the composer refuses to
/// offer a payment this wallet cannot prove and says why, the review screen
/// states the ZEC cost in words rather than leaving it to a fee row, an
/// expired plan cannot be sent from the review screen at all, and the receipt
/// says the transaction is on the network rather than that the recipient has
/// been paid.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/nightjar_config.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/nightjar_asset_detail_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/nightjar_send_review_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/nightjar_send_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/nightjar_send_status_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_send_flow.dart';

import 'support/nightjar_send_harness.dart';

void main() {
  group('the composer', () {
    testWidgets('will not offer to send without a proving key, and says why', (
      tester,
    ) async {
      await pumpNightjarSend(
        tester,
        const NightjarSendPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(),
        provingKey: const NightjarProvingKeyStatus(
          state: NightjarProvingKeyState.notSet,
          message: kNightjarProvingKeyNotSetText,
        ),
      );

      expect(
        find.byKey(const ValueKey('nightjar_send_unavailable')),
        findsOneWidget,
      );
      expect(find.text(kNightjarProvingKeyNotSetText), findsOneWidget);
      expect(reviewButton(tester).onPressed, isNull);
    });

    testWidgets('a key from another ceremony disables sending by name', (
      tester,
    ) async {
      const message = 'The proving keys in /keys belong to a different key set';
      await pumpNightjarSend(
        tester,
        const NightjarSendPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(),
        provingKey: const NightjarProvingKeyStatus(
          state: NightjarProvingKeyState.wrongKeySet,
          dir: '/keys',
          message: message,
        ),
      );

      expect(find.text(message), findsOneWidget);
      expect(reviewButton(tester).onPressed, isNull);
    });

    testWidgets('an amount above the balance names the balance', (
      tester,
    ) async {
      await pumpNightjarSend(
        tester,
        const NightjarSendPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(),
        provingKey: readyProvingKey,
      );

      await tester.enterText(
        find.byKey(const ValueKey('nightjar_send_recipient_field')),
        'njreg1recipient',
      );
      await tester.enterText(
        find.byKey(const ValueKey('nightjar_send_amount_field')),
        '99',
      );
      await tester.pump();

      // The holding card above says 1.25, so "too much" on its own would read
      // as a bug. The message repeats the number it is refusing against.
      expect(find.textContaining('This wallet holds 1.25 HBC'), findsOneWidget);
      expect(reviewButton(tester).onPressed, isNull);
    });

    testWidgets('more decimal places than the asset has is refused', (
      tester,
    ) async {
      await pumpNightjarSend(
        tester,
        const NightjarSendPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(),
        provingKey: readyProvingKey,
      );

      await tester.enterText(
        find.byKey(const ValueKey('nightjar_send_amount_field')),
        '0.1234567',
      );
      await tester.pump();

      expect(find.text('This asset has 6 decimal places.'), findsOneWidget);
    });

    testWidgets('a valid amount and recipient enable review', (tester) async {
      await pumpNightjarSend(
        tester,
        const NightjarSendPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(),
        provingKey: readyProvingKey,
      );

      await tester.enterText(
        find.byKey(const ValueKey('nightjar_send_recipient_field')),
        'njreg1recipient',
      );
      await tester.enterText(
        find.byKey(const ValueKey('nightjar_send_amount_field')),
        '0.5',
      );
      await tester.pump();

      expect(reviewButton(tester).onPressed, isNotNull);
    });

    testWidgets('an unconfigured wallet says so instead of proving', (
      tester,
    ) async {
      await pumpNightjarSend(
        tester,
        const NightjarSendPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(),
        provingKey: readyProvingKey,
        // No channel on the default network, so nothing can be read or built.
        config: defaultNightjarConfig('main'),
      );

      await tester.enterText(
        find.byKey(const ValueKey('nightjar_send_recipient_field')),
        'nj1recipient',
      );
      await tester.enterText(
        find.byKey(const ValueKey('nightjar_send_amount_field')),
        '0.5',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('nightjar_send_review_button')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('nightjar_send_error')), findsOneWidget);
    });
  });

  group('the asset detail entry point', () {
    testWidgets('offers Send and routes to the composer', (tester) async {
      await pumpNightjarSend(
        tester,
        const NightjarAssetDetailPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(),
        provingKey: readyProvingKey,
      );

      await tester.tap(
        find.byKey(const ValueKey('nightjar_asset_detail_send_button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('send route $kHarnessAssetId'), findsOneWidget);
    });

    testWidgets('disables Send with the reason when there is no key', (
      tester,
    ) async {
      await pumpNightjarSend(
        tester,
        const NightjarAssetDetailPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(),
        provingKey: const NightjarProvingKeyStatus(
          state: NightjarProvingKeyState.notSet,
          message: kNightjarProvingKeyNotSetText,
        ),
      );

      expect(
        find.byKey(const ValueKey('nightjar_asset_detail_send_unavailable')),
        findsOneWidget,
      );
      final button = appButtonWithKey(
        tester,
        'nightjar_asset_detail_send_button',
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('an empty holding is not offered a Send button', (
      tester,
    ) async {
      await pumpNightjarSend(
        tester,
        const NightjarAssetDetailPane(assetId: kHarnessAssetId),
        loader: () async => harnessReadyView(balance: BigInt.zero),
        provingKey: readyProvingKey,
      );

      expect(
        find.byKey(const ValueKey('nightjar_asset_detail_send_button')),
        findsNothing,
      );
    });
  });

  group('the review', () {
    testWidgets('states the ZEC cost, its total, and who receives it', (
      tester,
    ) async {
      final args = harnessReviewArgs(memoCount: 3);
      await pumpNightjarSend(
        tester,
        NightjarSendReviewPane(args: args),
        chainTip: 6923,
      );

      expect(find.text('ZEC to the channel'), findsOneWidget);
      expect(find.text('0.0003 ZEC'), findsOneWidget);
      expect(
        find.textContaining('paid to the channel, not to the recipient'),
        findsOneWidget,
      );
      expect(find.text('3 memos, one transaction'), findsOneWidget);
    });

    testWidgets('a fresh plan can be sent and routes to the status screen', (
      tester,
    ) async {
      final args = harnessReviewArgs();
      await pumpNightjarSend(
        tester,
        NightjarSendReviewPane(args: args),
        chainTip: 6923,
      );

      expect(
        find.byKey(const ValueKey('nightjar_review_freshness')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('nightjar_review_send_button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('status route'), findsOneWidget);
    });

    testWidgets('an expired plan cannot be sent and says what it would cost', (
      tester,
    ) async {
      final args = harnessReviewArgs();
      await pumpNightjarSend(
        tester,
        NightjarSendReviewPane(args: args),
        // 200 blocks past the anchor: outside the channel's anchor window.
        chainTip: args.anchorHeight + 260,
      );

      expect(
        find.byKey(const ValueKey('nightjar_review_freshness')),
        findsOneWidget,
      );
      expect(find.textContaining('spend the ZEC'), findsOneWidget);
      final send = appButtonWithKey(tester, 'nightjar_review_send_button');
      expect(send.onPressed, isNull);
    });

    testWidgets('an ageing plan warns but is still sendable', (tester) async {
      final args = harnessReviewArgs();
      await pumpNightjarSend(
        tester,
        NightjarSendReviewPane(args: args),
        chainTip: args.anchorHeight + 180,
      );

      expect(find.textContaining('more blocks'), findsOneWidget);
      final send = appButtonWithKey(tester, 'nightjar_review_send_button');
      expect(send.onPressed, isNotNull);
    });

    testWidgets('a channel changed since the build blocks the send', (
      tester,
    ) async {
      final args = harnessReviewArgs();
      await pumpNightjarSend(
        tester,
        NightjarSendReviewPane(args: args),
        chainTip: 6923,
        config: harnessConfig.copyWith(channelAddress: 'uregtestsomewhereelse'),
      );

      expect(
        find.byKey(const ValueKey('nightjar_review_channel_changed')),
        findsOneWidget,
      );
      final send = appButtonWithKey(tester, 'nightjar_review_send_button');
      expect(send.onPressed, isNull);
    });

    testWidgets('no plan is an explanation, not an empty review', (
      tester,
    ) async {
      await pumpNightjarSend(tester, const NightjarSendReviewPane(args: null));

      expect(find.text(kNightjarReviewNoPlanText), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nightjar_review_payment')),
        findsNothing,
      );
    });
  });

  group('the receipt', () {
    testWidgets('says the transaction is on the network, not that it arrived', (
      tester,
    ) async {
      await pumpNightjarSend(
        tester,
        NightjarSendStatusPane(
          args: harnessReviewArgs(),
          broadcastRunner: harnessRunner(
            const NightjarSendOutcome(
              phase: NightjarSendOutcomePhase.succeeded,
              proposalConsumed: true,
              txid: 'abc123',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(kNightjarStatusSentTitle), findsOneWidget);
      expect(
        find.textContaining('applies it once that transaction is 10 blocks'),
        findsOneWidget,
      );
      expect(find.text('Transaction'), findsOneWidget);
    });

    testWidgets('a broadcast that did not land warns rather than celebrates', (
      tester,
    ) async {
      await pumpNightjarSend(
        tester,
        NightjarSendStatusPane(
          args: harnessReviewArgs(),
          broadcastRunner: harnessRunner(
            const NightjarSendOutcome(
              phase: NightjarSendOutcomePhase.pendingBroadcast,
              proposalConsumed: true,
              txid: 'abc123',
              statusMessage: 'It will retry automatically.',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(kNightjarStatusPendingTitle), findsOneWidget);
      expect(find.text('It will retry automatically.'), findsOneWidget);
    });

    testWidgets('a failure shows the reason and no transaction', (
      tester,
    ) async {
      await pumpNightjarSend(
        tester,
        NightjarSendStatusPane(
          args: harnessReviewArgs(),
          broadcastRunner: harnessRunner(
            const NightjarSendOutcome(
              phase: NightjarSendOutcomePhase.failed,
              proposalConsumed: false,
              error: 'Insufficient shielded balance to cover the memos.',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(kNightjarStatusFailedTitle), findsOneWidget);
      expect(
        find.text('Insufficient shielded balance to cover the memos.'),
        findsOneWidget,
      );
      expect(find.text('Transaction'), findsNothing);
    });

    testWidgets('leaving is refused while the send is still in flight', (
      tester,
    ) async {
      await pumpNightjarSend(
        tester,
        NightjarSendStatusPane(
          args: harnessReviewArgs(),
          broadcastRunner: harnessRunner(null),
        ),
      );
      await tester.pump();

      final done = appButtonWithKey(tester, 'nightjar_status_done_button');
      expect(done.onPressed, isNull);
      expect(find.text(kNightjarStatusSendingTitle), findsOneWidget);
    });

    testWidgets('no plan is an explanation, not a broadcast', (tester) async {
      await pumpNightjarSend(tester, const NightjarSendStatusPane(args: null));
      await tester.pumpAndSettle();

      expect(find.text(kNightjarStatusNoPlanText), findsOneWidget);
    });
  });
}
