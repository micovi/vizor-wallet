/// Desktop `/nightjar/send/status` — the broadcast leg and its receipt.
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

import '../../../core/formatting/address_display.dart';
import '../../../core/formatting/number_format.dart';
import '../../../core/formatting/zec_amount.dart';
import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_copy_feedback.dart';
import '../providers/nightjar_assets_view_provider.dart';
import '../services/nightjar_send_flow.dart';
import '../widgets/nightjar_asset_row_data.dart';
import '../widgets/nightjar_assets_feed.dart';
import '../widgets/nightjar_facts_card.dart';

/// The runner the screen drives. Swapped in tests, which cannot reach Rust.
typedef NightjarSendBroadcastRunner =
    Future<NightjarSendOutcome> Function({
      required WidgetRef ref,
      required NightjarSendReviewArgs args,
      void Function(NightjarSendPhase phase)? onPhase,
      Future<bool> Function()? shouldAbort,
    });

const String kNightjarStatusSendingTitle = 'Sending Nightjar payment';
const String kNightjarStatusSentTitle = 'Payment sent';
const String kNightjarStatusPendingTitle = 'Payment not on the network yet';
const String kNightjarStatusFailedTitle = 'Payment not sent';
const String kNightjarStatusDoneLabel = 'Back to Nightjar assets';

/// Shown when the route is reached without a plan. Nothing was proposed and
/// nothing was spent.
const String kNightjarStatusNoPlanText =
    'There is no Nightjar payment in progress. Start again from the asset you '
    'want to send.';

/// What a broadcast actually bought, said precisely.
///
/// The transaction is on the network; the channel has not applied anything
/// yet and will not until the block carrying it is final. Saying "sent" and
/// leaving it there is what makes a recipient's empty balance look like a bug.
String nightjarStatusSentText(int finalityDepth) =>
    'The transaction carrying this payment is on the network. Every wallet on '
    'the channel — including the recipient’s — applies it once that '
    'transaction is $finalityDepth blocks deep, so it will not appear in a '
    'balance before then.';

/// Phase copy for the two steps this screen genuinely knows about.
String nightjarSendPhaseText(NightjarSendPhase phase) {
  return switch (phase) {
    NightjarSendPhase.proposing => 'Choosing ZEC inputs for the memos...',
    NightjarSendPhase.broadcasting =>
      'Signing and broadcasting one transaction...',
  };
}

/// The receipt's facts: what the transaction carried, and what it cost.
List<NightjarAssetFactData> buildNightjarSendReceiptFacts({
  required NightjarSendReviewArgs args,
  String? txid,
}) {
  final symbol = args.assetSymbol.trim();
  final suffix = symbol.isEmpty ? '' : ' $symbol';
  return [
    NightjarAssetFactData(
      label: 'Amount',
      value: '${formatNightjarAmount(args.amount, args.assetDecimals)}$suffix',
    ),
    NightjarAssetFactData(
      label: 'To',
      value: truncatedAddress(args.recipient),
      copyText: args.recipient,
    ),
    NightjarAssetFactData(
      label: 'ZEC to the channel',
      value: ZecAmount.fromZatoshi(args.channelZatoshi).fee.toString(),
    ),
    NightjarAssetFactData(
      label: 'Memos',
      value: args.memoCount == 1
          ? '1 memo, one transaction'
          : '${formatGroupedInteger(args.memoCount)} memos, one transaction',
    ),
    NightjarAssetFactData(
      label: 'Message id',
      value: truncateNightjarAssetId(args.msgId),
      copyText: args.msgId,
    ),
    if (txid != null)
      NightjarAssetFactData(
        label: 'Transaction',
        value: truncatedTxid(txid),
        copyText: txid,
      ),
  ];
}

class NightjarSendStatusScreen extends StatelessWidget {
  const NightjarSendStatusScreen({
    required this.args,
    this.broadcastRunner,
    super.key,
  });

  /// Null when the route was reached without a plan.
  final NightjarSendReviewArgs? args;

  @visibleForTesting
  final NightjarSendBroadcastRunner? broadcastRunner;

  @override
  Widget build(BuildContext context) {
    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NightjarSendStatusPane(
          args: args,
          broadcastRunner: broadcastRunner,
        ),
      ),
    );
  }
}

/// The pane body without the sidebar, so it renders on its own in tests and
/// in Widgetbook.
class NightjarSendStatusPane extends StatelessWidget {
  const NightjarSendStatusPane({
    required this.args,
    this.broadcastRunner,
    super.key,
  });

  final NightjarSendReviewArgs? args;

  @visibleForTesting
  final NightjarSendBroadcastRunner? broadcastRunner;

  @override
  Widget build(BuildContext context) {
    return AppPaneScrollScaffold(
      toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: kNightjarCardWidth,
          child: NightjarSendStatusBody(
            args: args,
            broadcastRunner: broadcastRunner,
          ),
        ),
      ),
    );
  }
}

enum _NightjarStatusPhase { sending, succeeded, pendingBroadcast, failed }

/// The broadcast and its receipt, shared by the desktop pane and the mobile
/// screen.
class NightjarSendStatusBody extends ConsumerStatefulWidget {
  const NightjarSendStatusBody({
    required this.args,
    this.showTitle = true,
    this.broadcastRunner,
    this.onSendingChanged,
    super.key,
  });

  final NightjarSendReviewArgs? args;
  final bool showTitle;

  /// Fired when the broadcast starts and when it ends. The mobile chrome uses
  /// it to withhold its back arrow while a proposal is live, which the desktop
  /// pane gets from the `PopScope` below.
  final void Function(bool isSending)? onSendingChanged;

  @visibleForTesting
  final NightjarSendBroadcastRunner? broadcastRunner;

  @override
  ConsumerState<NightjarSendStatusBody> createState() =>
      _NightjarSendStatusBodyState();
}

class _NightjarSendStatusBodyState
    extends ConsumerState<NightjarSendStatusBody> {
  _NightjarStatusPhase _phase = _NightjarStatusPhase.sending;
  NightjarSendPhase _step = NightjarSendPhase.proposing;
  String? _txid;
  String? _error;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    if (widget.args == null) {
      _phase = _NightjarStatusPhase.failed;
      _error = kNightjarStatusNoPlanText;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onSendingChanged?.call(true);
      unawaited(_send());
    });
  }

  Future<void> _send() async {
    final args = widget.args;
    if (args == null) return;
    final runner = widget.broadcastRunner ?? runNightjarSendBroadcast;
    final outcome = await runner(
      ref: ref,
      args: args,
      onPhase: (step) {
        if (!mounted) return;
        setState(() => _step = step);
      },
      // Leaving the screen mid-flight releases the proposal rather than
      // leaving this wallet's ZEC inputs locked until the proposal expires.
      shouldAbort: () async => !mounted,
    );
    if (!mounted) return;
    widget.onSendingChanged?.call(false);
    if (outcome.phase == NightjarSendOutcomePhase.aborted) return;

    // Not because the balance has changed — it has not, and will not until
    // the block carrying this is final — but because the channel now carries
    // one more message above the finality cut-off, and the assets screen's
    // notice is what turns "my balance did not move" into an explanation.
    if (outcome.phase != NightjarSendOutcomePhase.failed) {
      ref.invalidate(nightjarAssetsViewProvider);
    }

    setState(() {
      _phase = switch (outcome.phase) {
        NightjarSendOutcomePhase.succeeded => _NightjarStatusPhase.succeeded,
        NightjarSendOutcomePhase.pendingBroadcast =>
          _NightjarStatusPhase.pendingBroadcast,
        NightjarSendOutcomePhase.failed ||
        NightjarSendOutcomePhase.aborted => _NightjarStatusPhase.failed,
      };
      _txid = outcome.txid;
      _error = outcome.error;
      _statusMessage = outcome.statusMessage;
    });
  }

  void _copyTxid() {
    final txid = _txid;
    if (txid == null) return;
    copyTextWithToast(
      context,
      text: txid,
      toastMessage: 'Transaction hash copied',
    );
  }

  String get _title => switch (_phase) {
    _NightjarStatusPhase.sending => kNightjarStatusSendingTitle,
    _NightjarStatusPhase.succeeded => kNightjarStatusSentTitle,
    _NightjarStatusPhase.pendingBroadcast => kNightjarStatusPendingTitle,
    _NightjarStatusPhase.failed => kNightjarStatusFailedTitle,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final args = widget.args;
    final isSending = _phase == _NightjarStatusPhase.sending;

    final notice = switch (_phase) {
      _NightjarStatusPhase.sending => nightjarSendPhaseText(_step),
      _NightjarStatusPhase.succeeded => nightjarStatusSentText(
        kNightjarDefaultFinalityDepth,
      ),
      _NightjarStatusPhase.pendingBroadcast => _statusMessage,
      _NightjarStatusPhase.failed => _error,
    };
    final noticeTone = switch (_phase) {
      _NightjarStatusPhase.sending => NightjarMessageTone.neutral,
      _NightjarStatusPhase.succeeded => NightjarMessageTone.neutral,
      _NightjarStatusPhase.pendingBroadcast => NightjarMessageTone.warning,
      _NightjarStatusPhase.failed => NightjarMessageTone.error,
    };

    return PopScope<void>(
      // A send that is still in flight owns a proposal and this wallet's ZEC
      // inputs. Popping is allowed once it is over and not before.
      canPop: !isSending,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showTitle) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
              child: Text(
                _title,
                key: const ValueKey('nightjar_status_title'),
                style: AppTypography.headlineSmall.copyWith(
                  color: colors.text.accent,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
          ],
          if (notice != null) ...[
            NightjarMessageCard(
              key: ValueKey('nightjar_status_notice_${_phase.name}'),
              text: notice,
              width: kNightjarCardWidth,
              tone: noticeTone,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (args != null) ...[
            NightjarFactsCard(
              key: const ValueKey('nightjar_status_receipt'),
              title: 'Payment',
              facts: buildNightjarSendReceiptFacts(args: args, txid: _txid),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_txid != null) ...[
            Center(
              child: AppButton(
                key: const ValueKey('nightjar_status_copy_txid'),
                size: AppButtonSize.small,
                variant: AppButtonVariant.ghost,
                onPressed: _copyTxid,
                child: const Text('Copy transaction hash'),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
          Center(
            child: AppButton(
              key: const ValueKey('nightjar_status_done_button'),
              minWidth: 196,
              onPressed: isSending ? null : () => context.go('/nightjar'),
              child: const Text(kNightjarStatusDoneLabel),
            ),
          ),
          const SizedBox(height: AppSpacing.base),
        ],
      ),
    );
  }
}
