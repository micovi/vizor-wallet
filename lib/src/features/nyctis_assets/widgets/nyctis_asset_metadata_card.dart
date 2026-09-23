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
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../core/widgets/review_wrap_card.dart';
import '../models/nyctis_asset_acceptance.dart';
import '../models/nyctis_metadata_pointer.dart';
import '../services/nyctis_metadata_fetcher.dart';
import 'nyctis_acceptance_controls.dart';
import 'nyctis_asset_logo.dart';
import 'nyctis_asset_row_data.dart';
import 'nyctis_collection_mapper.dart' show kNyctisWhatThisMeansTitle;
import 'nyctis_interactive.dart';
import 'nyctis_metadata_copy.dart';

/// Everything the card renders, already decided.
class NyctisAssetMetadataCardData {
  const NyctisAssetMetadataCardData({
    required this.assetId,
    this.name,
    this.symbol,
    this.pointer,
    this.refusalText,
    this.accepted = false,
    this.isLoading = false,
    this.view,
    this.collisions = const [],
    this.collectionDocumentOrigin,
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
  final NyctisMetadataPointer? pointer;

  /// Why there is no pointer, when that is worth saying out loud.
  final String? refusalText;

  final bool accepted;
  final bool isLoading;

  /// The fetched document, or null when the fetch was abandoned.
  final NyctisAssetMetadataView? view;

  /// Section 5's collision, computed against what is already accepted.
  final List<NyctisNameCollision> collisions;

  /// Where this asset's collection document came from, when the asset is
  /// described by one rather than by a document of its own.
  final String? collectionDocumentOrigin;

  bool get hasAnythingToSay => pointer != null || refusalText != null;
}

/// The card itself.
class NyctisAssetMetadataCard extends StatelessWidget {
  const NyctisAssetMetadataCard({
    required this.data,
    this.onAccept,
    this.onForget,
    this.onOpenLink,
    super.key,
  });

  final NyctisAssetMetadataCardData data;

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
        kNyctisMetadataTitle,
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
    _body(context, data.refusalText!, key: 'nyctis_metadata_refused'),
  ];

  /// Before acceptance: one sentence, the id, the collision if there is one,
  /// and the button. Everything else is behind "What this means" — about 150
  /// words used to sit above the button, which is how a card gets skimmed and
  /// pressed.
  List<Widget> _beforeAcceptance(BuildContext context) {
    final pointer = data.pointer!;
    final collisionText = nyctisCollisionWarningText(
      collisions: data.collisions,
      name: data.name,
      symbol: data.symbol,
    );
    return [
      _body(
        context,
        nyctisMetadataLeadText(pointer.origin),
        key: 'nyctis_metadata_lead',
        color: context.colors.text.primary,
      ),
      _assetIdRow(context),
      if (collisionText != null)
        NyctisCollisionPanel(
          key: const ValueKey('nyctis_metadata_collision'),
          text: collisionText,
          lines: [
            for (final collision in data.collisions)
              NyctisIdentityLineData(
                label: kNyctisCollisionExistingLabel,
                name: _acceptedLabel(collision.existing),
                assetId: collision.existing.assetId,
              ),
            NyctisIdentityLineData(
              label: kNyctisCollisionThisAssetLabel,
              name: _displayName(),
              assetId: data.assetId,
            ),
          ],
        ),
      NyctisGuardedAcceptButton(
        buttonKey: const ValueKey('nyctis_metadata_accept_button'),
        confirmKey: const ValueKey('nyctis_metadata_confirm_button'),
        label: kNyctisMetadataAcceptAction,
        requiresConfirmation: collisionText != null,
        onAccept: onAccept,
      ),
      NyctisDisclosure(
        key: const ValueKey('nyctis_metadata_details'),
        toggleKey: const ValueKey('nyctis_metadata_details_toggle'),
        title: kNyctisWhatThisMeansTitle,
        builder: (context) => _details(
          context,
          origin: pointer.origin,
          pinned: pointer.isPinned,
          lead: [
            _body(
              context,
              kNyctisMetadataNotFetchedText,
              key: 'nyctis_metadata_not_fetched',
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _accepted(BuildContext context) {
    if (data.isLoading) {
      return [
        Row(
          children: [
            AppIcon(
              AppIcons.loader,
              size: AppIconSize.medium,
              color: context.colors.icon.regular,
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: _body(
                context,
                kNyctisMetadataLoadingText,
                key: 'nyctis_metadata_loading',
              ),
            ),
          ],
        ),
        _forgetButton(),
      ];
    }
    final view = data.view;
    final collectionOrigin = data.collectionDocumentOrigin;
    if (view == null && collectionOrigin != null) {
      return [
        _body(
          context,
          nyctisMetadataFromCollectionText(collectionOrigin),
          key: 'nyctis_metadata_collection_document',
        ),
        _body(context, kNyctisMetadataNotEvidenceText),
        _forgetButton(),
      ];
    }
    if (view == null) {
      return [
        _body(
          context,
          nyctisMetadataAbsentText(data.pointer!.origin),
          key: 'nyctis_metadata_absent',
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
          key: 'nyctis_metadata_description',
          color: context.colors.text.primary,
        ),
      if (website != null)
        _linkRow(
          context,
          key: 'nyctis_metadata_website',
          label: nyctisWebsiteActionLabel(website),
          uri: website,
        ),
      for (final link in links)
        _linkRow(
          context,
          key: 'nyctis_metadata_link_${link.rel}',
          label: nyctisLinkActionLabel(link),
          uri: link.uri,
        ),
      if (view.isEmpty)
        _body(context, kNyctisMetadataEmptyText, key: 'nyctis_metadata_empty'),
      // Beside the logo, where it matters: the picture is now on screen.
      _body(context, kNyctisMetadataNotEvidenceText),
      _forgetButton(),
      NyctisDisclosure(
        key: const ValueKey('nyctis_metadata_details'),
        toggleKey: const ValueKey('nyctis_metadata_details_toggle'),
        title: kNyctisWhatThisMeansTitle,
        builder: (context) => _details(
          context,
          origin: view.sourceOrigin,
          pinned: view.documentPinned,
          includeNotEvidence: false,
        ),
      ),
    ];
  }

  /// The host, the pin, what the pin means, and the line that must survive
  /// every redesign — inside "What this means".
  Widget _details(
    BuildContext context, {
    required String origin,
    required bool pinned,
    List<Widget> lead = const [],
    bool includeNotEvidence = true,
  }) {
    final children = <Widget>[
      ...lead,
      _factRow(context, kNyctisMetadataHostLabel, origin),
      _factRow(
        context,
        kNyctisMetadataPinLabel,
        pinned ? kNyctisMetadataPinnedValue : kNyctisMetadataUnpinnedValue,
      ),
      _body(
        context,
        pinned ? kNyctisMetadataPinnedNote : kNyctisMetadataUnpinnedNote,
      ),
      if (includeNotEvidence) _body(context, kNyctisMetadataNotEvidenceText),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.xs),
          children[i],
        ],
      ],
    );
  }

  String _displayName() {
    final name = data.name?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final symbol = data.symbol?.trim() ?? '';
    return symbol.isNotEmpty ? symbol : 'Unnamed asset';
  }

  static String _acceptedLabel(NyctisAcceptedAsset asset) {
    final name = asset.name?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final symbol = asset.symbol?.trim() ?? '';
    return symbol.isNotEmpty ? symbol : 'Unnamed asset';
  }

  /// The logo, and the asset id beside it.
  ///
  /// Section 5: a wallet **MUST** show `asset_id`, or an unambiguous
  /// abbreviation of it, wherever it shows a logo. These two are one widget
  /// so that they cannot be separated by a later layout change.
  Widget _header(BuildContext context, NyctisAssetMetadataView view) {
    final colors = context.colors;
    final symbol = data.symbol?.trim();
    return Row(
      key: const ValueKey('nyctis_metadata_header'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        NyctisAssetLogoImage(
          bytes: view.logoBytes,
          size: kNyctisMetadataLogoSize,
        ),
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
                    ? truncateNyctisAssetId(data.assetId)
                    : '$symbol · ${truncateNyctisAssetId(data.assetId)}',
                key: const ValueKey('nyctis_metadata_header_asset_id'),
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
    truncateNyctisAssetId(data.assetId),
    copyText: data.assetId,
  );

  Widget _forgetButton() => Align(
    alignment: Alignment.centerLeft,
    child: AppButton(
      key: const ValueKey('nyctis_metadata_forget_button'),
      size: AppButtonSize.small,
      // Long labels wrap at large text instead of overflowing.
      growWithContent: true,
      constrainContent: true,
      variant: AppButtonVariant.ghost,
      onPressed: onForget,
      child: const Text(kNyctisMetadataForgetAction),
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
          color: colors.icon.regular,
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
          AppIcons.arrowTopRight,
          size: AppIconSize.medium,
          color: colors.icon.regular,
        ),
      ],
    );
    // Section 4.3: a link opens on an explicit action and never on render.
    return NyctisPressable(
      key: ValueKey(key),
      onPressed: open == null ? null : () => open(uri),
      semanticsLabel: label,
      semanticsHint: kNyctisOpensInBrowserHint,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxs,
        vertical: AppSpacing.xxs,
      ),
      child: row,
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
          // `text.secondary`, not `text.muted`: muted is 3.65:1 on the light
          // card, under AA for 12px labels.
          style: AppTypography.labelSmall.copyWith(
            color: colors.text.secondary,
          ),
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
            color: colors.icon.regular,
          ),
        ],
      ],
    );
    if (copyText == null) return row;
    return NyctisPressable(
      key: ValueKey('nyctis_metadata_copy_$label'),
      onPressed: () => copyNyctisText(context, text: copyText, what: label),
      semanticsLabel: nyctisCopyLabel(nyctisMidSentence(label), value),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxs,
        vertical: AppSpacing.xxs,
      ),
      child: row,
    );
  }

  Widget _body(BuildContext context, String text, {String? key, Color? color}) {
    return Text(
      text,
      key: key == null ? null : ValueKey(key),
      style: AppTypography.bodySmall.copyWith(
        color: color ?? context.colors.text.secondary,
      ),
    );
  }
}

/// Side of the logo in the accepted header.
const double kNyctisMetadataLogoSize = 40;

/// Spoken after a link's label: where activating it goes.
const String kNyctisOpensInBrowserHint = 'Opens in your browser';

/// Builds the card's data from an asset, the acceptance set and a fetch.
///
/// Pure, so the "no logo without acceptance" rule is testable without a
/// widget tree: [NyctisAssetMetadataCardData.view] is only ever non-null
/// when [accepted] is true, because the caller that produces [view] is itself
/// gated on acceptance.
NyctisAssetMetadataCardData buildNyctisMetadataCardData({
  required NyctisAssetDetailData asset,
  required NyctisAssetAcceptance acceptance,
  NyctisAssetMetadataView? view,
  bool isLoading = false,
  String? collectionDocumentOrigin,
}) {
  final result = readNyctisMetadataUri(asset.metadataUri);
  final accepted = acceptance.isAccepted(asset.assetId);
  return NyctisAssetMetadataCardData(
    assetId: asset.assetId,
    name: asset.name,
    symbol: asset.symbol,
    pointer: result.pointer,
    refusalText: nyctisPointerRefusalText(result.rejection),
    accepted: accepted,
    isLoading: accepted && isLoading,
    view: accepted ? view : null,
    collectionDocumentOrigin: accepted ? collectionDocumentOrigin : null,
    collisions: accepted
        ? const []
        : acceptance.collisionsWith(
            assetId: asset.assetId,
            name: asset.name,
            symbol: asset.symbol,
          ),
  );
}
