/// The controls every acceptance surface shares: the "Show …" button, its
/// second deliberate step when names collide, and the list of colliding ids.
///
/// `spec/asset-metadata-v0.md` section 5 says a wallet **SHOULD** warn, at the
/// moment of acceptance, when an asset's name or symbol matches one already
/// accepted under a different `asset_id`, because that collision *is* the
/// impersonation attack. A warning that names neither id and sits above the
/// same one-tap button as every other asset is a warning users learn to skip.
/// So the ids are drawn, copyable, beside each other, and accepting a
/// colliding asset takes a second press on a differently worded, differently
/// coloured control.
///
/// Presentational: plain values in, callbacks out.
library;

import 'package:flutter/widgets.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_icon.dart';
import 'nyctis_asset_row_data.dart';
import 'nyctis_interactive.dart';
import 'nyctis_metadata_copy.dart';

/// One side of a collision: a label, a name, and an id that can be copied.
class NyctisIdentityLineData {
  const NyctisIdentityLineData({
    required this.label,
    required this.name,
    required this.assetId,
  });

  /// `Already shown` or `This asset`.
  final String label;
  final String name;

  /// The full id. Drawn truncated, copied whole.
  final String assetId;
}

/// A name-collision warning with the ids that tell the assets apart.
///
/// [lines] is drawn in order; callers put the already-accepted asset(s) first
/// and this asset last, so the thing being compared against is read first.
class NyctisCollisionPanel extends StatelessWidget {
  const NyctisCollisionPanel({
    required this.text,
    required this.lines,
    this.moreCount = 0,
    super.key,
  });

  final String text;
  final List<NyctisIdentityLineData> lines;

  /// Colliding pairs not drawn, for a collection with many of them.
  final int moreCount;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      key: const ValueKey('nyctis_collision_panel'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.small),
        border: Border.all(color: colors.border.subtle),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            NyctisNoticeText(text: text),
            for (final line in lines) ...[
              const SizedBox(height: AppSpacing.xxs),
              NyctisIdentityLine(line: line),
            ],
            if (moreCount > 0) ...[
              const SizedBox(height: AppSpacing.xxs),
              Text(
                moreCount == 1 ? 'And 1 more.' : 'And $moreCount more.',
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.secondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// `Already shown  NightCash · b2c1f7…e5f401  [copy]` — one focusable, copyable
/// line.
class NyctisIdentityLine extends StatelessWidget {
  const NyctisIdentityLine({required this.line, super.key});

  final NyctisIdentityLineData line;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final shortId = truncateNyctisAssetId(line.assetId);
    return NyctisPressable(
      key: ValueKey('nyctis_identity_line_${line.assetId}'),
      onPressed: () =>
          copyNyctisText(context, text: line.assetId, what: 'Asset id'),
      semanticsLabel:
          '${line.label}: ${line.name}. '
          '${nyctisCopyLabel('asset id', shortId)}',
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxs,
        vertical: AppSpacing.xxs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${line.label}: ',
                    style: TextStyle(color: colors.text.secondary),
                  ),
                  TextSpan(
                    text: '${line.name} · ',
                    style: TextStyle(color: colors.text.primary),
                  ),
                  TextSpan(
                    text: shortId,
                    style: AppTypography.codeSmall.copyWith(
                      color: colors.text.accent,
                    ),
                  ),
                ],
              ),
              style: AppTypography.bodySmall,
            ),
          ),
          const SizedBox(width: AppSpacing.xxs),
          AppIcon(
            AppIcons.copy,
            size: AppIconSize.medium,
            color: colors.icon.regular,
          ),
        ],
      ),
    );
  }
}

/// The acceptance button, with a second step when [requiresConfirmation].
///
/// Without a collision it is one press. With one, the first press only opens
/// the confirmation: a prompt, a destructive-styled "I checked the asset id —
/// show anyway" that takes focus, and a way back. The asset is accepted only by
/// that second control.
class NyctisGuardedAcceptButton extends StatefulWidget {
  const NyctisGuardedAcceptButton({
    required this.label,
    required this.onAccept,
    this.requiresConfirmation = false,
    this.buttonKey,
    this.confirmKey,
    super.key,
  });

  final String label;

  /// Null renders the button disabled — a read-only fixture.
  final VoidCallback? onAccept;
  final bool requiresConfirmation;
  final Key? buttonKey;
  final Key? confirmKey;

  @override
  State<NyctisGuardedAcceptButton> createState() =>
      _NyctisGuardedAcceptButtonState();
}

class _NyctisGuardedAcceptButtonState extends State<NyctisGuardedAcceptButton> {
  bool _confirming = false;

  @override
  void didUpdateWidget(covariant NyctisGuardedAcceptButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.requiresConfirmation) _confirming = false;
  }

  @override
  Widget build(BuildContext context) {
    final onAccept = widget.onAccept;
    if (!_confirming) {
      return Align(
        alignment: Alignment.centerLeft,
        child: AppButton(
          key: widget.buttonKey,
          size: AppButtonSize.small,
          // Long labels wrap at large text instead of overflowing.
          growWithContent: true,
          constrainContent: true,
          variant: AppButtonVariant.secondary,
          onPressed: onAccept == null
              ? null
              : widget.requiresConfirmation
              ? () => setState(() => _confirming = true)
              : onAccept,
          child: Text(widget.label),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const NyctisNoticeText(text: kNyctisCollisionConfirmPrompt),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            AppButton(
              key: widget.confirmKey,
              size: AppButtonSize.small,
              // Long labels wrap at large text instead of overflowing.
              growWithContent: true,
              constrainContent: true,
              variant: AppButtonVariant.destructive,
              autofocus: true,
              onPressed: onAccept == null
                  ? null
                  : () {
                      setState(() => _confirming = false);
                      onAccept();
                    },
              child: const Text(kNyctisCollisionConfirmAction),
            ),
            AppButton(
              key: const ValueKey('nyctis_collision_cancel'),
              size: AppButtonSize.small,
              // Long labels wrap at large text instead of overflowing.
              growWithContent: true,
              constrainContent: true,
              variant: AppButtonVariant.ghost,
              onPressed: () => setState(() => _confirming = false),
              child: const Text(kNyctisCollisionCancelAction),
            ),
          ],
        ),
      ],
    );
  }
}
