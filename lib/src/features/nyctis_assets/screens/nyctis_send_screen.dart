/// Desktop `/nyctis/:assetId/send` — compose a Nyctis payment.
///
/// The composer is the cheap half: a recipient, an amount in base units, and
/// everything that decides whether the button works at all — an account that
/// can prove, a proving key this wallet actually has, no earlier payment of
/// this asset still settling, enough ZEC to carry a message, a balance this
/// asset actually holds, and an address that is a Nyctis address on this
/// network. Every one of those is checked here, before Review. Pressing
/// Review is the expensive half: it reads the channel, verifies every proof,
/// replays the state and proves the payment, which is seconds of work and
/// about 600 MB of peak memory. That is why the button says Review and not
/// Send: nothing has been spent when it comes back, and nothing is spent until
/// the review screen is confirmed.
///
/// [NyctisSendBody] is the whole screen; the desktop shell and the mobile
/// chrome both wrap it, so there is one composer and not two.
library;

import 'dart:async';

import 'package:flutter/services.dart'
    show
        Clipboard,
        TextEditingValue,
        TextInputAction,
        TextInputFormatter,
        TextInputType,
        TextSelection;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feedback/app_announce.dart';
import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_form_factor.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/comma_to_dot_input_formatter.dart';
import '../../../core/widgets/mobile_text_field.dart';
import '../../../providers/nyctis_config_provider.dart';
import '../providers/nyctis_assets_view_provider.dart';
import '../providers/nyctis_send_readiness_provider.dart';
import '../services/nyctis_address.dart';
import '../services/nyctis_send_flow.dart';
import '../widgets/nyctis_asset_row_data.dart';
import '../widgets/nyctis_asset_row_mapper.dart';
import '../widgets/nyctis_assets_feed.dart';
import '../widgets/nyctis_facts_card.dart';
import 'nyctis_send_chrome.dart';
import 'nyctis_send_review_screen.dart';

/// Title of the composer, and the label of the entry point that reaches it.
const String kNyctisSendTitle = 'Send Nyctis asset';

const String kNyctisSendRecipientLabel = 'Recipient Nyctis address';
const String kNyctisSendAmountLabel = 'Amount';
const String kNyctisSendReviewLabel = 'Review payment';
const String kNyctisSendPreparingLabel = 'Preparing…';
const String kNyctisSendPasteLabel = 'Paste';
const String kNyctisSendMaxLabel = 'Use max';

/// Placeholder for the recipient field on [networkName]: the network's own
/// prefix, never another network's.
String nyctisSendRecipientHint(String networkName) =>
    nyctisAddressHint(networkName);

/// Why the recipient field wants a Nyctis address and not a Zcash one.
const String kNyctisSendRecipientNote =
    'A Nyctis address has no Zcash receiver, so nothing on chain is '
    'addressed to the recipient. The payment travels inside memos that only '
    'they can open.';

/// What pressing Review is about to cost, said before it is pressed.
const String kNyctisSendProvingNote =
    'Reviewing verifies every proof on the channel and proves this payment '
    'on this device — $kNyctisProvingEstimateText, and a few hundred '
    'megabytes of memory. Nothing is sent and no ZEC is spent until you '
    'confirm the review.';

/// Label of the action beside a blocker that is fixed in settings.
const String kNyctisOpenSettingsLabel = 'Open Nyctis settings';

/// Where that action goes.
const String kNyctisSettingsRoute = '/settings/nyctis';

/// Progress copy for the one boundary Dart can actually see.
///
/// `nyctisBuildPay` replays, proves and frames behind a single FFI call that
/// returns once, so there is no honest way to show "proving 60%" — what is
/// reported is what is known: the network fetch finished, the proof started.
String nyctisBuildPhaseText(NyctisBuildPhase phase) {
  return switch (phase) {
    NyctisBuildPhase.readingChannel => 'Reading the channel…',
    NyctisBuildPhase.proving =>
      'Verifying every proof and proving this payment. This takes '
          '$kNyctisProvingEstimateText.',
  };
}

/// Sentence-case reason the entered amount cannot be used, or null.
String? nyctisSendAmountError({
  required String text,
  required int decimals,
  required BigInt balance,
  required String symbol,
}) {
  if (text.trim().isEmpty) return null;
  if (nyctisAmountHasTooManyDecimals(text, decimals)) {
    return decimals == 0
        ? 'This asset has no decimal places.'
        : 'This asset has $decimals decimal places.';
  }
  final amount = parseNyctisAmount(text, decimals);
  if (amount == null) return 'Enter an amount, for example 1.';
  if (amount <= BigInt.zero) return 'Enter an amount greater than zero.';
  if (amount > balance) {
    // Named, not just refused: the balance is on the same screen and a bare
    // "too much" reads as a bug when the number above it is larger.
    final held = formatNyctisAmount(balance, decimals);
    return symbol.isEmpty
        ? 'This wallet holds $held of this asset.'
        : 'This wallet holds $held $symbol.';
  }
  return null;
}

/// The most one payment of [asset] can move.
///
/// The circuit consumes at most two notes, so the ceiling is the two largest
/// unspent notes together, not the balance. Falls back to the balance when the
/// view carries no notes to add up.
BigInt nyctisMaxSendable(NyctisAssetDetailData asset) {
  final unspent = [
    for (final note in asset.notes)
      if (!note.spent && note.amount > BigInt.zero) note.amount,
  ]..sort((a, b) => b.compareTo(a));
  if (unspent.isEmpty) return asset.balance;
  final top = unspent.take(2).fold(BigInt.zero, (sum, next) => sum + next);
  return top < asset.balance ? top : asset.balance;
}

/// Said under the amount when [nyctisMaxSendable] is below the balance, so
/// "Use max" filling a smaller number than the one on the card is explained.
String nyctisTwoNoteLimitText(NyctisAssetDetailData asset, BigInt max) {
  final symbol = (asset.symbol ?? '').trim();
  final amount = formatNyctisAmount(max, asset.decimals);
  return 'One payment can spend at most two of your notes, so the most you '
      'can send at once is ${symbol.isEmpty ? amount : '$amount $symbol'}.';
}

class NyctisSendScreen extends StatelessWidget {
  const NyctisSendScreen({required this.assetId, super.key});

  final String assetId;

  @override
  Widget build(BuildContext context) {
    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NyctisSendPane(assetId: assetId),
      ),
    );
  }
}

/// The pane body without the sidebar, so it renders on its own in tests and
/// in Widgetbook.
class NyctisSendPane extends StatefulWidget {
  const NyctisSendPane({required this.assetId, super.key});

  final String assetId;

  @override
  State<NyctisSendPane> createState() => _NyctisSendPaneState();
}

class _NyctisSendPaneState extends State<NyctisSendPane> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return NyctisSendPaneFrame(
      busy: _busy,
      child: NyctisSendBody(
        assetId: widget.assetId,
        onBusyChanged: (busy) {
          if (!mounted || busy == _busy) return;
          setState(() => _busy = busy);
        },
      ),
    );
  }
}

/// The composer itself, shared by the desktop pane and the mobile screen.
class NyctisSendBody extends ConsumerStatefulWidget {
  const NyctisSendBody({
    required this.assetId,
    this.showTitle = true,
    this.onBusyChanged,
    super.key,
  });

  final String assetId;

  /// Desktop draws its own title; the mobile top nav already carries one.
  final bool showTitle;

  /// Fired when a proof starts and when it ends, so the chrome can withhold
  /// its back control: leaving mid-proof throws the plan away and leaves the
  /// native call running for nothing.
  final ValueChanged<bool>? onBusyChanged;

  @override
  ConsumerState<NyctisSendBody> createState() => _NyctisSendBodyState();
}

class _NyctisSendBodyState extends ConsumerState<NyctisSendBody> {
  final _recipientController = TextEditingController();
  final _amountController = TextEditingController();
  final _recipientFocus = FocusNode();
  final _amountFocus = FocusNode();

  NyctisBuildPhase? _phase;
  String? _error;

  /// Whether the recipient has been finished with — left, pasted, or
  /// submitted — so its format error may show. An address typed a character
  /// at a time is invalid until its last character, and saying so on every
  /// keystroke is noise; Review stays disabled either way.
  bool _recipientChecked = false;

  bool get _isBuilding => _phase != null;

  @override
  void initState() {
    super.initState();
    _recipientFocus.addListener(_onRecipientFocusChanged);
  }

  void _onRecipientFocusChanged() {
    if (_recipientFocus.hasFocus || _recipientChecked) return;
    if (_recipientController.text.trim().isEmpty) return;
    setState(() => _recipientChecked = true);
  }

  @override
  void dispose() {
    _recipientFocus.removeListener(_onRecipientFocusChanged);
    _recipientController.dispose();
    _amountController.dispose();
    _recipientFocus.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  void _setPhase(NyctisBuildPhase? phase) {
    final wasBuilding = _isBuilding;
    setState(() => _phase = phase);
    if (wasBuilding != _isBuilding) widget.onBusyChanged?.call(_isBuilding);
    if (phase != null) {
      unawaited(
        announceForAccessibility(context, nyctisBuildPhaseText(phase)),
      );
    }
  }

  Future<void> _review(NyctisAssetDetailData asset) async {
    // Two Enter presses before the rebuild would otherwise start two proofs,
    // each about 600 MB at peak.
    if (_isBuilding) return;
    final amount = parseNyctisAmount(_amountController.text, asset.decimals);
    if (amount == null || amount <= BigInt.zero) return;

    _error = null;
    _setPhase(NyctisBuildPhase.readingChannel);

    final result = await ref.read(nyctisPayPlanBuilderProvider)(
      assetId: asset.assetId,
      amount: amount,
      recipient: _recipientController.text,
      assetName: asset.name ?? '',
      onPhase: (phase) {
        if (!mounted) return;
        _setPhase(phase);
      },
    );

    if (!mounted) return;
    final plan = result.plan;
    if (plan == null) {
      _error = result.error;
      _setPhase(null);
      final error = result.error;
      if (error != null) {
        unawaited(
          announceForAccessibility(context, 'Payment not prepared. $error'),
        );
      }
      return;
    }
    _setPhase(null);
    // A plan starts ageing the moment it exists, so it is handed straight to
    // the review screen rather than parked here.
    await context.push(nyctisSendReviewRoute, extra: plan);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final pasted = data?.text?.trim() ?? '';
    if (pasted.isEmpty || !mounted) return;
    _recipientController.value = TextEditingValue(
      text: pasted,
      selection: TextSelection.collapsed(offset: pasted.length),
    );
    setState(() {
      _error = null;
      _recipientChecked = true;
    });
  }

  void _useMax(NyctisAssetDetailData asset) {
    final text = formatNyctisAmount(
      nyctisMaxSendable(asset),
      asset.decimals,
    ).replaceAll(',', '');
    _amountController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final view = resolveNyctisView(ref.watch(nyctisAssetsViewProvider));
    final asset = view?.assetById(widget.assetId);

    if (view == null) {
      return const NyctisMessageCard(
        key: ValueKey('nyctis_send_loading'),
        text: 'Loading Nyctis asset…',
        width: kNyctisCardWidth,
        loading: true,
      );
    }
    if (asset == null) {
      final listError = nyctisListErrorText(view);
      return NyctisMessageCard(
        key: const ValueKey('nyctis_send_missing'),
        text: listError ?? nyctisUnknownAssetText(widget.assetId),
        width: kNyctisCardWidth,
        tone: listError == null
            ? NyctisMessageTone.neutral
            : nyctisListErrorTone(view),
      );
    }

    String networkName;
    try {
      networkName = ref.watch(
        nyctisConfigProvider.select((config) => config.networkName),
      );
    } catch (_) {
      networkName = 'main';
    }

    final symbol = (asset.symbol ?? '').trim();
    final block = ref.watch(nyctisSendBlockProvider(asset.assetId));
    final recipientText = _recipientController.text;
    final recipientError = nyctisRecipientError(
      recipientText,
      networkName: networkName,
    );
    final amountError = nyctisSendAmountError(
      text: _amountController.text,
      decimals: asset.decimals,
      balance: asset.balance,
      symbol: symbol,
    );
    final amount = parseNyctisAmount(_amountController.text, asset.decimals);
    final maxSendable = nyctisMaxSendable(asset);
    final canReview =
        !_isBuilding &&
        block == null &&
        amountError == null &&
        recipientError == null &&
        amount != null &&
        amount > BigInt.zero &&
        recipientText.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTitle) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
            child: Semantics(
              header: true,
              child: Text(
                kNyctisSendTitle,
                key: const ValueKey('nyctis_send_title'),
                style: AppTypography.headlineSmall.copyWith(
                  color: colors.text.accent,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.base),
        ],
        NyctisFactsCardForAsset(asset: asset),
        const SizedBox(height: AppSpacing.md),
        if (block != null) ...[
          NyctisSendBlockNotice(
            key: const ValueKey('nyctis_send_unavailable'),
            block: block,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        NyctisSendTextField(
          fieldKey: const ValueKey('nyctis_send_recipient_field'),
          label: kNyctisSendRecipientLabel,
          hintText: nyctisSendRecipientHint(networkName),
          controller: _recipientController,
          focusNode: _recipientFocus,
          enabled: !_isBuilding,
          textInputAction: TextInputAction.next,
          messageText: _recipientChecked ? recipientError : null,
          errorKey: const ValueKey('nyctis_send_recipient_error'),
          trailing: AppButton(
            key: const ValueKey('nyctis_send_paste_button'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.secondary,
            onPressed: _isBuilding ? null : () => unawaited(_paste()),
            leading: const AppIcon(AppIcons.paste),
            child: const Text(kNyctisSendPasteLabel),
          ),
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) {
            setState(() => _recipientChecked = true);
            _amountFocus.requestFocus();
          },
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          kNyctisSendRecipientNote,
          style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
        ),
        const SizedBox(height: AppSpacing.md),
        NyctisSendTextField(
          fieldKey: const ValueKey('nyctis_send_amount_field'),
          label: symbol.isEmpty
              ? kNyctisSendAmountLabel
              : '$kNyctisSendAmountLabel ($symbol)',
          hintText: '0',
          controller: _amountController,
          focusNode: _amountFocus,
          enabled: !_isBuilding,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          // A decimal comma is a decimal point. Without this, "1,5" typed on a
          // comma-decimal keypad parsed as 15.
          inputFormatters: const [CommaToDotInputFormatter()],
          messageText: amountError,
          errorKey: const ValueKey('nyctis_send_amount_error'),
          trailing: AppButton(
            key: const ValueKey('nyctis_send_max_button'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.ghost,
            onPressed: _isBuilding || maxSendable <= BigInt.zero
                ? null
                : () => _useMax(asset),
            child: const Text(kNyctisSendMaxLabel),
          ),
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) {
            if (canReview) unawaited(_review(asset));
          },
        ),
        if (maxSendable < asset.balance) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            nyctisTwoNoteLimitText(asset, maxSendable),
            key: const ValueKey('nyctis_send_two_note_limit'),
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        if (_phase != null) ...[
          NyctisMessageCard(
            key: const ValueKey('nyctis_send_progress'),
            text: nyctisBuildPhaseText(_phase!),
            width: kNyctisCardWidth,
            loading: true,
            liveRegion: true,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (_error != null) ...[
          NyctisMessageCard(
            key: const ValueKey('nyctis_send_error'),
            text: _error!,
            width: kNyctisCardWidth,
            tone: NyctisMessageTone.error,
            liveRegion: true,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Text(
          kNyctisSendProvingNote,
          style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
        ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: AppButton(
            key: const ValueKey('nyctis_send_review_button'),
            minWidth: kNyctisSendButtonMinWidth,
            onPressed: canReview ? () => unawaited(_review(asset)) : null,
            child: Text(
              _isBuilding
                  ? kNyctisSendPreparingLabel
                  : kNyctisSendReviewLabel,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.base),
      ],
    );
  }
}

/// The holding this payment will come out of, as the shared facts card.
class NyctisFactsCardForAsset extends StatelessWidget {
  const NyctisFactsCardForAsset({required this.asset, super.key});

  final NyctisAssetDetailData asset;

  @override
  Widget build(BuildContext context) {
    return NyctisFactsCard(
      key: const ValueKey('nyctis_send_holding'),
      title: nyctisAssetDetailTitle(asset),
      facts: buildNyctisWalletHoldingFacts(asset),
    );
  }
}

/// Why sending is unavailable, with the one action that fixes it when there
/// is one. Reused by every screen that offers Send.
class NyctisSendBlockNotice extends StatelessWidget {
  const NyctisSendBlockNotice({required this.block, super.key});

  final NyctisSendBlock block;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        NyctisMessageCard(
          text: block.text,
          width: kNyctisCardWidth,
          tone: block.kind == NyctisSendBlockKind.inFlight
              ? NyctisMessageTone.neutral
              : NyctisMessageTone.warning,
        ),
        if (block.opensSettings) ...[
          const SizedBox(height: AppSpacing.xs),
          Center(
            child: AppButton(
              key: const ValueKey('nyctis_send_open_settings'),
              size: AppButtonSize.small,
              variant: AppButtonVariant.secondary,
              onPressed: () => context.push(kNyctisSettingsRoute),
              child: const Text(kNyctisOpenSettingsLabel),
            ),
          ),
        ],
      ],
    );
  }
}

/// One text field in whichever shape this form factor uses. The two are not
/// interchangeable widgets — desktop's carries its own label and message,
/// mobile's does not — so the branch is here rather than in every caller.
///
/// On mobile the visible label and the error are drawn beside the field, so
/// the field is given the same label for a screen reader, and the error is
/// its hint and a live region: without both, TalkBack reads "text field,
/// nyreg1…" with no name and never mentions the error.
class NyctisSendTextField extends StatelessWidget {
  const NyctisSendTextField({
    required this.fieldKey,
    required this.label,
    required this.controller,
    required this.focusNode,
    this.hintText,
    this.enabled = true,
    this.keyboardType,
    this.textInputAction = TextInputAction.done,
    this.inputFormatters,
    this.messageText,
    this.errorKey,
    this.trailing,
    this.onChanged,
    this.onSubmitted,
    super.key,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? hintText;
  final bool enabled;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final String? messageText;

  /// Key on the mobile error line, for tests.
  final Key? errorKey;
  final Widget? trailing;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final message = messageText;
    if (kAppFormFactor == AppFormFactor.mobile) {
      final colors = context.colors;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
            child: ExcludeSemantics(
              child: Text(
                label,
                style: AppTypography.labelLarge.copyWith(
                  color: colors.text.secondary,
                ),
              ),
            ),
          ),
          MobileTextField(
            fieldKey: fieldKey,
            semanticsLabel: label,
            semanticsHint: message,
            hintText: hintText,
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            textInputAction: textInputAction,
            trailing: trailing == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.xs),
                    child: trailing,
                  ),
            restingBorderColor: message == null
                ? null
                : colors.border.utilityDestructive,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Semantics(
              liveRegion: true,
              child: Text(
                message,
                key: errorKey,
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.destructive,
                ),
              ),
            ),
          ],
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
      textInputAction: textInputAction,
      inputFormatters: inputFormatters,
      messageText: message,
      tone: message == null
          ? AppTextFieldTone.neutral
          : AppTextFieldTone.destructive,
      trailing: trailing,
      trailingFitsSlot: trailing != null,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}
