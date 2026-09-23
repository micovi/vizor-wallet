/// The provider-connected collection widgets.
///
/// Everything here is a thin wiring layer over a presentational widget, for
/// the same reason `nyctis_asset_metadata_section.dart` is: the places that
/// can turn a user action into a metadata fetch should be few, named, and
/// obvious. There are exactly two of them for collections — the accept button
/// on [NyctisCollectionAcceptanceSection], and the moment a
/// [NyctisCollectionMemberTile] is first built for a piece the user has
/// already accepted.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import '../models/nyctis_asset_acceptance.dart';
import '../models/nyctis_metadata_pointer.dart';
import '../providers/nyctis_asset_acceptance_provider.dart';
import '../providers/nyctis_asset_metadata_provider.dart';
import '../providers/nyctis_collection_artwork_provider.dart';
import 'nyctis_acceptance_controls.dart';
import 'nyctis_artwork_data.dart';
import 'nyctis_asset_logo.dart';
import 'nyctis_asset_row_data.dart';
import 'nyctis_collection_acceptance_card.dart';
import 'nyctis_collection_data.dart';
import 'nyctis_collection_grid.dart';
import 'nyctis_collection_mapper.dart';

/// Side of the artwork on a single piece's screen.
///
/// Large enough to be the point of the screen rather than a decoration beside
/// the facts, and bounded so that it stays one image: the decode ceiling that
/// goes with it is [kNyctisArtworkMaxDecodePixels], which is affordable
/// precisely because nothing shows two of these at once.
const double kNyctisUniqueArtworkSize = 280;

/// The accept-the-whole-collection card, wired to the acceptance notifier.
class NyctisCollectionAcceptanceSection extends ConsumerWidget {
  const NyctisCollectionAcceptanceSection({
    required this.collection,
    super.key,
  });

  /// Null while the view is loading, or when it holds no such collection.
  final NyctisCollectionData? collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = this.collection;
    if (collection == null) return const SizedBox.shrink();

    final acceptance = ref.watch(nyctisAssetAcceptanceProvider);
    // Read for its progress only. The same provider is already watched by
    // [NyctisCollectionArtworkWarmup] on this screen, and it fetches
    // nothing until a member is accepted, so watching it here adds no
    // request.
    final warmup = ref.watch(
      nyctisCollectionArtworkWarmupProvider(collection.collectionId),
    );
    final anyAccepted = collection.members.any(
      (member) => acceptance.isAccepted(member.assetId),
    );
    final result = warmup.asData?.value;
    final data = buildNyctisCollectionAcceptanceData(
      collection: collection,
      acceptance: acceptance,
      warmupMaxBytes: kNyctisCollectionWarmupMaxBytes,
      warmupPhase: !anyAccepted
          ? NyctisCollectionWarmupPhase.idle
          : warmup.isLoading || result == null
          ? NyctisCollectionWarmupPhase.running
          : NyctisCollectionWarmupPhase.done,
      warmupFetched: result?.requested ?? 0,
      warmupComplete: result?.complete ?? true,
    );

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: NyctisCollectionAcceptanceCard(
        key: const ValueKey('nyctis_collection_acceptance'),
        data: data,
        onAcceptAll: data.pendingIds.isEmpty
            ? null
            : () => unawaited(
                ref.read(nyctisAssetAcceptanceProvider.notifier).acceptMany([
                  // The **signed** name and symbol, per member. Not a
                  // collection-level label: the stored record is what a
                  // later acceptance is warned against, and warning
                  // against a derived title would warn about a string no
                  // issuer ever signed.
                  for (final member in collection.members)
                    if (data.pendingIds.contains(member.assetId))
                      NyctisAcceptedAsset(
                        assetId: member.assetId,
                        name: member.name,
                        symbol: member.symbol,
                      ),
                ]),
              ),
        onForgetAll: () => unawaited(
          ref
              .read(nyctisAssetAcceptanceProvider.notifier)
              .revokeMany(collection.memberIds),
        ),
      ),
    );
  }
}

/// The one place a stored acceptance turns into a burst of network requests.
///
/// It draws nothing. It exists as a named widget rather than as a `ref.watch`
/// tucked inside the grid because the rule it implements is a privacy decision
/// and not a loading strategy: warming **every** member of the collection is
/// what keeps the set of images the host sees from being the set of pieces the
/// user accepted, which — since users accept what they hold — is otherwise the
/// holdings disclosure `spec/asset-collection-v0.md` section 5 exists to
/// prevent. The whole argument, and the options rejected, are in
/// `nyctis_collection_artwork_provider.dart`.
///
/// Nothing it fetches is drawn without acceptance: every pixel still goes
/// through [nyctisAssetArtworkProvider], which gates on it.
class NyctisCollectionArtworkWarmup extends ConsumerWidget {
  const NyctisCollectionArtworkWarmup({
    required this.collectionId,
    super.key,
  });

  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(nyctisCollectionArtworkWarmupProvider(collectionId));
    return const SizedBox.shrink();
  }
}

/// One grid tile, subscribed to its own piece's logo and nothing else.
///
/// The subscription is per tile on purpose. Reading the whole logo map here
/// would rebuild every visible tile each time any one document arrived, and
/// — worse — would keep a hundred `FutureProvider`s alive for a collection
/// whose grid shows twelve. A tile that is scrolled past is disposed, and a
/// tile that is never built never asks its host for anything.
class NyctisCollectionMemberTile extends ConsumerWidget {
  const NyctisCollectionMemberTile({
    required this.member,
    this.onTap,
    super.key,
  });

  final NyctisAssetDetailData member;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NyctisCollectionTile(
      member: member,
      artwork: ref.watch(nyctisAssetArtworkProvider(member.assetId)),
      onTap: onTap,
    );
  }
}

/// The header of a unique item's own screen: the artwork at a size worth
/// looking at, the piece's name, its index, and — always — its `asset_id`.
///
/// The last of those is not negotiable and is why the id sits under the
/// picture rather than in the facts card below. Section 5 of
/// `spec/asset-metadata-v0.md`: a wallet **MUST** show `asset_id`, or an
/// unambiguous abbreviation of it, wherever it shows a logo. A piece of
/// artwork at 280 pixels is the most persuasive thing this feature draws, and
/// a name, a symbol and the right picture are a convincing imitation of
/// another asset; the id is the part that cannot be copied.
class NyctisUniqueItemSection extends ConsumerWidget {
  const NyctisUniqueItemSection({required this.asset, super.key});

  /// Null while the view is loading, or when it does not hold this asset.
  final NyctisAssetDetailData? asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = this.asset;
    if (asset == null || !asset.isUniqueItem) return const SizedBox.shrink();
    final colors = context.colors;

    // The other way into a piece. Normally a user reaches this screen through
    // the collection grid, which has already warmed the whole collection — but
    // a restored route or a link lands here directly, and fetching this one
    // piece's artwork alone would disclose exactly which piece
    // (`spec/asset-collection-v0.md` section 2.1). Warming from here makes the
    // request set the same either way.
    final collectionId = asset.collection?.trim();
    if (collectionId != null && collectionId.isNotEmpty) {
      ref.watch(nyctisCollectionArtworkWarmupProvider(collectionId));
    }

    final artwork = ref.watch(nyctisAssetArtworkProvider(asset.assetId));
    // `spec/asset-collection-v0.md` section 3.3 and `spec/asset-metadata-v0.md`
    // section 2.1 both put the pinned/unpinned statement "where it says where
    // the artwork came from", and this screen is that place: it is the one
    // surface with room for the whole chain — the image's digest, then the
    // document's.
    final provenance = nyctisArtworkProvenanceText(artwork);
    final documentPin = nyctisArtworkDocumentPinText(artwork);
    final title = nyctisCollectionMemberTitle(asset);

    // The accept control lives in the frame, next to the id, because this is
    // where the page says the artwork is not shown. It used to sit below the
    // identity card, off screen under 280 pixels of picture.
    final acceptance = ref.watch(nyctisAssetAcceptanceProvider);
    final canShow =
        artwork.status == NyctisArtworkStatus.notAccepted &&
        readNyctisMetadataUri(asset.metadataUri).isResolvable;
    final collides =
        canShow &&
        acceptance
            .collisionsWith(
              assetId: asset.assetId,
              name: asset.name,
              symbol: asset.symbol,
            )
            .isNotEmpty;

    return Padding(
      key: const ValueKey('nyctis_unique_item_header'),
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          NyctisArtwork(
            bytes: artwork.bytes,
            size: kNyctisUniqueArtworkSize,
            emptyText: nyctisArtworkDetailText(artwork.status),
            maxDecodePixels: kNyctisArtworkMaxDecodePixels,
            semanticLabel:
                'Artwork for $title, ${nyctisArtworkSpokenState(artwork.status)}',
          ),
          const SizedBox(height: AppSpacing.xs),
          // The page's heading: the detail body drops its own title when this
          // header is drawn, so the name is not said twice.
          Semantics(
            header: true,
            child: Text(
              title,
              key: const ValueKey('nyctis_unique_item_title'),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.headlineLarge.copyWith(
                color: colors.text.accent,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            nyctisCollectionMemberSubtitle(asset),
            key: const ValueKey('nyctis_unique_item_asset_id'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (asset.ownsUniqueItem) ...[
                ExcludeSemantics(
                  child: AppIcon(
                    AppIcons.checkCircle,
                    size: AppIconSize.medium,
                    color: colors.icon.regular,
                  ),
                ),
                const SizedBox(width: AppSpacing.xxs),
              ],
              Flexible(
                child: Text(
                  asset.ownsUniqueItem
                      ? kNyctisUniqueItemOwnedHeadline
                      : kNyctisUniqueItemNotOwnedHeadline,
                  key: const ValueKey('nyctis_unique_item_owned'),
                  textAlign: TextAlign.center,
                  // `text.primary` and a check glyph, not the gold success
                  // colour: that is 3.35:1 on white in the light theme.
                  style: AppTypography.bodySmall.copyWith(
                    color: asset.ownsUniqueItem
                        ? colors.text.primary
                        : colors.text.secondary,
                  ),
                ),
              ),
            ],
          ),
          if (canShow) ...[
            const SizedBox(height: AppSpacing.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: kNyctisUniqueArtworkSize,
              ),
              child: NyctisGuardedAcceptButton(
                key: const ValueKey('nyctis_unique_item_show_artwork'),
                buttonKey: const ValueKey(
                  'nyctis_unique_item_show_artwork_button',
                ),
                confirmKey: const ValueKey(
                  'nyctis_unique_item_show_artwork_confirm',
                ),
                label: kNyctisShowArtworkAction,
                requiresConfirmation: collides,
                onAccept: () => unawaited(
                  ref
                      .read(nyctisAssetAcceptanceProvider.notifier)
                      .accept(
                        assetId: asset.assetId,
                        name: asset.name,
                        symbol: asset.symbol,
                      ),
                ),
              ),
            ),
          ],
          if (provenance != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              provenance,
              key: const ValueKey('nyctis_artwork_provenance'),
              textAlign: TextAlign.center,
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
          if (documentPin != null) ...[
            const SizedBox(height: AppSpacing.xxs),
            Text(
              documentPin,
              key: const ValueKey('nyctis_artwork_document_pin'),
              textAlign: TextAlign.center,
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The line under a piece's artwork that says whether it is this wallet's.
///
/// A sentence rather than a number, for the same reason the list row says
/// `Owned` rather than `1`: there is no quantity of a unique item to state,
/// and the interesting fact is one nobody but this wallet can compute.
const String kNyctisUniqueItemOwnedHeadline = 'This wallet holds this piece';
const String kNyctisUniqueItemNotOwnedHeadline =
    'This wallet does not hold this piece';
