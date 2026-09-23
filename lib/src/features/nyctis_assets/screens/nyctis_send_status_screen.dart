/// Desktop `/nyctis/send/status` — the broadcast leg and its receipt.
///
/// Everything above this screen is free: a plan is proved locally and costs
/// nothing but time. This screen is where the ZEC is spent, so it owns the
/// proposal from the moment it is made. The lifecycle rules are the ZEC send
/// flow's, unchanged — `execute_proposal` consumes on entry, and every exit
/// that did not consume runs the idempotent discard, including the one where
/// the user walks away mid-broadcast.
///
/// What it must never do is claim the payment arrived. A broadcast that
/// reached lightwalletd is a transaction on the network; the *channel* applies
/// the payment only once that transaction is buried under the finality depth,
/// and every verifier decides that for itself. The success copy says which of
/// the two has happened.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feedback/app_announce.dart';
import '../../../core/formatting/address_display.dart';
import '../../../core/formatting/number_format.dart';
import '../../../core/formatting/zec_amount.dart';
import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/review_buttons_stack.dart';
import '../../../providers/nyctis_config_provider.dart';
import '../../../providers/sync_provider.dart';
import '../providers/nyctis_assets_view_provider.dart';
import '../providers/nyctis_in_flight_send_provider.dart';
import '../services/nyctis_send_flow.dart';
import '../widgets/nyctis_asset_row_data.dart';
import '../widgets/nyctis_assets_feed.dart';
import '../widgets/nyctis_facts_card.dart';
import 'nyctis_send_chrome.dart';
import 'nyctis_send_review_screen.dart';

/// The runner the screen drives. Swapped in tests, which cannot reach Rust.
typedef NyctisSendBroadcastRunner =
    Future<NyctisSendOutcome> Function({
      required WidgetRef ref,
      required NyctisSendReviewArgs args,
      void Function(NyctisSendPhase phase)? onPhase,
      Future<bool> Function()? shouldAbort,
    });

const String kNyctisStatusSendingTitle = 'Sending Nyctis payment';
const String kNyctisStatusSentTitle = 'Payment sent';
const String kNyctisStatusPendingTitle = 'Payment not on the network yet';
const String kNyctisStatusFailedTitle = 'Payment not sent';
const String kNyctisStatusDoneLabel = 'Back to Nyctis assets';
const String kNyctisStatusRetryLabel = 'Try again';

/// Where every exit from the status screen goes. Never back to the review:
/// that plan is being, or has been, broadcast.
const String kNyctisStatusExitRoute = '/nyctis';

/// Shown when the route is reached without a plan. Nothing was proposed and
/// nothing was spent.
const String kNyctisStatusNoPlanText =
    'There is no Nyctis payment in progress. Start again from the asset you '
    'want to send.';

/// What a broadcast actually bought, said precisely.
///
/// The transaction is on the network; the channel has not applied anything
/// yet and will not until the block carrying it is final. Saying "sent" and
/// leaving it there is what makes a recipient's empty balance look like a bug.
String nyctisStatusSentText(int finalityDepth, {String? estimate}) =>
    'The transaction carrying this payment is on the network. Every wallet on '
    'the channel — including the recipient’s — applies it once that '
    'transaction is $finalityDepth blocks deep'
    '${estimate == null ? '' : ', $estimate'}, so it will not appear in a '
    'balance before then.';

/// Said beside a failure that put nothing on the network, where trying again
/// is safe.
const String kNyctisStatusNothingSentText =
    'Nothing was broadcast, so no ZEC was spent and the asset did not move.';

/// Phase copy for the two steps this screen genuinely knows about.
String nyctisSendPhaseText(NyctisSendPhase phase) {
  return switch (phase) {
    NyctisSendPhase.proposing => 'Choosing ZEC inputs for the memos…',
    NyctisSendPhase.broadcasting =>
      'Signing and broadcasting one transaction…',
  };
}

/// The receipt's facts: what the transaction carried, and what it cost.
List<NyctisAssetFactData> buildNyctisSendReceiptFacts({
  required NyctisSendReviewArgs args,
  String? txid,
}) {
  final symbol = args.assetSymbol.trim();
  final suffix = symbol.isEmpty ? '' : ' $symbol';
  return [
    NyctisAssetFactData(
      label: 'Amount',
      value: '${formatNyctisAmount(args.amount, args.assetDecimals)}$suffix',
    ),
    NyctisAssetFactData(
      label: 'To',
      value: truncatedAddress(args.recipient),
      copyText: args.recipient,
    ),
    NyctisAssetFactData(
      label: 'ZEC to the channel',
      value: ZecAmount.fromZatoshi(args.channelZatoshi).fee.toString(),
    ),
    NyctisAssetFactData(
      // The count alone: "one transaction" is the footnote's to say, and a
      // long value is what gets cut off first at large text sizes.
      label: 'Memos',
      value: formatGroupedInteger(args.memoCount),
    ),
    NyctisAssetFactData(
      label: 'Message id',
      value: truncateNyctisAssetId(args.msgId),
      copyText: args.msgId,
    ),
    if (txid != null)
      NyctisAssetFactData(
        label: 'Transaction',
        value: truncatedTxid(txid),
        copyText: txid,
      ),
  ];
}

class NyctisSendStatusScreen extends StatelessWidget {
  const NyctisSendStatusScreen({
    required this.args,
    this.broadcastRunner,
    super.key,
  });

  /// Null when the route was reached without a plan.
  final NyctisSendReviewArgs? args;

  @visibleForTesting
  final NyctisSendBroadcastRunner? broadcastRunner;

  @override
  Widget build(BuildContext context) {
    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NyctisSendStatusPane(
          args: args,
          broadcastRunner: broadcastRunner,
        ),
      ),
    );
  }
}

/// The pane body without the sidebar, so it renders on its own in tests and
/// in Widgetbook.
class NyctisSendStatusPane extends StatefulWidget {
  const NyctisSendStatusPane({
    required this.args,
    this.broadcastRunner,
    super.key,
  });

  final NyctisSendReviewArgs? args;

  @visibleForTesting
  final NyctisSendBroadcastRunner? broadcastRunner;

  @override
  State<NyctisSendStatusPane> createState() => _NyctisSendStatusPaneState();
}

class _NyctisSendStatusPaneState extends State<NyctisSendStatusPane> {
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    return NyctisSendPaneFrame(
      busy: _sending,
      // The body owns the stricter scope: never pop back to the review.
      popScope: false,
      child: NyctisSendStatusBody(
        args: widget.args,
        broadcastRunner: widget.broadcastRunner,
        onSendingChanged: (sending) {
          if (!mounted || sending == _sending) return;
          setState(() => _sending = sending);
        },
      ),
    );
  }
}

enum _NyctisStatusPhase { sending, succeeded, pendingBroadcast, failed }

/// The broadcast and its receipt, shared by the desktop pane and the mobile
/// screen.
class NyctisSendStatusBody extends ConsumerStatefulWidget {
  const NyctisSendStatusBody({
    required this.args,
    this.showTitle = true,
    this.broadcastRunner,
    this.onSendingChanged,
    super.key,
  });

  final NyctisSendReviewArgs? args;
  final bool showTitle;

  /// Fired when the broadcast starts and when it ends. The mobile chrome uses
  /// it to withhold its back arrow while a proposal is live, which the desktop
  /// pane gets from the `PopScope` below.
  final void Function(bool isSending)? onSendingChanged;

  @visibleForTesting
  final NyctisSendBroadcastRunner? broadcastRunner;

  @override
  ConsumerState<NyctisSendStatusBody> createState() =>
      _NyctisSendStatusBodyState();
}

class _NyctisSendStatusBodyState
    extends ConsumerState<NyctisSendStatusBody> {
  _NyctisStatusPhase _phase = _NyctisStatusPhase.sending;
  NyctisSendPhase _step = NyctisSendPhase.proposing;
  String? _txid;
  String? _error;
  String? _statusMessage;

  /// True when the failure provably put nothing on the network — the
  /// proposal was never executed — so the plan may be reviewed and sent again.
  bool _nothingBroadcast = false;

  @override
  void initState() {
    super.initState();
    if (widget.args == null) {
      _phase = _NyctisStatusPhase.failed;
      _error = kNyctisStatusNoPlanText;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_send());
    });
  }

  Future<void> _send() async {
    final args = widget.args;
    if (args == null) return;
    final inFlight = ref.read(nyctisInFlightSendsProvider.notifier);
    // Recorded before anything is proposed: from here on the review must not
    // offer this plan again, and no new payment of this asset may pick the
    // notes it spends until the channel has settled it.
    inFlight.record(args);
    setState(() {
      _phase = _NyctisStatusPhase.sending;
      _step = NyctisSendPhase.proposing;
      _error = null;
      _statusMessage = null;
      _nothingBroadcast = false;
    });
    widget.onSendingChanged?.call(true);
    unawaited(announceForAccessibility(context, nyctisSendPhaseText(_step)));

    final runner = widget.broadcastRunner ?? runNyctisSendBroadcast;
    final outcome = await runner(
      ref: ref,
      args: args,
      onPhase: (step) {
        if (!mounted) return;
        setState(() => _step = step);
        unawaited(
          announceForAccessibility(context, nyctisSendPhaseText(step)),
        );
      },
      // Leaving the screen mid-flight releases the proposal rather than
      // leaving this wallet's ZEC inputs locked until the proposal expires.
      shouldAbort: () async => !mounted,
    );

    final nothingBroadcast =
        !outcome.proposalConsumed &&
        (outcome.phase == NyctisSendOutcomePhase.failed ||
            outcome.phase == NyctisSendOutcomePhase.aborted);
    // The notifier outlives this screen, so the record is settled even when
    // the user left mid-flight.
    if (nothingBroadcast) {
      inFlight.release(args.msgId);
    } else {
      inFlight.attachTxid(args.msgId, outcome.txid);
    }

    if (!mounted) return;
    widget.onSendingChanged?.call(false);
    if (outcome.phase == NyctisSendOutcomePhase.aborted) return;

    // Not because the balance has changed — it has not, and will not until
    // the block carrying this is final — but because the channel now carries
    // one more message above the finality cut-off, and the assets screen's
    // notice is what turns "my balance did not move" into an explanation.
    if (outcome.phase != NyctisSendOutcomePhase.failed) {
      ref.invalidate(nyctisAssetsViewProvider);
    }

    setState(() {
      _phase = switch (outcome.phase) {
        NyctisSendOutcomePhase.succeeded => _NyctisStatusPhase.succeeded,
        NyctisSendOutcomePhase.pendingBroadcast =>
          _NyctisStatusPhase.pendingBroadcast,
        NyctisSendOutcomePhase.failed ||
        NyctisSendOutcomePhase.aborted => _NyctisStatusPhase.failed,
      };
      _txid = outcome.txid;
      _error = outcome.error;
      _statusMessage = outcome.statusMessage;
      _nothingBroadcast = nothingBroadcast;
    });
    unawaited(announceForAccessibility(context, _outcomeAnnouncement()));
  }

  String _outcomeAnnouncement() {
    return switch (_phase) {
      _NyctisStatusPhase.sending => nyctisSendPhaseText(_step),
      _NyctisStatusPhase.succeeded =>
        '$kNyctisStatusSentTitle. It counts once it is final.',
      _NyctisStatusPhase.pendingBroadcast =>
        '$kNyctisStatusPendingTitle. ${_statusMessage ?? ''}',
      _NyctisStatusPhase.failed =>
        '$kNyctisStatusFailedTitle. ${_error ?? ''}',
    };
  }

  void _leave() {
    if (_phase == _NyctisStatusPhase.sending) return;
    context.go(kNyctisStatusExitRoute);
  }

  /// Back to the review of the same plan, which quotes the fee and checks the
  /// plan's age again before Send is offered. Only reachable when nothing was
  /// broadcast.
  void _retry(NyctisSendReviewArgs args) {
    context.go(nyctisSendReviewRoute, extra: args.withQuotedFee(null));
  }

  String get _title => switch (_phase) {
    _NyctisStatusPhase.sending => kNyctisStatusSendingTitle,
    _NyctisStatusPhase.succeeded => kNyctisStatusSentTitle,
    _NyctisStatusPhase.pendingBroadcast => kNyctisStatusPendingTitle,
    _NyctisStatusPhase.failed => kNyctisStatusFailedTitle,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final args = widget.args;
    final isSending = _phase == _NyctisStatusPhase.sending;

    String networkName;
    try {
      networkName = ref.watch(
        nyctisConfigProvider.select((config) => config.networkName),
      );
    } catch (_) {
      networkName = 'main';
    }
    final currentTip = ref.watch(
      syncProvider.select((state) => state.value?.chainTipHeight ?? 0),
    );

    final failedText = _error == null
        ? null
        : (_nothingBroadcast && args != null
              ? '$_error $kNyctisStatusNothingSentText'
              : _error);
    final notice = switch (_phase) {
      _NyctisStatusPhase.sending => nyctisSendPhaseText(_step),
      _NyctisStatusPhase.succeeded => nyctisStatusSentText(
        kNyctisDefaultFinalityDepth,
        estimate: nyctisFinalityEstimateText(
          networkName,
          kNyctisDefaultFinalityDepth,
        ),
      ),
      _NyctisStatusPhase.pendingBroadcast => _statusMessage,
      _NyctisStatusPhase.failed => failedText,
    };
    final noticeTone = switch (_phase) {
      _NyctisStatusPhase.sending => NyctisMessageTone.neutral,
      _NyctisStatusPhase.succeeded => NyctisMessageTone.neutral,
      _NyctisStatusPhase.pendingBroadcast => NyctisMessageTone.warning,
      _NyctisStatusPhase.failed => NyctisMessageTone.error,
    };

    // Safe only when nothing reached the network and the plan can still be
    // applied; an expired plan has to be rebuilt from the asset instead.
    final canRetry =
        _phase == _NyctisStatusPhase.failed &&
        _nothingBroadcast &&
        args != null &&
        args.freshnessAt(currentTip) != NyctisPlanFreshness.expired;

    return PopScope<void>(
      // Never a plain pop: the screen below is the review of this very plan.
      // A back gesture after the send leaves for the assets list instead, and
      // during the send it does nothing — the send owns a proposal and this
      // wallet's ZEC inputs.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showTitle) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
              child: Semantics(
                header: true,
                liveRegion: true,
                child: Text(
                  _title,
                  key: const ValueKey('nyctis_status_title'),
                  style: AppTypography.headlineSmall.copyWith(
                    color: colors.text.accent,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
          ],
          if (notice != null) ...[
            NyctisMessageCard(
              key: ValueKey('nyctis_status_notice_${_phase.name}'),
              text: notice,
              width: kNyctisCardWidth,
              tone: noticeTone,
              loading: isSending,
              liveRegion: true,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (args != null) ...[
            // The one place the transaction hash can be copied: its row.
            NyctisFactsCard(
              key: const ValueKey('nyctis_status_receipt'),
              title: 'Payment',
              facts: buildNyctisSendReceiptFacts(args: args, txid: _txid),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          Center(
            child: canRetry
                ? ReviewButtonsStack(
                    primaryKey: const ValueKey('nyctis_status_retry_button'),
                    primaryLabel: kNyctisStatusRetryLabel,
                    onPrimaryPressed: () => _retry(args),
                    secondaryLabel: kNyctisStatusDoneLabel,
                    onSecondaryPressed: _leave,
                  )
                : AppButton(
                    key: const ValueKey('nyctis_status_done_button'),
                    minWidth: kNyctisSendButtonMinWidth,
                    onPressed: isSending ? null : _leave,
                    child: const Text(kNyctisStatusDoneLabel),
                  ),
          ),
          const SizedBox(height: AppSpacing.base),
        ],
      ),
    );
  }
}
