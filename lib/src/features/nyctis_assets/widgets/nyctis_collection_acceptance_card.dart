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
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../core/widgets/review_wrap_card.dart';
import '../models/nyctis_asset_acceptance.dart';
import '../models/nyctis_metadata_pointer.dart';
import 'nyctis_acceptance_controls.dart';
import 'nyctis_collection_data.dart';
import 'nyctis_collection_mapper.dart';
import 'nyctis_interactive.dart';
import 'nyctis_metadata_copy.dart';

/// Where the collection's artwork warm-up is, for the progress line.
enum NyctisCollectionWarmupPhase {
  /// Nothing accepted, so nothing is being fetched.
  idle,

  /// Fetching every member's artwork, in index order.
  running,

  /// Finished — completely, or stopped at its byte budget.
  done,
}

/// Everything the card renders, already decided.
class NyctisCollectionAcceptanceData {
  const NyctisCollectionAcceptanceData({
    required this.collectionId,
    required this.state,
    required this.memberCount,
    required this.acceptedCount,
    required this.pendingIds,
    required this.origins,
    this.collisionText,
    this.collidingIds = const [],
    this.collisions = const [],
    this.warmupMaxBytes,
    this.warmupPhase = NyctisCollectionWarmupPhase.idle,
    this.warmupFetched = 0,
    this.warmupComplete = true,
  });

  final String collectionId;
  final NyctisCollectionAcceptanceState state;

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

  /// The colliding pieces' ids.
  final List<String> collidingIds;

  /// Each colliding piece with the accepted asset it matches, so the card can
  /// show the ids side by side.
  final List<NyctisCollectionCollision> collisions;

  /// The warm-up's byte budget, stated in the copy when known.
  final int? warmupMaxBytes;

  final NyctisCollectionWarmupPhase warmupPhase;

  /// Pieces whose artwork the finished warm-up asked for.
  final int warmupFetched;

  /// Whether the finished warm-up covered every piece.
  final bool warmupComplete;

  int get pendingCount => pendingIds.length;

  bool get hasCollision => collisionText != null;

  /// True when there is nothing here this wallet would ever fetch.
  bool get hasNothingToFetch =>
      pendingIds.isEmpty && state == NyctisCollectionAcceptanceState.none;
}

/// Builds the card's values from a collection and the accepted set.
///
/// The warm-up values come from the provider that runs it; a fixture or a test
/// that leaves them out gets a card with no progress line.
NyctisCollectionAcceptanceData buildNyctisCollectionAcceptanceData({
  required NyctisCollectionData collection,
  required NyctisAssetAcceptance acceptance,
  int? warmupMaxBytes,
  NyctisCollectionWarmupPhase warmupPhase =
      NyctisCollectionWarmupPhase.idle,
  int warmupFetched = 0,
  bool warmupComplete = true,
}) {
  final unaccepted = nyctisUnacceptedMembers(
    collection: collection,
    acceptance: acceptance,
  );
  // Only members with a resolvable pointer are offered. `readNyctisMetadataUri`
  // is the same reader the per-asset card uses, so a piece refused there — an
  // `http:` link, an `ipfs:` one, a malformed digest — is refused here too
  // rather than quietly accepted into a set that will never draw anything.
  final fetchable = [
    for (final member in unaccepted)
      if (readNyctisMetadataUri(member.metadataUri).isResolvable) member,
  ];
  var accepted = 0;
  for (final member in collection.members) {
    if (acceptance.isAccepted(member.assetId)) accepted++;
  }
  return NyctisCollectionAcceptanceData(
    collectionId: collection.collectionId,
    state: nyctisCollectionAcceptanceState(
      collection: collection,
      acceptance: acceptance,
    ),
    memberCount: collection.memberCount,
    acceptedCount: accepted,
    pendingIds: [for (final member in fetchable) member.assetId],
    origins: nyctisCollectionFetchOrigins(fetchable),
    collisionText: nyctisCollectionCollisionText(
      collection: collection,
      acceptance: acceptance,
    ),
    collidingIds: nyctisCollectionCollidingIds(
      collection: collection,
      acceptance: acceptance,
    ),
    collisions: nyctisCollectionCollisions(
      collection: collection,
      acceptance: acceptance,
    ),
    warmupMaxBytes: warmupMaxBytes,
    warmupPhase: warmupPhase,
    warmupFetched: warmupFetched,
    warmupComplete: warmupComplete,
  );
}

/// How many colliding pairs the card draws before summarising the rest.
const int kNyctisCollisionLinesShown = 3;

/// The card itself.
class NyctisCollectionAcceptanceCard extends StatelessWidget {
  const NyctisCollectionAcceptanceCard({
    required this.data,
    this.onAcceptAll,
    this.onForgetAll,
    super.key,
  });

  final NyctisCollectionAcceptanceData data;

  /// Accepts every id in [NyctisCollectionAcceptanceData.pendingIds]. Null
  /// renders the card read-only — a Widgetbook fixture, or a screen with no
  /// wallet behind it.
  final VoidCallback? onAcceptAll;

  final VoidCallback? onForgetAll;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final children = <Widget>[
      Semantics(
        header: true,
        child: Text(
          kNyctisCollectionAcceptTitle,
          style: AppTypography.labelLarge.copyWith(
            color: colors.text.secondary,
            fontWeight: FontWeight.w600,
          ),
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
          kNyctisCollectionNothingToFetchText,
          key: 'nyctis_collection_nothing_to_fetch',
        ),
      ];
    }

    return switch (data.state) {
      NyctisCollectionAcceptanceState.all => [
        _text(
          context,
          nyctisCollectionAcceptedText(data.acceptedCount),
          key: 'nyctis_collection_accepted',
          primary: true,
        ),
        ?_progress(context),
        _text(context, kNyctisMetadataNotEvidenceText),
        _forgetButton(),
      ],
      NyctisCollectionAcceptanceState.partial => [
        _text(
          context,
          nyctisCollectionPartialText(
            accepted: data.acceptedCount,
            total: data.memberCount,
          ),
          key: 'nyctis_collection_partial',
          primary: true,
        ),
        ?_progress(context),
        ..._offer(context),
        _forgetButton(),
      ],
      NyctisCollectionAcceptanceState.none => _offer(context),
    };
  }

  /// One sentence, the collision if any, the button — then the rest behind
  /// "What this means".
  List<Widget> _offer(BuildContext context) {
    if (data.pendingIds.isEmpty) return const [];
    final collisionText = data.collisionText;
    final shown = data.collisions.take(kNyctisCollisionLinesShown).toList();
    return [
      _text(
        context,
        nyctisCollectionAcceptLead(origins: data.origins),
        key: 'nyctis_collection_lead',
        primary: true,
      ),
      if (collisionText != null)
        NyctisCollisionPanel(
          key: const ValueKey('nyctis_collection_collision'),
          text: collisionText,
          lines: [
            for (final collision in shown) ...[
              NyctisIdentityLineData(
                label: kNyctisCollisionExistingLabel,
                name: collision.existingLabel,
                assetId: collision.existingId,
              ),
              NyctisIdentityLineData(
                label: 'Piece in this collection',
                name: collision.memberLabel,
                assetId: collision.memberId,
              ),
            ],
          ],
          moreCount: data.collisions.length - shown.length,
        ),
      NyctisGuardedAcceptButton(
        buttonKey: const ValueKey('nyctis_collection_accept_button'),
        confirmKey: const ValueKey('nyctis_collection_confirm_button'),
        label: nyctisCollectionAcceptAction(data.pendingCount),
        requiresConfirmation: data.hasCollision,
        onAccept: onAcceptAll,
      ),
      NyctisDisclosure(
        key: const ValueKey('nyctis_collection_details'),
        toggleKey: const ValueKey('nyctis_collection_details_toggle'),
        title: kNyctisWhatThisMeansTitle,
        builder: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _text(
              context,
              nyctisCollectionAcceptExplainer(
                count: data.pendingCount,
                origins: data.origins,
              ),
              key: 'nyctis_collection_explainer',
            ),
            const SizedBox(height: AppSpacing.xs),
            _text(
              context,
              kNyctisCollectionPerAssetNote,
              key: 'nyctis_collection_per_asset',
            ),
            const SizedBox(height: AppSpacing.xs),
            _text(
              context,
              nyctisCollectionWarmupNote(maxBytes: data.warmupMaxBytes),
              key: 'nyctis_collection_warmup',
            ),
            const SizedBox(height: AppSpacing.xs),
            _text(context, kNyctisMetadataNotEvidenceText),
          ],
        ),
      ),
    ];
  }

  /// The warm-up's progress, once anything is accepted.
  Widget? _progress(BuildContext context) {
    final colors = context.colors;
    switch (data.warmupPhase) {
      case NyctisCollectionWarmupPhase.idle:
        return null;
      case NyctisCollectionWarmupPhase.running:
        return Semantics(
          liveRegion: true,
          child: Row(
            key: const ValueKey('nyctis_collection_warmup_running'),
            children: [
              AppIcon(
                AppIcons.loader,
                size: AppIconSize.medium,
                color: colors.icon.regular,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: _text(context, kNyctisCollectionWarmupRunningText),
              ),
            ],
          ),
        );
      case NyctisCollectionWarmupPhase.done:
        return Semantics(
          liveRegion: true,
          child: _text(
            context,
            nyctisCollectionWarmupProgressText(
              fetched: data.warmupFetched,
              total: data.memberCount,
              complete: data.warmupComplete,
            ),
            key: 'nyctis_collection_warmup_done',
          ),
        );
    }
  }

  Widget _forgetButton() => Align(
    alignment: Alignment.centerLeft,
    child: AppButton(
      key: const ValueKey('nyctis_collection_forget_button'),
      size: AppButtonSize.small,
      // Long labels wrap at large text instead of overflowing.
      growWithContent: true,
      constrainContent: true,
      variant: AppButtonVariant.ghost,
      onPressed: onForgetAll,
      child: const Text(kNyctisCollectionForgetAction),
    ),
  );

  /// Paragraphs are `bodySmall`, not the 12px label style: they are sentences
  /// the user has to read before a decision.
  Widget _text(
    BuildContext context,
    String text, {
    String? key,
    bool primary = false,
  }) {
    final colors = context.colors;
    return Text(
      text,
      key: key == null ? null : ValueKey(key),
      style: AppTypography.bodySmall.copyWith(
        color: primary ? colors.text.primary : colors.text.secondary,
        letterSpacing: 0,
      ),
    );
  }
}
