/// Desktop `/nightjar/:assetId/send` — compose a Nightjar payment.
///
/// The composer is the cheap half: a recipient, an amount in base units, and
/// the two things that decide whether the button works at all — a proving key
/// this wallet actually has, and a balance this asset actually holds. Pressing
/// Review is the expensive half: it reads the channel, verifies every proof,
/// replays the state and proves the payment, which is seconds of work and
/// about 600 MB of peak memory. That is why the button says Review and not
/// Send: nothing has been spent when it comes back, and nothing is spent until
/// the review screen is confirmed.
///
/// [NightjarSendBody] is the whole screen; the desktop shell and the mobile
/// chrome both wrap it, so there is one composer and not two.
library;

import 'dart:async';

import 'package:flutter/services.dart' show TextInputAction, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_form_factor.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/mobile_text_field.dart';
import '../providers/nightjar_assets_view_provider.dart';
import '../providers/nightjar_proving_key_provider.dart';
import '../services/nightjar_send_flow.dart';
import '../widgets/nightjar_asset_row_data.dart';
import '../widgets/nightjar_asset_row_mapper.dart';
import '../widgets/nightjar_assets_feed.dart';
import '../widgets/nightjar_facts_card.dart';
import 'nightjar_send_review_screen.dart';

/// Title of the composer, and the label of the entry point that reaches it.
const String kNightjarSendTitle = 'Send Nightjar asset';

const String kNightjarSendRecipientLabel = 'Recipient Nightjar address';
const String kNightjarSendRecipientHint = 'njreg1...';
const String kNightjarSendAmountLabel = 'Amount';
const String kNightjarSendReviewLabel = 'Review payment';

/// Why the recipient field wants a Nightjar address and not a Zcash one.
const String kNightjarSendRecipientNote =
    'A Nightjar address has no Zcash receiver, so nothing on chain is '
    'addressed to the recipient. The payment travels inside memos that only '
    'they can open.';

/// What pressing Review is about to cost, said before it is pressed.
const String kNightjarSendProvingNote =
    'Reviewing verifies every proof on the channel and proves this payment '
    'locally. It takes a few seconds and a few hundred megabytes of memory. '
    'Nothing is sent and no ZEC is spent until you confirm the review.';

/// Progress copy for the one boundary Dart can actually see.
///
/// `nightjarBuildPay` replays, proves and frames behind a single FFI call that
/// returns once, so there is no honest way to show "proving 60%" — what is
/// reported is what is known: the network fetch finished, the proof started.
String nightjarBuildPhaseText(NightjarBuildPhase phase) {
  return switch (phase) {
    NightjarBuildPhase.readingChannel => 'Reading the channel...',
    NightjarBuildPhase.proving =>
      'Verifying every proof and proving this payment...',
  };
}

/// Sentence-case reason the entered amount cannot be used, or null.
String? nightjarSendAmountError({
  required String text,
  required int decimals,
  required BigInt balance,
  required String symbol,
}) {
  if (text.trim().isEmpty) return null;
  if (nightjarAmountHasTooManyDecimals(text, decimals)) {
    return decimals == 0
        ? 'This asset has no decimal places.'
        : 'This asset has $decimals decimal places.';
  }
  final amount = parseNightjarAmount(text, decimals);
  if (amount == null) return 'Enter an amount, for example 1.';
  if (amount <= BigInt.zero) return 'Enter an amount greater than zero.';
  if (amount > balance) {
    // Named, not just refused: the balance is on the same screen and a bare
    // "too much" reads as a bug when the number above it is larger.
    final held = formatNightjarAmount(balance, decimals);
    return symbol.isEmpty
        ? 'This wallet holds $held of this asset.'
        : 'This wallet holds $held $symbol.';
  }
  return null;
}

class NightjarSendScreen extends StatelessWidget {
  const NightjarSendScreen({required this.assetId, super.key});

  final String assetId;

  @override
  Widget build(BuildContext context) {
    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NightjarSendPane(assetId: assetId),
      ),
    );
  }
}

/// The pane body without the sidebar, so it renders on its own in tests and
/// in Widgetbook.
class NightjarSendPane extends StatelessWidget {
  const NightjarSendPane({required this.assetId, super.key});

  final String assetId;

  @override
  Widget build(BuildContext context) {
    return AppPaneScrollScaffold(
      toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: kNightjarCardWidth,
          child: NightjarSendBody(assetId: assetId),
        ),
      ),
    );
  }
}

/// The composer itself, shared by the desktop pane and the mobile screen.
class NightjarSendBody extends ConsumerStatefulWidget {
  const NightjarSendBody({
    required this.assetId,
    this.showTitle = true,
    super.key,
  });

  final String assetId;

  /// Desktop draws its own title; the mobile top nav already carries one.
  final bool showTitle;

  @override
  ConsumerState<NightjarSendBody> createState() => _NightjarSendBodyState();
}

class _NightjarSendBodyState extends ConsumerState<NightjarSendBody> {
  final _recipientController = TextEditingController();
  final _amountController = TextEditingController();
  final _recipientFocus = FocusNode();
  final _amountFocus = FocusNode();

  NightjarBuildPhase? _phase;
  String? _error;

  bool get _isBuilding => _phase != null;

  @override
  void dispose() {
    _recipientController.dispose();
    _amountController.dispose();
    _recipientFocus.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  Future<void> _review(NightjarAssetDetailData asset) async {
    final amount = parseNightjarAmount(_amountController.text, asset.decimals);
    if (amount == null || amount <= BigInt.zero) return;

    setState(() {
      _phase = NightjarBuildPhase.readingChannel;
      _error = null;
    });

    final result = await buildNightjarPayPlan(
      ref,
      assetId: asset.assetId,
      amount: amount,
      recipient: _recipientController.text,
      assetName: asset.name ?? '',
      onPhase: (phase) {
        if (!mounted) return;
        setState(() => _phase = phase);
      },
    );

    if (!mounted) return;
    final plan = result.plan;
    if (plan == null) {
      setState(() {
        _phase = null;
        _error = result.error;
      });
      return;
    }
    setState(() => _phase = null);
    // A plan starts ageing the moment it exists, so it is handed straight to
    // the review screen rather than parked here.
    await context.push(nightjarSendReviewRoute, extra: plan);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final view = resolveNightjarView(ref.watch(nightjarAssetsViewProvider));
    final asset = view?.assetById(widget.assetId);

    if (view == null) {
      return const NightjarMessageCard(
        key: ValueKey('nightjar_send_loading'),
        text: 'Loading Nightjar asset...',
        width: kNightjarCardWidth,
      );
    }
    if (asset == null) {
      final listError = nightjarListErrorText(view);
      return NightjarMessageCard(
        key: const ValueKey('nightjar_send_missing'),
        text: listError ?? nightjarUnknownAssetText(widget.assetId),
        width: kNightjarCardWidth,
        tone: listError == null
            ? NightjarMessageTone.neutral
            : nightjarListErrorTone(view),
      );
    }

    final symbol = (asset.symbol ?? '').trim();
    final unavailableReason = nightjarSendUnavailableReason(
      ref.watch(nightjarProvingKeyProvider),
    );
    final amountError = nightjarSendAmountError(
      text: _amountController.text,
      decimals: asset.decimals,
      balance: asset.balance,
      symbol: symbol,
    );
    final amount = parseNightjarAmount(_amountController.text, asset.decimals);
    final canReview =
        !_isBuilding &&
        unavailableReason == null &&
        amountError == null &&
        amount != null &&
        amount > BigInt.zero &&
        _recipientController.text.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTitle) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
            child: Text(
              kNightjarSendTitle,
              key: const ValueKey('nightjar_send_title'),
              style: AppTypography.headlineSmall.copyWith(
                color: colors.text.accent,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.base),
        ],
        NightjarFactsCardForAsset(asset: asset),
        const SizedBox(height: AppSpacing.md),
        _NightjarTextField(
          fieldKey: const ValueKey('nightjar_send_recipient_field'),
          label: kNightjarSendRecipientLabel,
          hintText: kNightjarSendRecipientHint,
          controller: _recipientController,
          focusNode: _recipientFocus,
          enabled: !_isBuilding,
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          kNightjarSendRecipientNote,
          style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
        ),
        const SizedBox(height: AppSpacing.md),
        _NightjarTextField(
          fieldKey: const ValueKey('nightjar_send_amount_field'),
          label: symbol.isEmpty
              ? kNightjarSendAmountLabel
              : '$kNightjarSendAmountLabel ($symbol)',
          hintText: '0',
          controller: _amountController,
          focusNode: _amountFocus,
          enabled: !_isBuilding,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          messageText: amountError,
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) {
            if (canReview) unawaited(_review(asset));
          },
        ),
        if (amountError != null && kAppFormFactor == AppFormFactor.mobile) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            amountError,
            key: const ValueKey('nightjar_send_amount_error'),
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.destructive,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        if (unavailableReason != null) ...[
          NightjarMessageCard(
            key: const ValueKey('nightjar_send_unavailable'),
            text: unavailableReason,
            width: kNightjarCardWidth,
            tone: NightjarMessageTone.warning,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (_phase != null) ...[
          NightjarMessageCard(
            key: const ValueKey('nightjar_send_progress'),
            text: nightjarBuildPhaseText(_phase!),
            width: kNightjarCardWidth,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (_error != null) ...[
          NightjarMessageCard(
            key: const ValueKey('nightjar_send_error'),
            text: _error!,
            width: kNightjarCardWidth,
            tone: NightjarMessageTone.error,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Text(
          kNightjarSendProvingNote,
          style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
        ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: AppButton(
            key: const ValueKey('nightjar_send_review_button'),
            minWidth: 196,
            onPressed: canReview ? () => unawaited(_review(asset)) : null,
            child: Text(
              _isBuilding ? 'Preparing...' : kNightjarSendReviewLabel,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.base),
      ],
    );
  }
}

/// The holding this payment will come out of, as the shared facts card.
class NightjarFactsCardForAsset extends StatelessWidget {
  const NightjarFactsCardForAsset({required this.asset, super.key});

  final NightjarAssetDetailData asset;

  @override
  Widget build(BuildContext context) {
    return NightjarFactsCard(
      key: const ValueKey('nightjar_send_holding'),
      title: nightjarAssetDetailTitle(asset),
      facts: buildNightjarWalletHoldingFacts(asset),
    );
  }
}

/// One text field in whichever shape this form factor uses. The two are not
/// interchangeable widgets — desktop's carries its own label, mobile's does
/// not — so the branch is here rather than in every caller.
class _NightjarTextField extends StatelessWidget {
  const _NightjarTextField({
    required this.fieldKey,
    required this.label,
    required this.controller,
    required this.focusNode,
    this.hintText,
    this.enabled = true,
    this.keyboardType,
    this.messageText,
    this.onChanged,
    this.onSubmitted,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? hintText;
  final bool enabled;
  final TextInputType? keyboardType;
  final String? messageText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    if (kAppFormFactor == AppFormFactor.mobile) {
      final colors = context.colors;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
            child: Text(
              label,
              style: AppTypography.labelLarge.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ),
          MobileTextField(
            key: fieldKey,
            hintText: hintText,
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            keyboardType: keyboardType,
            textInputAction: TextInputAction.done,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          ),
        ],
      );
    }
    return AppTextField(
      key: fieldKey,
      label: label,
      hintText: hintText,
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      keyboardType: keyboardType,
      textInputAction: TextInputAction.done,
      messageText: messageText,
      tone: messageText == null
          ? AppTextFieldTone.neutral
          : AppTextFieldTone.destructive,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}
