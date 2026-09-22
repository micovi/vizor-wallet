/// The provider-connected collection widgets.
///
/// Everything here is a thin wiring layer over a presentational widget, for
/// the same reason `nightjar_asset_metadata_section.dart` is: the places that
/// can turn a user action into a metadata fetch should be few, named, and
/// obvious. There are exactly two of them for collections — the accept button
/// on [NightjarCollectionAcceptanceSection], and the moment a
/// [NightjarCollectionMemberTile] is first built for a piece the user has
/// already accepted.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../models/nightjar_asset_acceptance.dart';
import '../providers/nightjar_asset_acceptance_provider.dart';
import '../providers/nightjar_asset_metadata_provider.dart';
import '../providers/nightjar_collection_artwork_provider.dart';
import 'nightjar_asset_logo.dart';
import 'nightjar_asset_row_data.dart';
import 'nightjar_collection_acceptance_card.dart';
import 'nightjar_collection_data.dart';
import 'nightjar_collection_grid.dart';
import 'nightjar_collection_mapper.dart';

/// Side of the artwork on a single piece's screen.
///
/// Large enough to be the point of the screen rather than a decoration beside
/// the facts, and bounded so that it stays one image: the decode ceiling that
/// goes with it is [kNightjarArtworkMaxDecodePixels], which is affordable
/// precisely because nothing shows two of these at once.
const double kNightjarUniqueArtworkSize = 280;

/// The accept-the-whole-collection card, wired to the acceptance notifier.
class NightjarCollectionAcceptanceSection extends ConsumerWidget {
  const NightjarCollectionAcceptanceSection({
    required this.collection,
    super.key,
  });

  /// Null while the view is loading, or when it holds no such collection.
  final NightjarCollectionData? collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = this.collection;
    if (collection == null) return const SizedBox.shrink();

    final acceptance = ref.watch(nightjarAssetAcceptanceProvider);
    final data = buildNightjarCollectionAcceptanceData(
      collection: collection,
      acceptance: acceptance,
    );

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: NightjarCollectionAcceptanceCard(
        key: const ValueKey('nightjar_collection_acceptance'),
        data: data,
        onAcceptAll: data.pendingIds.isEmpty
            ? null
            : () => unawaited(
                ref.read(nightjarAssetAcceptanceProvider.notifier).acceptMany([
                  // The **signed** name and symbol, per member. Not a
                  // collection-level label: the stored record is what a
                  // later acceptance is warned against, and warning
                  // against a derived title would warn about a string no
                  // issuer ever signed.
                  for (final member in collection.members)
                    if (data.pendingIds.contains(member.assetId))
                      NightjarAcceptedAsset(
                        assetId: member.assetId,
                        name: member.name,
                        symbol: member.symbol,
                      ),
                ]),
              ),
        onForgetAll: () => unawaited(
          ref
              .read(nightjarAssetAcceptanceProvider.notifier)
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
/// `nightjar_collection_artwork_provider.dart`.
///
/// Nothing it fetches is drawn without acceptance: every pixel still goes
/// through [nightjarAssetArtworkProvider], which gates on it.
class NightjarCollectionArtworkWarmup extends ConsumerWidget {
  const NightjarCollectionArtworkWarmup({
    required this.collectionId,
    super.key,
  });

  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(nightjarCollectionArtworkWarmupProvider(collectionId));
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
class NightjarCollectionMemberTile extends ConsumerWidget {
  const NightjarCollectionMemberTile({
    required this.member,
    this.onTap,
    super.key,
  });

  final NightjarAssetDetailData member;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NightjarCollectionTile(
      member: member,
      artwork: ref.watch(nightjarAssetArtworkProvider(member.assetId)),
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
class NightjarUniqueItemSection extends ConsumerWidget {
  const NightjarUniqueItemSection({required this.asset, super.key});

  /// Null while the view is loading, or when it does not hold this asset.
  final NightjarAssetDetailData? asset;

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
      ref.watch(nightjarCollectionArtworkWarmupProvider(collectionId));
    }

    final artwork = ref.watch(nightjarAssetArtworkProvider(asset.assetId));
    // `spec/asset-collection-v0.md` section 3.3 and `spec/asset-metadata-v0.md`
    // section 2.1 both put the pinned/unpinned statement "where it says where
    // the artwork came from", and this screen is that place: it is the one
    // surface with room for the whole chain — the image's digest, then the
    // document's.
    final provenance = nightjarArtworkProvenanceText(artwork);
    final documentPin = nightjarArtworkDocumentPinText(artwork);

    return Padding(
      key: const ValueKey('nightjar_unique_item_header'),
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          NightjarArtwork(
            bytes: artwork.bytes,
            size: kNightjarUniqueArtworkSize,
            emptyText: nightjarArtworkDetailText(artwork.status),
            maxDecodePixels: kNightjarArtworkMaxDecodePixels,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            nightjarCollectionMemberTitle(asset),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.bodyMediumStrong.copyWith(
              color: colors.text.accent,
            ),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            nightjarCollectionMemberSubtitle(asset),
            key: const ValueKey('nightjar_unique_item_asset_id'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.labelSmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            asset.ownsUniqueItem
                ? kNightjarUniqueItemOwnedHeadline
                : kNightjarUniqueItemNotOwnedHeadline,
            textAlign: TextAlign.center,
            style: AppTypography.labelSmall.copyWith(
              color: asset.ownsUniqueItem
                  ? colors.text.success
                  : colors.text.secondary,
            ),
          ),
          if (provenance != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              provenance,
              key: const ValueKey('nightjar_artwork_provenance'),
              textAlign: TextAlign.center,
              style: AppTypography.labelSmall.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
          if (documentPin != null) ...[
            const SizedBox(height: AppSpacing.xxs),
            Text(
              documentPin,
              key: const ValueKey('nightjar_artwork_document_pin'),
              textAlign: TextAlign.center,
              style: AppTypography.labelSmall.copyWith(
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
const String kNightjarUniqueItemOwnedHeadline = 'This wallet holds this piece';
const String kNightjarUniqueItemNotOwnedHeadline =
    'This wallet does not hold this piece';
