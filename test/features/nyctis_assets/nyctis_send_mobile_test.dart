@Tags(['mobile'])
library;

/// The mobile Nyctis send screens.
///
/// They are chrome around the same bodies the desktop panes use, so what is
/// pinned here is that the chrome does not lose anything: the ZEC cost is
/// still stated, an expired plan still cannot be sent, and the back arrow is
/// withheld while a proposal is live.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/mobile/mobile_nyctis_asset_detail_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/mobile/mobile_nyctis_send_review_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/mobile/mobile_nyctis_send_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/mobile/mobile_nyctis_send_status_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/nyctis_send_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/nyctis_send_status_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_send_flow.dart';

import 'support/nyctis_send_harness.dart';

void main() {
  testWidgets('the mobile composer refuses to send without a proving key', (
    tester,
  ) async {
    await pumpNyctisSend(
      tester,
      const MobileNyctisSendScreen(assetId: kHarnessAssetId),
      loader: () async => harnessReadyView(),
      provingKey: const NyctisProvingKeyStatus(
        state: NyctisProvingKeyState.notSet,
        message: kNyctisProvingKeyNotSetText,
      ),
    );

    expect(find.text(kNyctisSendTitle), findsWidgets);
    expect(find.text(kNyctisProvingKeyNotSetText), findsOneWidget);
    expect(reviewButton(tester).onPressed, isNull);
  });

  testWidgets('the mobile composer validates the amount against the balance', (
    tester,
  ) async {
    await pumpNyctisSend(
      tester,
      const MobileNyctisSendScreen(assetId: kHarnessAssetId),
      loader: () async => harnessReadyView(),
      provingKey: readyProvingKey,
    );

    await tester.enterText(
      find.byKey(const ValueKey('nyctis_send_amount_field')),
      '99',
    );
    await tester.pump();

    expect(find.textContaining('This wallet holds 1.25 HBC'), findsOneWidget);
    expect(reviewButton(tester).onPressed, isNull);
  });

  testWidgets('the mobile detail screen offers Send', (tester) async {
    await pumpNyctisSend(
      tester,
      const MobileNyctisAssetDetailScreen(assetId: kHarnessAssetId),
      loader: () async => harnessReadyView(),
      provingKey: readyProvingKey,
    );

    await tester.tap(
      find.byKey(const ValueKey('nyctis_asset_detail_send_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('send route $kHarnessAssetId'), findsOneWidget);
  });

  testWidgets('the mobile review states the ZEC cost and who receives it', (
    tester,
  ) async {
    await pumpNyctisSend(
      tester,
      MobileNyctisSendReviewScreen(args: harnessReviewArgs(memoCount: 3)),
      chainTip: 6923,
    );

    expect(find.text('ZEC to the channel'), findsOneWidget);
    expect(find.text('0.0003 ZEC'), findsOneWidget);
    expect(
      find.textContaining('paid to the channel, not to the recipient'),
      findsOneWidget,
    );
  });

  testWidgets('the mobile review refuses to send an expired plan', (
    tester,
  ) async {
    final args = harnessReviewArgs();
    await pumpNyctisSend(
      tester,
      MobileNyctisSendReviewScreen(args: args),
      chainTip: args.anchorHeight + 260,
    );

    expect(find.textContaining('spend the ZEC'), findsOneWidget);
    expect(
      appButtonWithKey(tester, 'nyctis_review_send_button').onPressed,
      isNull,
    );
  });

  testWidgets('the mobile receipt does not claim the recipient was paid', (
    tester,
  ) async {
    await pumpNyctisSend(
      tester,
      MobileNyctisSendStatusScreen(
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
  });

  testWidgets('the mobile receipt withholds back while the send is live', (
    tester,
  ) async {
    await pumpNyctisSend(
      tester,
      MobileNyctisSendStatusScreen(
        args: harnessReviewArgs(),
        broadcastRunner: harnessRunner(null),
      ),
    );
    await tester.pump();

    expect(
      appButtonWithKey(tester, 'nyctis_status_done_button').onPressed,
      isNull,
    );
    expect(find.text(kMobileNyctisStatusNavTitle), findsOneWidget);
    expect(find.text(kNyctisStatusSendingTitle), findsOneWidget);
  });
}
