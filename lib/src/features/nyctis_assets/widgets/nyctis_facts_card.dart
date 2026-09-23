/// A titled card of `label: value` fact rows, used by the Nyctis asset
/// detail screen for identity, supply, holding, and per-note facts.
///
/// Presentational only. The rows are the shared components — [ReviewListRow]
/// on desktop, [MobileListRow] on mobile — and the surface is the shared
/// [ReviewWrapCard] / [MobileSurfaceCard]; nothing new is invented here.
/// The branch is on [kAppFormFactor], so the unused half is tree-shaken.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../core/layout/app_form_factor.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/mobile/mobile_list_row.dart';
import '../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../core/widgets/review_list_row.dart';
import '../../../core/widgets/review_wrap_card.dart';
import 'nyctis_asset_row_data.dart';
import 'nyctis_assets_feed.dart' show nyctisRowShouldStack;
import 'nyctis_interactive.dart';

class NyctisFactsCard extends StatelessWidget {
  const NyctisFactsCard({
    required this.facts,
    this.title,
    this.footnote,
    super.key,
  });

  /// Section heading above the rows. Omitted for an unlabelled card.
  final String? title;

  final List<NyctisAssetFactData> facts;

  /// Sentence rendered under the rows — this is where the detail screen
  /// states that issued supply is public and balances are not.
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final title = this.title;
    final footnote = this.footnote;

    final children = <Widget>[
      if (title != null)
        Semantics(
          header: true,
          child: Text(
            title,
            style: AppTypography.labelLarge.copyWith(
              color: colors.text.secondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      for (final fact in facts) _NyctisFactRow(fact: fact),
      if (footnote != null)
        Text(
          footnote,
          style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
        ),
    ];

    if (kAppFormFactor == AppFormFactor.mobile) {
      return MobileSurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: AppSpacing.xs),
              children[i],
            ],
          ],
        ),
      );
    }
    return ReviewWrapCard(mainAxisSize: MainAxisSize.min, children: children);
  }
}

class _NyctisFactRow extends StatelessWidget {
  const _NyctisFactRow({required this.fact});

  final NyctisAssetFactData fact;

  @override
  Widget build(BuildContext context) {
    final copyText = fact.copyText;
    final Widget row;
    if (nyctisRowShouldStack(context)) {
      // At large text the label and the value cannot share one line: the
      // shared rows keep the label whole and squeeze the value to nothing.
      row = _StackedFactRow(fact: fact);
    } else if (kAppFormFactor == AppFormFactor.mobile) {
      // The shared mobile row keeps its label whole and ellipsizes the
      // value. On a narrow phone, or inside a nested card, a long label then
      // overflows the row, and a long value — a spend condition, an amount —
      // is cut to something it does not say. Such a fact stacks instead, as it
      // does at large text.
      row = LayoutBuilder(
        builder: (context, constraints) {
          if (!nyctisFactFitsOneLine(
            context,
            fact,
            maxWidth: constraints.maxWidth,
          )) {
            return _StackedFactRow(fact: fact);
          }
          return MobileListRow(
            label: fact.label,
            value: fact.value,
            trailing: copyText == null
                ? null
                : AppIcon(
                    AppIcons.copy,
                    size: AppIconSize.medium,
                    color: context.colors.icon.regular,
                  ),
          );
        },
      );
    } else {
      // The copy glyph without the row's own tap: the whole row is the
      // control below, so it is one focus stop with one name.
      row = ReviewListRow(
        label: fact.label,
        value: fact.value,
        trailingIconName: copyText == null ? null : AppIcons.copy,
      );
    }
    if (copyText == null) return row;
    return NyctisPressable(
      key: ValueKey('nyctis_fact_copy_${fact.label}'),
      onPressed: () => copyNyctisFact(context, fact),
      semanticsLabel: nyctisCopyLabel(
        nyctisMidSentence(fact.label),
        fact.value,
      ),
      child: row,
    );
  }
}

/// Whether [fact]'s label and whole value fit on one [MobileListRow] line of
/// [maxWidth], at the ambient text scale.
///
/// Measured with the row's own style ([AppTypography.bodyMedium] for both
/// halves) and its own gaps, so the answer is the row's: when it is false the
/// row would either overflow its label or ellipsize its value.
bool nyctisFactFitsOneLine(
  BuildContext context,
  NyctisAssetFactData fact, {
  required double maxWidth,
}) {
  if (!maxWidth.isFinite) return true;
  final textDirection = Directionality.of(context);
  final textScaler = MediaQuery.textScalerOf(context);
  double widthOf(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: AppTypography.bodyMedium),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  final trailing = fact.copyText == null
      ? 0.0
      : AppSpacing.xs + AppIconSize.medium;
  final needed =
      widthOf(fact.label) + AppSpacing.xs + widthOf(fact.value) + trailing;
  return needed <= maxWidth;
}

/// Copies a fact's [NyctisAssetFactData.copyText] with the shared toast, and
/// tells a screen reader what was copied.
void copyNyctisFact(BuildContext context, NyctisAssetFactData fact) {
  final text = fact.copyText;
  if (text == null) return;
  unawaited(copyNyctisText(context, text: text, what: fact.label));
}

/// A fact as two lines — label, then value — for large text sizes.
class _StackedFactRow extends StatelessWidget {
  const _StackedFactRow({required this.fact});

  final NyctisAssetFactData fact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      key: const ValueKey('nyctis_fact_stacked'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fact.label,
                  style: AppTypography.bodySmall.copyWith(
                    color: colors.text.secondary,
                  ),
                ),
                Text(
                  fact.value,
                  style: AppTypography.bodyMediumStrong.copyWith(
                    color: colors.text.accent,
                  ),
                ),
              ],
            ),
          ),
          if (fact.copyText != null) ...[
            const SizedBox(width: AppSpacing.xs),
            AppIcon(
              AppIcons.copy,
              size: AppIconSize.medium,
              color: colors.icon.regular,
            ),
          ],
        ],
      ),
    );
  }
}
