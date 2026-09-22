/// The assets screen's list, grouped into collections once per view rather
/// than once per frame.
///
/// The grouping itself is pure and lives in `nightjar_collection_data.dart`.
/// This provider exists for a cost reason: `nightjarReplay` reports every
/// publicly issued asset on the channel — a hundred-piece collection is a
/// hundred `NjAsset` entries whether the wallet holds any of them or not — and
/// the previous shape rebuilt and re-sorted that list inside `build()` on
/// every rebuild of either assets screen. Deriving it here means the grouping
/// runs when the view changes and at no other time.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/nightjar_asset_row_data.dart';
import '../widgets/nightjar_collection_data.dart';
import 'nightjar_assets_view_provider.dart';

/// Collections and ungrouped assets for the current view.
///
/// Empty while the first load is in flight, and empty for every non-ready
/// state — the screens render the loader's own copy for those, and a partial
/// listing under an error banner would be a list the wallet is not claiming.
final nightjarAssetsListingProvider = Provider<NightjarAssetsListing>((ref) {
  final view = resolveNightjarView(ref.watch(nightjarAssetsViewProvider));
  if (view == null) return const NightjarAssetsListing.empty();
  return groupNightjarCollections(view.assets);
});

/// One collection by id, or null when the current view has no members for it.
final nightjarCollectionProvider =
    Provider.family<NightjarCollectionData?, String>((ref, collectionId) {
      return ref
          .watch(nightjarAssetsListingProvider)
          .collectionById(collectionId);
    });

/// The `asset_id`s that are drawn inside a collection rather than as a row.
///
/// Watched by the logo map so that its eager work stays proportional to the
/// flat list. Exposed as its own provider, with `updateShouldNotify` left to
/// the default, because the set changes only when the grouping does.
final nightjarGroupedMemberIdsProvider = Provider<Set<String>>((ref) {
  return ref.watch(nightjarAssetsListingProvider).groupedMemberIds;
});

/// Every asset in the current view, by id, whether grouped or not.
///
/// The collection screen needs a member's full record and reaching it through
/// [nightjarAssetsListingProvider] would mean a linear scan per tile.
final nightjarAssetByIdProvider =
    Provider.family<NightjarAssetDetailData?, String>((ref, assetId) {
      final view = resolveNightjarView(ref.watch(nightjarAssetsViewProvider));
      return view?.assetById(assetId);
    });
