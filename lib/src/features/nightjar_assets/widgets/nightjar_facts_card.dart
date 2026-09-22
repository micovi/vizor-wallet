/// A titled card of `label: value` fact rows, used by the Nightjar asset
/// detail screen for identity, supply, holding, and per-note facts.
///
/// Presentational only. The rows are the shared components — [ReviewListRow]
/// on desktop, [MobileListRow] on mobile — and the surface is the shared
/// [ReviewWrapCard] / [MobileSurfaceCard]; nothing new is invented here.
/// The branch is on [kAppFormFactor], so the unused half is tree-shaken.
library;

import 'package:flutter/widgets.dart';

import '../../../core/layout/app_form_factor.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_copy_feedback.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/mobile/mobile_list_row.dart';
import '../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../core/widgets/review_list_row.dart';
import '../../../core/widgets/review_wrap_card.dart';
import 'nightjar_asset_row_data.dart';

class NightjarFactsCard extends StatelessWidget {
  const NightjarFactsCard({
    required this.facts,
    this.title,
    this.footnote,
    super.key,
  });

  /// Section heading above the rows. Omitted for an unlabelled card.
  final String? title;

  final List<NightjarAssetFactData> facts;

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
        Text(
          title,
          style: AppTypography.labelLarge.copyWith(
            color: colors.text.secondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      for (final fact in facts) _NightjarFactRow(fact: fact),
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

class _NightjarFactRow extends StatelessWidget {
  const _NightjarFactRow({required this.fact});

  final NightjarAssetFactData fact;

  @override
  Widget build(BuildContext context) {
    if (kAppFormFactor == AppFormFactor.mobile) {
      return MobileListRow(
        label: fact.label,
        value: fact.value,
        trailing: fact.copyText == null
            ? null
            : AppIcon(
                AppIcons.copy,
                size: AppIconSize.medium,
                color: context.colors.icon.muted,
              ),
        onTap: fact.copyText == null
            ? null
            : () => copyNightjarFact(context, fact),
      );
    }
    return ReviewListRow(
      label: fact.label,
      value: fact.value,
      copyText: fact.copyText,
    );
  }
}

/// Copies a fact's [NightjarAssetFactData.copyText] with the shared toast.
/// Exposed so the mobile row and any future caller share one behaviour.
void copyNightjarFact(BuildContext context, NightjarAssetFactData fact) {
  final text = fact.copyText;
  if (text == null) return;
  copyTextWithToast(context, text: text, toastMessage: 'Copied');
}
