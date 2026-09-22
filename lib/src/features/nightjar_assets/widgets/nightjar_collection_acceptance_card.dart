/// The card that offers to accept a whole collection's artwork at once.
///
/// It exists because a hundred-piece collection makes accepting each piece
/// separately absurd, and it is written the way it is because accepting a
/// collection is **not** a UI convenience. `collection_id` is derived from the
/// issuer's key and hashed into every member's `asset_id`, so one press here
/// says "I trust this one key for every piece it has published into this
/// collection". Section 5 of `spec/asset-metadata-v0.md` allows that only on
/// terms:
///
/// * the record underneath stays **per `asset_id`** — this writes one
///   acceptance entry per member, and any single piece can be forgotten
///   afterwards;
/// * the user is told what the press grants before they make it, including
///   which hosts will be talked to and how many;
/// * the section 5 name collision is still checked, aggregated rather than
///   dropped;
/// * nothing is fetched for an unaccepted piece, ever, and least of all to
///   make the grid behind this card look full.
///
/// Presentational: plain values in, callbacks out.
library;

import 'package:flutter/widgets.dart';

import '../../../core/layout/app_form_factor.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../core/widgets/review_wrap_card.dart';
import '../models/nightjar_asset_acceptance.dart';
import '../models/nightjar_metadata_pointer.dart';
import 'nightjar_collection_data.dart';
import 'nightjar_collection_mapper.dart';
import 'nightjar_metadata_copy.dart';

/// Everything the card renders, already decided.
class NightjarCollectionAcceptanceData {
  const NightjarCollectionAcceptanceData({
    required this.collectionId,
    required this.state,
    required this.memberCount,
    required this.acceptedCount,
    required this.pendingIds,
    required this.origins,
    this.collisionText,
    this.collidingIds = const [],
  });

  final String collectionId;
  final NightjarCollectionAcceptanceState state;

  /// Members in this view.
  final int memberCount;

  /// Members already accepted.
  final int acceptedCount;

  /// The `asset_id`s a press would accept — the unaccepted members that carry
  /// a `uri` this wallet would resolve. A member with no document is left out
  /// rather than accepted silently: accepting it would grant nothing and would
  /// still put a record in the stored set.
  final List<String> pendingIds;

  /// Distinct hosts those members would be fetched from.
  final List<String> origins;

  /// The aggregated section 5 collision warning, or null.
  final String? collisionText;
  final List<String> collidingIds;

  int get pendingCount => pendingIds.length;

  /// True when there is nothing here this wallet would ever fetch.
  bool get hasNothingToFetch =>
      pendingIds.isEmpty && state == NightjarCollectionAcceptanceState.none;
}

/// Builds the card's values from a collection and the accepted set.
NightjarCollectionAcceptanceData buildNightjarCollectionAcceptanceData({
  required NightjarCollectionData collection,
  required NightjarAssetAcceptance acceptance,
}) {
  final unaccepted = nightjarUnacceptedMembers(
    collection: collection,
    acceptance: acceptance,
  );
  // Only members with a resolvable pointer are offered. `readNightjarMetadataUri`
  // is the same reader the per-asset card uses, so a piece refused there — an
  // `http:` link, an `ipfs:` one, a malformed digest — is refused here too
  // rather than quietly accepted into a set that will never draw anything.
  final fetchable = [
    for (final member in unaccepted)
      if (readNightjarMetadataUri(member.metadataUri).isResolvable) member,
  ];
  var accepted = 0;
  for (final member in collection.members) {
    if (acceptance.isAccepted(member.assetId)) accepted++;
  }
  return NightjarCollectionAcceptanceData(
    collectionId: collection.collectionId,
    state: nightjarCollectionAcceptanceState(
      collection: collection,
      acceptance: acceptance,
    ),
    memberCount: collection.memberCount,
    acceptedCount: accepted,
    pendingIds: [for (final member in fetchable) member.assetId],
    origins: nightjarCollectionFetchOrigins(fetchable),
    collisionText: nightjarCollectionCollisionText(
      collection: collection,
      acceptance: acceptance,
    ),
    collidingIds: nightjarCollectionCollidingIds(
      collection: collection,
      acceptance: acceptance,
    ),
  );
}

/// The card itself.
class NightjarCollectionAcceptanceCard extends StatelessWidget {
  const NightjarCollectionAcceptanceCard({
    required this.data,
    this.onAcceptAll,
    this.onForgetAll,
    super.key,
  });

  final NightjarCollectionAcceptanceData data;

  /// Accepts every id in [NightjarCollectionAcceptanceData.pendingIds]. Null
  /// renders the card read-only — a Widgetbook fixture, or a screen with no
  /// wallet behind it.
  final VoidCallback? onAcceptAll;

  final VoidCallback? onForgetAll;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final children = <Widget>[
      Text(
        kNightjarCollectionAcceptTitle,
        style: AppTypography.labelLarge.copyWith(
          color: colors.text.secondary,
          fontWeight: FontWeight.w600,
        ),
      ),
      ..._body(context),
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

  List<Widget> _body(BuildContext context) {
    if (data.hasNothingToFetch) {
      return [
        _text(
          context,
          kNightjarCollectionNothingToFetchText,
          key: 'nightjar_collection_nothing_to_fetch',
        ),
      ];
    }

    return switch (data.state) {
      NightjarCollectionAcceptanceState.all => [
        _text(
          context,
          nightjarCollectionAcceptedText(data.acceptedCount),
          key: 'nightjar_collection_accepted',
        ),
        _text(context, kNightjarMetadataNotEvidenceText),
        _forgetButton(),
      ],
      NightjarCollectionAcceptanceState.partial => [
        _text(
          context,
          nightjarCollectionPartialText(
            accepted: data.acceptedCount,
            total: data.memberCount,
          ),
          key: 'nightjar_collection_partial',
        ),
        ..._offer(context),
        _forgetButton(),
      ],
      NightjarCollectionAcceptanceState.none => _offer(context),
    };
  }

  List<Widget> _offer(BuildContext context) {
    if (data.pendingIds.isEmpty) return const [];
    final collisionText = data.collisionText;
    return [
      _text(
        context,
        nightjarCollectionAcceptExplainer(
          count: data.pendingCount,
          origins: data.origins,
        ),
        key: 'nightjar_collection_explainer',
      ),
      _text(
        context,
        kNightjarCollectionPerAssetNote,
        key: 'nightjar_collection_per_asset',
      ),
      _text(
        context,
        kNightjarCollectionWarmupNote,
        key: 'nightjar_collection_warmup',
      ),
      if (collisionText != null)
        _text(
          context,
          collisionText,
          key: 'nightjar_collection_collision',
          warning: true,
        ),
      _text(context, kNightjarMetadataNotEvidenceText),
      Align(
        alignment: Alignment.centerLeft,
        child: AppButton(
          key: const ValueKey('nightjar_collection_accept_button'),
          size: AppButtonSize.small,
          variant: AppButtonVariant.secondary,
          onPressed: onAcceptAll,
          child: Text(nightjarCollectionAcceptAction(data.pendingCount)),
        ),
      ),
    ];
  }

  Widget _forgetButton() => Align(
    alignment: Alignment.centerLeft,
    child: AppButton(
      key: const ValueKey('nightjar_collection_forget_button'),
      size: AppButtonSize.small,
      variant: AppButtonVariant.ghost,
      onPressed: onForgetAll,
      child: const Text(kNightjarCollectionForgetAction),
    ),
  );

  Widget _text(
    BuildContext context,
    String text, {
    String? key,
    bool warning = false,
  }) {
    final colors = context.colors;
    return Text(
      text,
      key: key == null ? null : ValueKey(key),
      style: AppTypography.labelSmall.copyWith(
        color: warning ? colors.text.warning : colors.text.secondary,
        letterSpacing: 0,
      ),
    );
  }
}
