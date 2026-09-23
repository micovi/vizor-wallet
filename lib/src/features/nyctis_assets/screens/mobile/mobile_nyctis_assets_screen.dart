/// Mobile `/nyctis` — the Nyctis assets this wallet holds.
///
/// Pushed over the tab shell as a `CupertinoPage`, so its back action pops.
/// Same provider, same mapper, same feed as the desktop pane; only the
/// chrome differs.
library;

import 'package:flutter/cupertino.dart'
    show CupertinoSliverRefreshControl, RefreshIndicatorMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/mobile/mobile_top_nav_circle_button.dart';
import '../../providers/nyctis_asset_metadata_provider.dart';
import '../../providers/nyctis_collection_artwork_provider.dart';
import '../../providers/nyctis_assets_view_provider.dart';
import '../../providers/nyctis_collections_provider.dart';
import '../../widgets/nyctis_asset_row_mapper.dart';
import '../../widgets/nyctis_assets_feed.dart';
import '../../widgets/nyctis_collection_data.dart';
import '../../widgets/nyctis_collection_mapper.dart';
import '../nyctis_asset_detail_screen.dart' show kNyctisReceiveRoute;
import '../nyctis_assets_screen.dart'
    show kNyctisRefreshingLabel, refreshNyctisAssets;
import '../nyctis_collection_screen.dart';
import 'mobile_nyctis_scaffold.dart';

class MobileNyctisAssetsScreen extends ConsumerWidget {
  const MobileNyctisAssetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = resolveNyctisView(ref.watch(nyctisAssetsViewProvider));
    final listing = ref.watch(nyctisAssetsListingProvider);
    final sections = view == null
        ? const <NyctisAssetsSectionData>[]
        : buildNyctisAssetSections(
            buildNyctisAssetRows(
              // Ungrouped only: a member of a collection is drawn inside it.
              assets: listing.ungrouped,
              onAssetTap: (assetId) => context.push('/nyctis/$assetId'),
              // Only assets the user accepted are in here, and nothing else
              // is consulted: building this from `view.assets` instead would
              // fetch one document per asset the wallet holds, which is the
              // disclosure `spec/asset-metadata-v0.md` section 3.1 forbids.
              logos: ref.watch(nyctisAssetLogosProvider),
            ),
          );
    final collections = view == null
        ? const <NyctisCollectionRowData>[]
        : buildNyctisCollectionRows(
            collections: listing.collections,
            onCollectionTap: (collectionId) =>
                context.push(nyctisCollectionRouteFor(collectionId)),
            // The collection's own face, per collection rather than per
            // member: one watch each, and it answers "not accepted" without
            // touching a host until the user has accepted a member.
            artworkFor: (collectionId) =>
                ref.watch(nyctisCollectionArtworkProvider(collectionId)),
          );
    final notice = view == null ? null : nyctisNoticeText(view);

    return MobileNyctisScaffold(
      topNav: MobileTopNav.back(
        title: 'Nyctis assets',
        onBack: () => context.pop(),
        trailing: MobileTopNavCircleButton(
          key: const ValueKey('mobile_nyctis_receive_button'),
          iconName: AppIcons.qr,
          semanticsLabel: 'Receive Nyctis assets',
          onPressed: () => context.push(kNyctisReceiveRoute),
        ),
      ),
      // Pull to refresh: the phone had no way to re-read the channel at all.
      body: CustomScrollView(
        key: const ValueKey('mobile_nyctis_assets_scroll'),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          CupertinoSliverRefreshControl(
            onRefresh: () => refreshNyctisAssets(ref),
            builder: _refreshIndicator,
          ),
          SliverPadding(
            padding: kNyctisMobileListPadding,
            sliver: SliverList.list(
              children: [
                if (notice != null) ...[
                  NyctisMessageCard(
                    key: const ValueKey('mobile_nyctis_assets_notice'),
                    text: notice,
                    tone: kNyctisNoticeTone,
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                NyctisAssetsFeed(
                  key: const ValueKey('mobile_nyctis_assets_feed'),
                  sections: sections,
                  collections: collections,
                  collectionsTitle: kNyctisCollectionsSectionTitle,
                  cardWidth: null,
                  isLoading: view == null,
                  errorText: view == null ? null : nyctisListErrorText(view),
                  errorDetail: view == null
                      ? null
                      : nyctisListErrorDetail(view),
                  errorTone: view == null
                      ? NyctisMessageTone.error
                      : nyctisListErrorTone(view),
                  emptyText: kNyctisEmptyText,
                  rowKeyPrefix: 'mobile_nyctis_assets',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The pull-to-refresh indicator: the shared loader, which honours reduced
/// motion, rather than the platform spinner.
Widget _refreshIndicator(
  BuildContext context,
  RefreshIndicatorMode mode,
  double pulledExtent,
  double refreshTriggerPullDistance,
  double refreshIndicatorExtent,
) {
  if (mode == RefreshIndicatorMode.inactive) return const SizedBox.shrink();
  return Center(
    child: Semantics(
      label:
          mode == RefreshIndicatorMode.refresh ||
              mode == RefreshIndicatorMode.armed
          ? kNyctisRefreshingLabel
          : null,
      child: AppIcon(
        AppIcons.loader,
        key: const ValueKey('mobile_nyctis_assets_refresh_loader'),
        size: AppIconSize.large,
        color: context.colors.icon.regular,
        animated: mode != RefreshIndicatorMode.drag,
      ),
    ),
  );
}
