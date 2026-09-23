/// Desktop `/nyctis/send/review` — the last screen before any ZEC moves.
///
/// Four things live here that live nowhere else in the app:
///
/// * **The ZEC cost, in full.** A Nyctis payment moves an asset nobody
///   outside the channel can see, but the memos carrying it are ordinary
///   shielded outputs to the *channel's* Zcash address and they cost real ZEC.
///   The recipient receives none of it. The review quotes the network fee by
///   proposing exactly the outputs the broadcast will, so it can show the
///   channel's share, the fee and the total before Send — and refuse, with the
///   reason, when this account cannot pay them.
/// * **The plan's age.** The proof is anchored at the tree root of `tip − 10`,
///   and the channel keeps roughly [NyctisSendReviewArgs.anchorWindow]
///   blocks of anchors. A plan older than that is ignored with "unknown
///   anchor" *after* the ZEC has been spent, so an expired plan cannot be
///   sent from here — Rebuild becomes the primary action.
/// * **Whether it was already sent.** A plan whose message id the wallet has
///   broadcast is never offered again: the second transaction would carry
///   identical memos and the channel would ignore it after its ZEC was spent.
/// * **What the payment actually is.** Base units, the recipient's full
///   Nyctis address to check character by character, the notes it
///   consumes, and the message id the channel will know it by.
///
/// [NyctisSendReviewBody] is the screen; the desktop shell and the mobile
/// chrome both wrap it.
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
import '../../../core/layout/app_form_factor.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/full_address_viewer.dart';
import '../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../core/widgets/review_buttons_stack.dart';
import '../../../core/widgets/review_wrap_card.dart';
import '../../../providers/nyctis_config_provider.dart';
import '../../../providers/sync_provider.dart';
import '../providers/nyctis_in_flight_send_provider.dart';
import '../providers/nyctis_send_readiness_provider.dart';
import '../services/nyctis_send_flow.dart';
import '../widgets/nyctis_asset_row_data.dart';
import '../widgets/nyctis_assets_feed.dart';
import '../widgets/nyctis_facts_card.dart';
import 'nyctis_send_chrome.dart';

/// Where a built plan is reviewed. One place, so the composer and the router
/// cannot disagree about it.
const String nyctisSendReviewRoute = '/nyctis/send/review';

/// Where a confirmed plan is broadcast.
const String nyctisSendStatusRoute = '/nyctis/send/status';

const String kNyctisReviewTitle = 'Review Nyctis payment';
const String kNyctisReviewSendLabel = 'Confirm & send';
const String kNyctisReviewCancelLabel = 'Cancel';
const String kNyctisReviewRebuildLabel = 'Rebuild payment';
const String kNyctisReviewRebuildingLabel = 'Rebuilding…';

/// Shown when the route is reached without a plan — a refresh, a deep link, a
/// restored window. There is nothing to review and nothing has been spent.
const String kNyctisReviewNoPlanText =
    'There is no Nyctis payment to review. Start again from the asset you '
    'want to send.';

/// Shown when this plan's message has already been broadcast.
const String kNyctisReviewAlreadySentText =
    'This payment was already sent. Sending it again would spend more ZEC on a '
    'message the channel ignores. Track it in Activity.';

/// Shown while the fee is being quoted.
const String kNyctisReviewQuotingText = 'Calculating…';

/// The privacy line this screen owes the user about the ZEC half.
const String kNyctisReviewZecPrivacyNote =
    'The Zcash transaction is shielded, so its amounts and memos are private. '
    'What it shows anyone watching the channel is that somebody paid into it.';

/// The sentence that states the ZEC cost plainly.
///
/// Written out rather than left to a fee row because the row alone reads as a
/// network fee, and most of it is not one: it is value attached to each memo
/// output and paid to the channel, on top of the Zcash fee.
String nyctisReviewZecCostText(
  NyctisSendReviewArgs args, {
  BigInt? feeZatoshi,
}) {
  final each = ZecAmount.fromZatoshi(args.memoValueZatoshi).fee;
  final total = ZecAmount.fromZatoshi(args.channelZatoshi).fee;
  final memos = args.memoCount == 1
      ? 'Its single memo is an ordinary shielded output'
      : 'Its ${formatGroupedInteger(args.memoCount)} memos are ordinary '
            'shielded outputs';
  final fee = feeZatoshi == null
      ? 'plus the Zcash network fee'
      : 'plus a ${ZecAmount.fromZatoshi(feeZatoshi).fee} network fee';
  return 'This payment costs ZEC. $memos to the channel, carrying $each '
      'each — $total in total, $fee. That ZEC is paid to the channel, not to '
      'the recipient: they receive the asset and no ZEC.';
}

/// What the payment is, in the asset's own units.
List<NyctisAssetFactData> buildNyctisPaymentFacts(NyctisSendReviewArgs args) {
  final symbol = args.assetSymbol.trim();
  final suffix = symbol.isEmpty ? '' : ' $symbol';
  return [
    NyctisAssetFactData(
      label: 'Asset',
      value: args.assetName.trim().isNotEmpty
          ? args.assetName.trim()
          : (symbol.isNotEmpty ? symbol : truncateNyctisAssetId(args.assetId)),
      copyText: args.assetId,
    ),
    NyctisAssetFactData(
      label: 'Amount',
      value: '${formatNyctisAmount(args.amount, args.assetDecimals)}$suffix',
    ),
    NyctisAssetFactData(
      label: 'Change back to you',
      value: '${formatNyctisAmount(args.change, args.assetDecimals)}$suffix',
    ),
    NyctisAssetFactData(
      label: 'Notes spent',
      value: args.inputs == 1 ? '1 note' : '${args.inputs} notes',
    ),
  ];
}

/// The ZEC half: what it costs and where it goes.
///
/// [quote] is null while the fee has not been asked for; a quote without a fee
/// says the fee could not be known, which the review states rather than
/// leaving a blank.
List<NyctisAssetFactData> buildNyctisZecCostFacts(
  NyctisSendReviewArgs args, {
  NyctisZecQuote? quote,
  bool quoting = false,
}) {
  final fee = quote?.feeZatoshi;
  final total = quote?.totalZatoshi;
  final pending = quoting || quote == null;
  return [
    NyctisAssetFactData(
      // The count alone: "one transaction" is the footnote's to say, and a
      // long value is what gets cut off first at large text sizes.
      label: 'Memos',
      value: formatGroupedInteger(args.memoCount),
    ),
    NyctisAssetFactData(
      label: 'ZEC per memo',
      value: ZecAmount.fromZatoshi(args.memoValueZatoshi).fee.toString(),
    ),
    NyctisAssetFactData(
      label: 'ZEC to the channel',
      value: ZecAmount.fromZatoshi(args.channelZatoshi).fee.toString(),
    ),
    NyctisAssetFactData(
      label: 'Network fee',
      value: fee != null
          ? ZecAmount.fromZatoshi(fee).fee.toString()
          : (pending ? kNyctisReviewQuotingText : 'Not available'),
    ),
    NyctisAssetFactData(
      label: 'Total ZEC',
      value: total != null
          ? ZecAmount.fromZatoshi(total).fee.toString()
          : (pending ? kNyctisReviewQuotingText : 'Not available'),
    ),
    NyctisAssetFactData(
      label: 'Channel address',
      value: truncatedAddress(args.channelAddress),
      copyText: args.channelAddress,
    ),
  ];
}

/// What the proof is anchored to, and what it cost to make.
List<NyctisAssetFactData> buildNyctisProofFacts(NyctisSendReviewArgs args) {
  return [
    NyctisAssetFactData(
      label: 'Message id',
      value: truncateNyctisAssetId(args.msgId),
      copyText: args.msgId,
    ),
    NyctisAssetFactData(
      label: 'Anchored at height',
      value: formatGroupedInteger(args.anchorHeight),
    ),
    NyctisAssetFactData(
      label: 'Built against tip',
      value: formatGroupedInteger(args.chainTip),
    ),
    NyctisAssetFactData(
      label: 'Body size',
      value: '${formatGroupedInteger(args.bodyBytes)} bytes',
    ),
    NyctisAssetFactData(
      label: 'Proved in',
      value: '${formatGroupedInteger(args.provedMs)} ms',
    ),
    NyctisAssetFactData(
      label: 'Verifying key',
      value: truncateNyctisAssetId(args.vkHash),
      copyText: args.vkHash,
    ),
  ];
}

class NyctisSendReviewScreen extends StatelessWidget {
  const NyctisSendReviewScreen({required this.args, super.key});

  /// Null when the route was reached without a plan.
  final NyctisSendReviewArgs? args;

  @override
  Widget build(BuildContext context) {
    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NyctisSendReviewPane(args: args),
      ),
    );
  }
}

/// The pane body without the sidebar, so it renders on its own in tests and
/// in Widgetbook.
class NyctisSendReviewPane extends StatefulWidget {
  const NyctisSendReviewPane({required this.args, super.key});

  final NyctisSendReviewArgs? args;

  @override
  State<NyctisSendReviewPane> createState() => _NyctisSendReviewPaneState();
}

class _NyctisSendReviewPaneState extends State<NyctisSendReviewPane> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return NyctisSendPaneFrame(
      busy: _busy,
      child: NyctisSendReviewBody(
        args: widget.args,
        onBusyChanged: (busy) {
          if (!mounted || busy == _busy) return;
          setState(() => _busy = busy);
        },
      ),
    );
  }
}

/// The recipient's full address, for checking character by character before
/// confirming — the truncated form hides exactly the middle a look-alike
/// address would differ in.
class NyctisRecipientCard extends StatelessWidget {
  const NyctisRecipientCard({required this.address, super.key});

  final String address;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final children = <Widget>[
      Semantics(
        header: true,
        child: Text(
          'To',
          style: AppTypography.labelLarge.copyWith(
            color: colors.text.secondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      const SizedBox(height: AppSpacing.xs),
      Semantics(
        label: 'Recipient Nyctis address',
        child: FullAddressText(address: address),
      ),
      const SizedBox(height: AppSpacing.xs),
      Text(
        'Check the whole address. A Nyctis payment cannot be reversed.',
        style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
      ),
      const SizedBox(height: AppSpacing.sm),
      Align(
        alignment: Alignment.centerLeft,
        child: FullAddressCopyButton(
          key: const ValueKey('nyctis_review_copy_recipient'),
          address: address,
          size: AppButtonSize.small,
        ),
      ),
    ];
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
    if (kAppFormFactor == AppFormFactor.mobile) {
      return MobileSurfaceCard(child: content);
    }
    return ReviewWrapCard(mainAxisSize: MainAxisSize.min, children: [content]);
  }
}

/// The review itself, shared by the desktop pane and the mobile screen.
class NyctisSendReviewBody extends ConsumerStatefulWidget {
  const NyctisSendReviewBody({
    required this.args,
    this.showTitle = true,
    this.onBusyChanged,
    super.key,
  });

  final NyctisSendReviewArgs? args;
  final bool showTitle;

  /// Fired when a rebuild starts and ends, so the chrome withholds its back
  /// control for the length of the proof.
  final ValueChanged<bool>? onBusyChanged;

  @override
  ConsumerState<NyctisSendReviewBody> createState() =>
      _NyctisSendReviewBodyState();
}

class _NyctisSendReviewBodyState extends ConsumerState<NyctisSendReviewBody> {
  /// The plan on screen. Starts as the one the composer handed over and is
  /// replaced in place by Rebuild — the alternative is sending the user back
  /// to re-type an amount they have already confirmed once.
  NyctisSendReviewArgs? _args;
  NyctisBuildPhase? _phase;
  String? _error;

  NyctisZecQuote? _quote;
  bool _quoting = false;

  /// Bumped per quote, so a slow quote for a plan that was since rebuilt
  /// cannot overwrite the new plan's figure.
  int _quoteGeneration = 0;

  bool get _isRebuilding => _phase != null;

  @override
  void initState() {
    super.initState();
    _args = widget.args;
    if (_args != null) _scheduleQuote();
  }

  @override
  void didUpdateWidget(NyctisSendReviewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.args, widget.args) && widget.args != null) {
      _args = widget.args;
      _scheduleQuote();
    }
  }

  void _scheduleQuote() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_requote());
    });
  }

  Future<void> _requote() async {
    final args = _args;
    if (args == null) return;
    final generation = ++_quoteGeneration;
    setState(() {
      _quoting = true;
      _quote = null;
    });
    NyctisZecQuote quote;
    try {
      quote = await ref.read(nyctisSendQuoterProvider)(args);
    } catch (error) {
      quote = NyctisZecQuote.failed(
        error: nyctisErrorText(error),
        channelZatoshi: args.channelZatoshi,
      );
    }
    if (!mounted || generation != _quoteGeneration) return;
    setState(() {
      _quoting = false;
      _quote = quote;
    });
    final error = quote.error;
    if (error != null) {
      unawaited(announceForAccessibility(context, error));
    }
  }

  void _setPhase(NyctisBuildPhase? phase) {
    final wasBusy = _isRebuilding;
    setState(() => _phase = phase);
    if (wasBusy != _isRebuilding) widget.onBusyChanged?.call(_isRebuilding);
    if (phase != null) {
      unawaited(
        announceForAccessibility(context, nyctisRebuildPhaseText(phase)),
      );
    }
  }

  Future<void> _rebuild() async {
    final args = _args;
    if (args == null || _isRebuilding) return;
    _error = null;
    _setPhase(NyctisBuildPhase.readingChannel);
    final result = await ref.read(nyctisPayPlanBuilderProvider)(
      assetId: args.assetId,
      amount: args.amount,
      recipient: args.recipient,
      assetName: args.assetName,
      onPhase: (phase) {
        if (!mounted) return;
        _setPhase(phase);
      },
    );
    if (!mounted) return;
    final plan = result.plan;
    if (plan != null) {
      _args = plan;
      _error = null;
      _setPhase(null);
      unawaited(announceForAccessibility(context, 'Payment rebuilt.'));
      unawaited(_requote());
    } else {
      _error = result.error;
      _setPhase(null);
      final error = result.error;
      if (error != null) {
        unawaited(
          announceForAccessibility(context, 'Payment not rebuilt. $error'),
        );
      }
    }
  }

  void _send(NyctisSendReviewArgs args) {
    final quote = _quote;
    if (quote == null || !quote.isReady) return;
    // `go`, not `push`: the review leaves the stack, so no back gesture or
    // back link can return to a live Send for a plan that is being broadcast.
    context.go(
      nyctisSendStatusRoute,
      extra: args.withQuotedFee(quote.feeZatoshi),
    );
  }

  void _cancel(NyctisSendReviewArgs? args) {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go(args == null ? '/nyctis' : '/nyctis/${args.assetId}');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final args = _args;
    if (args == null) {
      return const NyctisMessageCard(
        key: ValueKey('nyctis_review_no_plan'),
        text: kNyctisReviewNoPlanText,
        width: kNyctisCardWidth,
      );
    }

    // The wallet's own synced tip, not the one the plan was built against: the
    // whole point is to notice that the chain has moved on since.
    final currentTip = ref.watch(
      syncProvider.select((state) => state.value?.chainTipHeight ?? 0),
    );
    final channelAddress = ref.watch(
      nyctisConfigProvider.select((config) => config.channelAddress),
    );
    final alreadySent = ref.watch(
      nyctisInFlightSendsProvider.select(
        (sends) => sends.any((send) => send.msgId == args.msgId),
      ),
    );
    final block = alreadySent
        ? null
        : ref.watch(nyctisSendBlockProvider(args.assetId));
    final freshness = args.freshnessAt(currentTip);
    final freshnessText = args.freshnessTextAt(currentTip);
    final expired = freshness == NyctisPlanFreshness.expired;

    // The plan carries the address its memos will be sent to. If settings have
    // been pointed at another channel since it was built, sending it would pay
    // one channel with a message proved against another's state.
    final channelChanged =
        channelAddress.isNotEmpty && channelAddress != args.channelAddress;
    final needsRebuild = expired || channelChanged;

    final quote = _quote;
    // A ZEC shortfall is judged by the quote, which knows the real cost; the
    // composer's lower bound is not repeated here.
    final blocksSend = block != null && block.kind != NyctisSendBlockKind.zec;
    final canSend =
        !_isRebuilding &&
        !needsRebuild &&
        !alreadySent &&
        !blocksSend &&
        !_quoting &&
        quote != null &&
        quote.isReady;
    final canRebuild = !_isRebuilding && !alreadySent && !blocksSend;

    final VoidCallback? onPrimary = needsRebuild
        ? (canRebuild ? () => unawaited(_rebuild()) : null)
        : (canSend ? () => _send(args) : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTitle) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
            child: Semantics(
              header: true,
              child: Text(
                kNyctisReviewTitle,
                key: const ValueKey('nyctis_review_title'),
                style: AppTypography.headlineSmall.copyWith(
                  color: colors.text.accent,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.base),
        ],
        if (alreadySent) ...[
          const NyctisMessageCard(
            key: ValueKey('nyctis_review_already_sent'),
            text: kNyctisReviewAlreadySentText,
            width: kNyctisCardWidth,
            tone: NyctisMessageTone.warning,
            liveRegion: true,
          ),
          const SizedBox(height: AppSpacing.md),
        ] else if (blocksSend) ...[
          NyctisMessageCard(
            key: const ValueKey('nyctis_review_blocked'),
            text: block.text,
            width: kNyctisCardWidth,
            tone: NyctisMessageTone.warning,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (freshnessText != null && !alreadySent) ...[
          NyctisMessageCard(
            key: const ValueKey('nyctis_review_freshness'),
            text: freshnessText,
            width: kNyctisCardWidth,
            tone: expired ? NyctisMessageTone.error : NyctisMessageTone.warning,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (channelChanged) ...[
          const NyctisMessageCard(
            key: ValueKey('nyctis_review_channel_changed'),
            text:
                'The Nyctis channel changed after this payment was built, so '
                'it would pay one channel with a message proved against '
                'another. Rebuild it.',
            width: kNyctisCardWidth,
            tone: NyctisMessageTone.error,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        NyctisFactsCard(
          key: const ValueKey('nyctis_review_payment'),
          title: 'Payment',
          facts: buildNyctisPaymentFacts(args),
        ),
        const SizedBox(height: AppSpacing.md),
        NyctisRecipientCard(
          key: const ValueKey('nyctis_review_recipient'),
          address: args.recipient,
        ),
        const SizedBox(height: AppSpacing.md),
        NyctisFactsCard(
          key: const ValueKey('nyctis_review_zec_cost'),
          title: 'What this costs in ZEC',
          facts: buildNyctisZecCostFacts(args, quote: quote, quoting: _quoting),
          footnote: nyctisReviewZecCostText(
            args,
            feeZatoshi: quote?.feeZatoshi,
          ),
        ),
        if (quote?.error != null) ...[
          const SizedBox(height: AppSpacing.md),
          NyctisMessageCard(
            key: const ValueKey('nyctis_review_quote_error'),
            text: quote!.error!,
            width: kNyctisCardWidth,
            tone: NyctisMessageTone.error,
            liveRegion: true,
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        NyctisFactsCard(
          key: const ValueKey('nyctis_review_proof'),
          title: 'Proof',
          facts: buildNyctisProofFacts(args),
          footnote: kNyctisReviewZecPrivacyNote,
        ),
        const SizedBox(height: AppSpacing.md),
        if (_phase != null) ...[
          NyctisMessageCard(
            key: const ValueKey('nyctis_review_progress'),
            text: nyctisRebuildPhaseText(_phase!),
            width: kNyctisCardWidth,
            loading: true,
            liveRegion: true,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (_error != null) ...[
          NyctisMessageCard(
            key: const ValueKey('nyctis_review_error'),
            text: _error!,
            width: kNyctisCardWidth,
            tone: NyctisMessageTone.error,
            liveRegion: true,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Center(
          child: ReviewButtonsStack(
            primaryKey: ValueKey(
              needsRebuild
                  ? 'nyctis_review_rebuild_button'
                  : 'nyctis_review_send_button',
            ),
            primaryLabel: needsRebuild
                ? (_isRebuilding
                      ? kNyctisReviewRebuildingLabel
                      : kNyctisReviewRebuildLabel)
                : kNyctisReviewSendLabel,
            primaryLeadingIconName: needsRebuild ? null : AppIcons.plane,
            onPrimaryPressed: onPrimary,
            secondaryLabel: kNyctisReviewCancelLabel,
            onSecondaryPressed: _isRebuilding ? null : () => _cancel(args),
          ),
        ),
        // An ageing plan can still be sent, and can also be refreshed before
        // it runs out; a fresh one has nothing to gain from a second proof.
        if (!needsRebuild &&
            !alreadySent &&
            freshness == NyctisPlanFreshness.aging) ...[
          const SizedBox(height: AppSpacing.xs),
          Center(
            child: AppButton(
              key: const ValueKey('nyctis_review_rebuild_button'),
              size: AppButtonSize.small,
              variant: AppButtonVariant.secondary,
              onPressed: canRebuild ? () => unawaited(_rebuild()) : null,
              child: Text(
                _isRebuilding
                    ? kNyctisReviewRebuildingLabel
                    : kNyctisReviewRebuildLabel,
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.base),
      ],
    );
  }
}

/// Progress copy while a plan is rebuilt in place.
String nyctisRebuildPhaseText(NyctisBuildPhase phase) {
  return switch (phase) {
    NyctisBuildPhase.readingChannel => 'Reading the channel again…',
    NyctisBuildPhase.proving =>
      'Proving this payment again. This takes $kNyctisProvingEstimateText.',
  };
}
