/// The issuer-metadata card on the asset detail screen.
///
/// It has two faces, and which one is drawn is the whole of section 5 of
/// `spec/asset-metadata-v0.md`:
///
/// * **before acceptance** — the asset id, the host a fetch would talk to,
///   whether the signed link pins what comes back, the section 5 collision
///   warning when there is one, and a button. No logo, no description, no
///   request. A wallet that draws the picture first and asks afterwards has
///   already handed an impersonator everything they wanted.
/// * **after acceptance** — the logo, the asset id beside it (section 5, first
///   bullet), the description, and the links, each labelled with the origin it
///   would open (section 4.3).
///
/// Presentational: it takes plain values and callbacks, so both form factors,
/// the Widgetbook fixtures and the widget tests render the same thing.
library;

import 'package:flutter/widgets.dart';

import '../../../core/layout/app_form_factor.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_copy_feedback.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../core/widgets/review_wrap_card.dart';
import '../models/nightjar_asset_acceptance.dart';
import '../models/nightjar_metadata_pointer.dart';
import '../services/nightjar_metadata_fetcher.dart';
import 'nightjar_asset_logo.dart';
import 'nightjar_asset_row_data.dart';
import 'nightjar_metadata_copy.dart';

/// Everything the card renders, already decided.
class NightjarAssetMetadataCardData {
  const NightjarAssetMetadataCardData({
    required this.assetId,
    this.name,
    this.symbol,
    this.pointer,
    this.refusalText,
    this.accepted = false,
    this.isLoading = false,
    this.view,
    this.collisions = const [],
  });

  /// The asset's only true identifier, and the one thing on this card an
  /// impersonator cannot copy.
  final String assetId;

  /// The **signed** name and symbol, from the `ASSET` message. Never the
  /// copies a document may carry: section 1 says a wallet must ignore those
  /// and use the signed values, and a document that disagrees is not an error.
  final String? name;
  final String? symbol;

  /// The resolvable pointer, or null when there is none.
  final NightjarMetadataPointer? pointer;

  /// Why there is no pointer, when that is worth saying out loud.
  final String? refusalText;

  final bool accepted;
  final bool isLoading;

  /// The fetched document, or null when the fetch was abandoned.
  final NightjarAssetMetadataView? view;

  /// Section 5's collision, computed against what is already accepted.
  final List<NightjarNameCollision> collisions;

  bool get hasAnythingToSay => pointer != null || refusalText != null;
}

/// The card itself.
class NightjarAssetMetadataCard extends StatelessWidget {
  const NightjarAssetMetadataCard({
    required this.data,
    this.onAccept,
    this.onForget,
    this.onOpenLink,
    super.key,
  });

  final NightjarAssetMetadataCardData data;

  /// Explicit acceptance. Null renders the card read-only — a Widgetbook
  /// fixture, or a screen with no wallet behind it.
  final VoidCallback? onAccept;

  final VoidCallback? onForget;

  /// Opens an external link. Section 4.3: only from an explicit action, and
  /// the origin is already in the button's label.
  final void Function(Uri uri)? onOpenLink;

  @override
  Widget build(BuildContext context) {
    if (!data.hasAnythingToSay) return const SizedBox.shrink();
    final colors = context.colors;

    final children = <Widget>[
      Text(
        kNightjarMetadataTitle,
        style: AppTypography.labelLarge.copyWith(
          color: colors.text.secondary,
          fontWeight: FontWeight.w600,
        ),
      ),
      ...(data.pointer == null
          ? _refusal(context)
          : data.accepted
          ? _accepted(context)
          : _beforeAcceptance(context)),
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

  List<Widget> _refusal(BuildContext context) => [
    _body(context, data.refusalText!, key: 'nightjar_metadata_refused'),
  ];

  List<Widget> _beforeAcceptance(BuildContext context) {
    final collisionText = nightjarCollisionWarningText(
      collisions: data.collisions,
      name: data.name,
      symbol: data.symbol,
    );
    return [
      _body(
        context,
        kNightjarMetadataNotFetchedText,
        key: 'nightjar_metadata_not_fetched',
      ),
      _assetIdRow(context),
      _factRow(context, kNightjarMetadataHostLabel, data.pointer!.origin),
      _factRow(
        context,
        kNightjarMetadataPinLabel,
        data.pointer!.isPinned
            ? kNightjarMetadataPinnedValue
            : kNightjarMetadataUnpinnedValue,
      ),
      _body(
        context,
        data.pointer!.isPinned
            ? kNightjarMetadataPinnedNote
            : kNightjarMetadataUnpinnedNote,
      ),
      if (collisionText != null)
        _body(
          context,
          collisionText,
          key: 'nightjar_metadata_collision',
          tone: _MetadataTone.warning,
        ),
      _body(context, kNightjarMetadataNotEvidenceText),
      Align(
        alignment: Alignment.centerLeft,
        child: AppButton(
          key: const ValueKey('nightjar_metadata_accept_button'),
          size: AppButtonSize.small,
          variant: AppButtonVariant.secondary,
          onPressed: onAccept,
          child: const Text(kNightjarMetadataAcceptAction),
        ),
      ),
    ];
  }

  List<Widget> _accepted(BuildContext context) {
    if (data.isLoading) {
      return [
        _body(
          context,
          kNightjarMetadataLoadingText,
          key: 'nightjar_metadata_loading',
        ),
        _forgetButton(),
      ];
    }
    final view = data.view;
    if (view == null) {
      return [
        _body(
          context,
          nightjarMetadataAbsentText(data.pointer!.origin),
          key: 'nightjar_metadata_absent',
        ),
        _forgetButton(),
      ];
    }
    final metadata = view.metadata;
    final links = metadata.renderableLinks;
    final website = metadata.website;
    return [
      _header(context, view),
      if (metadata.description != null)
        _body(
          context,
          metadata.description!,
          key: 'nightjar_metadata_description',
        ),
      if (website != null)
        _linkRow(
          context,
          key: 'nightjar_metadata_website',
          label: nightjarWebsiteActionLabel(website),
          uri: website,
        ),
      for (final link in links)
        _linkRow(
          context,
          key: 'nightjar_metadata_link_${link.rel}',
          label: nightjarLinkActionLabel(link),
          uri: link.uri,
        ),
      if (view.isEmpty)
        _body(
          context,
          kNightjarMetadataEmptyText,
          key: 'nightjar_metadata_empty',
        ),
      _factRow(context, kNightjarMetadataHostLabel, view.sourceOrigin),
      _factRow(
        context,
        kNightjarMetadataPinLabel,
        view.documentPinned
            ? kNightjarMetadataPinnedValue
            : kNightjarMetadataUnpinnedValue,
      ),
      _body(
        context,
        view.documentPinned
            ? kNightjarMetadataPinnedNote
            : kNightjarMetadataUnpinnedNote,
      ),
      _body(context, kNightjarMetadataNotEvidenceText),
      _forgetButton(),
    ];
  }

  /// The logo, and the asset id beside it.
  ///
  /// Section 5: a wallet **MUST** show `asset_id`, or an unambiguous
  /// abbreviation of it, wherever it shows a logo. These two are one widget
  /// so that they cannot be separated by a later layout change.
  Widget _header(BuildContext context, NightjarAssetMetadataView view) {
    final colors = context.colors;
    final symbol = data.symbol?.trim();
    return Row(
      key: const ValueKey('nightjar_metadata_header'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        NightjarAssetLogoImage(bytes: view.logoBytes, size: 40),
        if (view.hasLogo) const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                data.name?.trim().isNotEmpty == true
                    ? data.name!.trim()
                    : 'Unnamed asset',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodyMediumStrong.copyWith(
                  color: colors.text.accent,
                ),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                symbol == null || symbol.isEmpty
                    ? truncateNightjarAssetId(data.assetId)
                    : '$symbol · ${truncateNightjarAssetId(data.assetId)}',
                key: const ValueKey('nightjar_metadata_header_asset_id'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.labelSmall.copyWith(
                  color: colors.text.secondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _assetIdRow(BuildContext context) => _factRow(
    context,
    'Asset id',
    truncateNightjarAssetId(data.assetId),
    copyText: data.assetId,
  );

  Widget _forgetButton() => Align(
    alignment: Alignment.centerLeft,
    child: AppButton(
      key: const ValueKey('nightjar_metadata_forget_button'),
      size: AppButtonSize.small,
      variant: AppButtonVariant.ghost,
      onPressed: onForget,
      child: const Text(kNightjarMetadataForgetAction),
    ),
  );

  /// One link, as a row rather than as a button.
  ///
  /// A row because the label carries the origin (section 4.3) and an origin
  /// can be long: a button sizes to its content and a long host pushes it off
  /// a 390-pixel screen, which would either clip the origin or hide the
  /// action. Ellipsising the middle of a row keeps both on screen.
  Widget _linkRow(
    BuildContext context, {
    required String key,
    required String label,
    required Uri uri,
  }) {
    final colors = context.colors;
    final open = onOpenLink;
    final row = Row(
      children: [
        AppIcon(
          AppIcons.link,
          size: AppIconSize.medium,
          color: colors.icon.muted,
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.labelLarge.copyWith(
              color: colors.text.accent,
              letterSpacing: 0,
            ),
          ),
        ),
        AppIcon(
          AppIcons.chevronForward,
          size: AppIconSize.medium,
          color: colors.icon.muted,
        ),
      ],
    );
    // Section 4.3: a link opens on an explicit action and never on render.
    return Semantics(
      key: ValueKey(key),
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: open == null ? null : () => open(uri),
        child: row,
      ),
    );
  }

  Widget _factRow(
    BuildContext context,
    String label,
    String value, {
    String? copyText,
  }) {
    final colors = context.colors;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTypography.labelSmall.copyWith(color: colors.text.muted),
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.labelSmall.copyWith(
              color: colors.text.primary,
            ),
          ),
        ),
        if (copyText != null) ...[
          const SizedBox(width: AppSpacing.xxs),
          AppIcon(
            AppIcons.copy,
            size: AppIconSize.medium,
            color: colors.icon.muted,
          ),
        ],
      ],
    );
    if (copyText == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          copyTextWithToast(context, text: copyText, toastMessage: 'Copied'),
      child: row,
    );
  }

  Widget _body(
    BuildContext context,
    String text, {
    String? key,
    _MetadataTone tone = _MetadataTone.neutral,
  }) {
    final colors = context.colors;
    return Text(
      text,
      key: key == null ? null : ValueKey(key),
      style: AppTypography.bodySmall.copyWith(
        color: switch (tone) {
          _MetadataTone.neutral => colors.text.secondary,
          _MetadataTone.warning => colors.text.warning,
        },
      ),
    );
  }
}

enum _MetadataTone { neutral, warning }

/// Builds the card's data from an asset, the acceptance set and a fetch.
///
/// Pure, so the "no logo without acceptance" rule is testable without a
/// widget tree: [NightjarAssetMetadataCardData.view] is only ever non-null
/// when [accepted] is true, because the caller that produces [view] is itself
/// gated on acceptance.
NightjarAssetMetadataCardData buildNightjarMetadataCardData({
  required NightjarAssetDetailData asset,
  required NightjarAssetAcceptance acceptance,
  NightjarAssetMetadataView? view,
  bool isLoading = false,
}) {
  final result = readNightjarMetadataUri(asset.metadataUri);
  final accepted = acceptance.isAccepted(asset.assetId);
  return NightjarAssetMetadataCardData(
    assetId: asset.assetId,
    name: asset.name,
    symbol: asset.symbol,
    pointer: result.pointer,
    refusalText: nightjarPointerRefusalText(result.rejection),
    accepted: accepted,
    isLoading: accepted && isLoading,
    view: accepted ? view : null,
    collisions: accepted
        ? const []
        : acceptance.collisionsWith(
            assetId: asset.assetId,
            name: asset.name,
            symbol: asset.symbol,
          ),
  );
}
