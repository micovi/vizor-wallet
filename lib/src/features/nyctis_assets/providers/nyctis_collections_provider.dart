/// The assets screen's list, grouped into collections once per view rather
/// than once per frame.
///
/// The grouping itself is pure and lives in `nyctis_collection_data.dart`.
/// This provider exists for a cost reason: `nyctisReplay` reports every
/// publicly issued asset on the channel — a hundred-piece collection is a
/// hundred `NyAsset` entries whether the wallet holds any of them or not — and
/// the previous shape rebuilt and re-sorted that list inside `build()` on
/// every rebuild of either assets screen. Deriving it here means the grouping
/// runs when the view changes and at no other time.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/nyctis_asset_row_data.dart';
import '../widgets/nyctis_collection_data.dart';
import 'nyctis_assets_view_provider.dart';

/// Collections and ungrouped assets for the current view.
///
/// Empty while the first load is in flight, and empty for every non-ready
/// state — the screens render the loader's own copy for those, and a partial
/// listing under an error banner would be a list the wallet is not claiming.
final nyctisAssetsListingProvider = Provider<NyctisAssetsListing>((ref) {
  final view = resolveNyctisView(ref.watch(nyctisAssetsViewProvider));
  if (view == null) return const NyctisAssetsListing.empty();
  return groupNyctisCollections(view.assets);
});

/// One collection by id, or null when the current view has no members for it.
final nyctisCollectionProvider =
    Provider.family<NyctisCollectionData?, String>((ref, collectionId) {
      return ref
          .watch(nyctisAssetsListingProvider)
          .collectionById(collectionId);
    });

/// The `asset_id`s that are drawn inside a collection rather than as a row.
///
/// Watched by the logo map so that its eager work stays proportional to the
/// flat list. Exposed as its own provider, with `updateShouldNotify` left to
/// the default, because the set changes only when the grouping does.
final nyctisGroupedMemberIdsProvider = Provider<Set<String>>((ref) {
  return ref.watch(nyctisAssetsListingProvider).groupedMemberIds;
});

/// Every asset in the current view, by id, whether grouped or not.
///
/// The collection screen needs a member's full record and reaching it through
/// [nyctisAssetsListingProvider] would mean a linear scan per tile.
final nyctisAssetByIdProvider =
    Provider.family<NyctisAssetDetailData?, String>((ref, assetId) {
      final view = resolveNyctisView(ref.watch(nyctisAssetsViewProvider));
      return view?.assetById(assetId);
    });
