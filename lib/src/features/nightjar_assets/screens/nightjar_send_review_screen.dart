/// Desktop `/nightjar/send/review` — the last screen before any ZEC moves.
///
/// Three things live here that live nowhere else in the app:
///
/// * **The ZEC cost.** A Nightjar payment moves an asset nobody outside the
///   channel can see, but the memos carrying it are ordinary shielded outputs
///   to the *channel's* Zcash address and they cost real ZEC. The recipient
///   receives none of it. This is the one part of a Nightjar payment
///   denominated in ZEC and the only screen that can state it before it is
///   spent.
/// * **The plan's age.** The proof is anchored at the tree root of `tip − 10`,
///   and the channel keeps roughly [NightjarSendReviewArgs.anchorWindow]
///   blocks of anchors. A plan older than that is ignored with "unknown
///   anchor" *after* the ZEC has been spent, so an expired plan cannot be
///   sent from here — it has to be rebuilt.
/// * **What the payment actually is.** Base units, the recipient's Nightjar
///   address, the notes it consumes, and the message id the channel will know
///   it by.
///
/// [NightjarSendReviewBody] is the screen; the desktop shell and the mobile
/// chrome both wrap it.
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
import '../../../providers/nightjar_config_provider.dart';
import '../../../providers/sync_provider.dart';
import '../services/nightjar_send_flow.dart';
import '../widgets/nightjar_asset_row_data.dart';
import '../widgets/nightjar_assets_feed.dart';
import '../widgets/nightjar_facts_card.dart';

/// Where a built plan is reviewed. One place, so the composer and the router
/// cannot disagree about it.
const String nightjarSendReviewRoute = '/nightjar/send/review';

/// Where a confirmed plan is broadcast.
const String nightjarSendStatusRoute = '/nightjar/send/status';

const String kNightjarReviewTitle = 'Review Nightjar payment';
const String kNightjarReviewSendLabel = 'Send payment';
const String kNightjarReviewRebuildLabel = 'Rebuild payment';
const String kNightjarReviewRebuildingLabel = 'Rebuilding...';

/// Shown when the route is reached without a plan — a refresh, a deep link, a
/// restored window. There is nothing to review and nothing has been spent.
const String kNightjarReviewNoPlanText =
    'There is no Nightjar payment to review. Start again from the asset you '
    'want to send.';

/// The privacy line this screen owes the user about the ZEC half.
const String kNightjarReviewZecPrivacyNote =
    'The Zcash transaction is shielded, so its amounts and memos are private. '
    'What it shows anyone watching the channel is that somebody paid into it.';

/// The sentence that states the ZEC cost plainly.
///
/// Written out rather than left to a fee row because the row alone reads as a
/// network fee, and this is not one: it is value attached to each memo output
/// and paid to the channel, on top of the Zcash fee.
String nightjarReviewZecCostText(NightjarSendReviewArgs args) {
  final each = ZecAmount.fromZatoshi(args.memoValueZatoshi).fee;
  final total = ZecAmount.fromZatoshi(args.channelZatoshi).fee;
  final memos = args.memoCount == 1
      ? 'Its single memo is an ordinary shielded output'
      : 'Its ${formatGroupedInteger(args.memoCount)} memos are ordinary '
            'shielded outputs';
  return 'This payment costs ZEC. $memos to the channel, carrying $each '
      'each — $total in total, plus the Zcash network fee. That ZEC is paid '
      'to the channel, not to the recipient: they receive the asset and no '
      'ZEC.';
}

/// What the payment is, in the asset's own units.
List<NightjarAssetFactData> buildNightjarPaymentFacts(
  NightjarSendReviewArgs args,
) {
  final symbol = args.assetSymbol.trim();
  final suffix = symbol.isEmpty ? '' : ' $symbol';
  return [
    NightjarAssetFactData(
      label: 'Asset',
      value: args.assetName.trim().isNotEmpty
          ? args.assetName.trim()
          : (symbol.isNotEmpty
                ? symbol
                : truncateNightjarAssetId(args.assetId)),
      copyText: args.assetId,
    ),
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
      label: 'Change back to you',
      value: '${formatNightjarAmount(args.change, args.assetDecimals)}$suffix',
    ),
    NightjarAssetFactData(
      label: 'Notes spent',
      value: args.inputs == 1 ? '1 note' : '${args.inputs} notes',
    ),
  ];
}

/// The ZEC half: what it costs and where it goes.
List<NightjarAssetFactData> buildNightjarZecCostFacts(
  NightjarSendReviewArgs args,
) {
  return [
    NightjarAssetFactData(
      label: 'Memos',
      value: args.memoCount == 1
          ? '1 memo, one transaction'
          : '${formatGroupedInteger(args.memoCount)} memos, one transaction',
    ),
    NightjarAssetFactData(
      label: 'ZEC per memo',
      value: ZecAmount.fromZatoshi(args.memoValueZatoshi).fee.toString(),
    ),
    NightjarAssetFactData(
      label: 'ZEC to the channel',
      value: ZecAmount.fromZatoshi(args.channelZatoshi).fee.toString(),
    ),
    NightjarAssetFactData(label: 'Zcash network fee', value: 'Added on top'),
    NightjarAssetFactData(
      label: 'Channel address',
      value: truncatedAddress(args.channelAddress),
      copyText: args.channelAddress,
    ),
  ];
}

/// What the proof is anchored to, and what it cost to make.
List<NightjarAssetFactData> buildNightjarProofFacts(
  NightjarSendReviewArgs args,
) {
  return [
    NightjarAssetFactData(
      label: 'Message id',
      value: truncateNightjarAssetId(args.msgId),
      copyText: args.msgId,
    ),
    NightjarAssetFactData(
      label: 'Anchored at height',
      value: formatGroupedInteger(args.anchorHeight),
    ),
    NightjarAssetFactData(
      label: 'Built against tip',
      value: formatGroupedInteger(args.chainTip),
    ),
    NightjarAssetFactData(
      label: 'Body size',
      value: '${formatGroupedInteger(args.bodyBytes)} bytes',
    ),
    NightjarAssetFactData(
      label: 'Proved in',
      value: '${formatGroupedInteger(args.provedMs)} ms',
    ),
    NightjarAssetFactData(
      label: 'Verifying key',
      value: truncateNightjarAssetId(args.vkHash),
      copyText: args.vkHash,
    ),
  ];
}

class NightjarSendReviewScreen extends StatelessWidget {
  const NightjarSendReviewScreen({required this.args, super.key});

  /// Null when the route was reached without a plan.
  final NightjarSendReviewArgs? args;

  @override
  Widget build(BuildContext context) {
    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NightjarSendReviewPane(args: args),
      ),
    );
  }
}

/// The pane body without the sidebar, so it renders on its own in tests and
/// in Widgetbook.
class NightjarSendReviewPane extends StatelessWidget {
  const NightjarSendReviewPane({required this.args, super.key});

  final NightjarSendReviewArgs? args;

  @override
  Widget build(BuildContext context) {
    return AppPaneScrollScaffold(
      toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: kNightjarCardWidth,
          child: NightjarSendReviewBody(args: args),
        ),
      ),
    );
  }
}

/// The review itself, shared by the desktop pane and the mobile screen.
class NightjarSendReviewBody extends ConsumerStatefulWidget {
  const NightjarSendReviewBody({
    required this.args,
    this.showTitle = true,
    super.key,
  });

  final NightjarSendReviewArgs? args;
  final bool showTitle;

  @override
  ConsumerState<NightjarSendReviewBody> createState() =>
      _NightjarSendReviewBodyState();
}

class _NightjarSendReviewBodyState
    extends ConsumerState<NightjarSendReviewBody> {
  /// The plan on screen. Starts as the one the composer handed over and is
  /// replaced in place by Rebuild — the alternative is sending the user back
  /// to re-type an amount they have already confirmed once.
  NightjarSendReviewArgs? _args;
  NightjarBuildPhase? _phase;
  String? _error;

  bool get _isRebuilding => _phase != null;

  @override
  void initState() {
    super.initState();
    _args = widget.args;
  }

  @override
  void didUpdateWidget(NightjarSendReviewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.args, widget.args) && widget.args != null) {
      _args = widget.args;
    }
  }

  Future<void> _rebuild() async {
    final args = _args;
    if (args == null) return;
    setState(() {
      _phase = NightjarBuildPhase.readingChannel;
      _error = null;
    });
    final result = await buildNightjarPayPlan(
      ref,
      assetId: args.assetId,
      amount: args.amount,
      recipient: args.recipient,
      assetName: args.assetName,
      onPhase: (phase) {
        if (!mounted) return;
        setState(() => _phase = phase);
      },
    );
    if (!mounted) return;
    setState(() {
      _phase = null;
      if (result.plan != null) {
        _args = result.plan;
        _error = null;
      } else {
        _error = result.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final args = _args;
    if (args == null) {
      return const NightjarMessageCard(
        key: ValueKey('nightjar_review_no_plan'),
        text: kNightjarReviewNoPlanText,
        width: kNightjarCardWidth,
      );
    }

    // The wallet's own synced tip, not the one the plan was built against: the
    // whole point is to notice that the chain has moved on since.
    final currentTip = ref.watch(
      syncProvider.select((state) => state.value?.chainTipHeight ?? 0),
    );
    final channelAddress = ref.watch(
      nightjarConfigProvider.select((config) => config.channelAddress),
    );
    final freshness = args.freshnessAt(currentTip);
    final freshnessText = args.freshnessTextAt(currentTip);
    final expired = freshness == NightjarPlanFreshness.expired;

    // The plan carries the address its memos will be sent to. If settings have
    // been pointed at another channel since it was built, sending it would pay
    // one channel with a message proved against another's state.
    final channelChanged =
        channelAddress.isNotEmpty && channelAddress != args.channelAddress;

    final canSend = !_isRebuilding && !expired && !channelChanged;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTitle) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
            child: Text(
              kNightjarReviewTitle,
              key: const ValueKey('nightjar_review_title'),
              style: AppTypography.headlineSmall.copyWith(
                color: colors.text.accent,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.base),
        ],
        if (freshnessText != null) ...[
          NightjarMessageCard(
            key: const ValueKey('nightjar_review_freshness'),
            text: freshnessText,
            width: kNightjarCardWidth,
            tone: expired
                ? NightjarMessageTone.error
                : NightjarMessageTone.warning,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (channelChanged) ...[
          const NightjarMessageCard(
            key: ValueKey('nightjar_review_channel_changed'),
            text:
                'The Nightjar channel changed after this payment was built, so '
                'it would pay one channel with a message proved against '
                'another. Rebuild it.',
            width: kNightjarCardWidth,
            tone: NightjarMessageTone.error,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        NightjarFactsCard(
          key: const ValueKey('nightjar_review_payment'),
          title: 'Payment',
          facts: buildNightjarPaymentFacts(args),
        ),
        const SizedBox(height: AppSpacing.md),
        NightjarFactsCard(
          key: const ValueKey('nightjar_review_zec_cost'),
          title: 'What this costs in ZEC',
          facts: buildNightjarZecCostFacts(args),
          footnote: nightjarReviewZecCostText(args),
        ),
        const SizedBox(height: AppSpacing.md),
        NightjarFactsCard(
          key: const ValueKey('nightjar_review_proof'),
          title: 'Proof',
          facts: buildNightjarProofFacts(args),
          footnote: kNightjarReviewZecPrivacyNote,
        ),
        const SizedBox(height: AppSpacing.md),
        if (_phase != null) ...[
          NightjarMessageCard(
            key: const ValueKey('nightjar_review_progress'),
            text: nightjarRebuildPhaseText(_phase!),
            width: kNightjarCardWidth,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (_error != null) ...[
          NightjarMessageCard(
            key: const ValueKey('nightjar_review_error'),
            text: _error!,
            width: kNightjarCardWidth,
            tone: NightjarMessageTone.error,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Center(
          child: AppButton(
            key: const ValueKey('nightjar_review_send_button'),
            minWidth: 196,
            onPressed: canSend
                ? () => unawaited(
                    context.push(nightjarSendStatusRoute, extra: args),
                  )
                : null,
            child: const Text(kNightjarReviewSendLabel),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Center(
          child: AppButton(
            key: const ValueKey('nightjar_review_rebuild_button'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.secondary,
            onPressed: _isRebuilding ? null : () => unawaited(_rebuild()),
            child: Text(
              _isRebuilding
                  ? kNightjarReviewRebuildingLabel
                  : kNightjarReviewRebuildLabel,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.base),
      ],
    );
  }
}

/// Progress copy while a plan is rebuilt in place.
String nightjarRebuildPhaseText(NightjarBuildPhase phase) {
  return switch (phase) {
    NightjarBuildPhase.readingChannel => 'Reading the channel again...',
    NightjarBuildPhase.proving => 'Proving this payment again...',
  };
}
