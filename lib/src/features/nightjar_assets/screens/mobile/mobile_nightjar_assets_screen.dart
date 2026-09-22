/// Mobile `/nightjar` — the Nightjar assets this wallet holds.
///
/// Pushed over the tab shell as a `CupertinoPage`, so its back action pops.
/// Same provider, same mapper, same feed as the desktop pane; only the
/// chrome differs.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/app_mobile_tab_bar.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_tappable.dart';
import '../../providers/nightjar_asset_metadata_provider.dart';
import '../../providers/nightjar_collection_artwork_provider.dart';
import '../../providers/nightjar_assets_view_provider.dart';
import '../../providers/nightjar_collections_provider.dart';
import '../../widgets/nightjar_asset_row_mapper.dart';
import '../../widgets/nightjar_assets_feed.dart';
import '../../widgets/nightjar_collection_data.dart';
import '../../widgets/nightjar_collection_mapper.dart';
import '../nightjar_collection_screen.dart';

class MobileNightjarAssetsScreen extends ConsumerWidget {
  const MobileNightjarAssetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final view = resolveNightjarView(ref.watch(nightjarAssetsViewProvider));
    final listing = ref.watch(nightjarAssetsListingProvider);
    final sections = view == null
        ? const <NightjarAssetsSectionData>[]
        : buildNightjarAssetSections(
            buildNightjarAssetRows(
              // Ungrouped only: a member of a collection is drawn inside it.
              assets: listing.ungrouped,
              onAssetTap: (assetId) => context.push('/nightjar/$assetId'),
              // Only assets the user accepted are in here, and nothing else
              // is consulted: building this from `view.assets` instead would
              // fetch one document per asset the wallet holds, which is the
              // disclosure `spec/asset-metadata-v0.md` section 3.1 forbids.
              logos: ref.watch(nightjarAssetLogosProvider),
            ),
          );
    final collections = view == null
        ? const <NightjarCollectionRowData>[]
        : buildNightjarCollectionRows(
            collections: listing.collections,
            onCollectionTap: (collectionId) =>
                context.push(nightjarCollectionRouteFor(collectionId)),
            // The collection's own face, per collection rather than per
            // member: one watch each, and it answers "not accepted" without
            // touching a host until the user has accepted a member.
            artworkFor: (collectionId) =>
                ref.watch(nightjarCollectionArtworkProvider(collectionId)),
          );
    final notice = view == null ? null : nightjarNoticeText(view);

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          MobileTopNav.back(
            title: 'Nightjar assets',
            onBack: () => context.pop(),
            trailing: AppTappable(
              key: const ValueKey('mobile_nightjar_receive_button'),
              onTap: () => context.push('/nightjar/receive'),
              semanticsLabel: 'Receive Nightjar assets',
              child: AppIcon(
                AppIcons.qr,
                size: AppIconSize.large,
                color: colors.icon.accent,
              ),
            ),
          ),
          Expanded(
            child: MobileBottomSafeArea(
              bottomPadding: kMobileTabBarHeight + AppSpacing.lg,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s,
                  AppSpacing.s,
                  AppSpacing.s,
                  kMobileTabBarHeight + AppSpacing.lg,
                ),
                children: [
                  if (notice != null) ...[
                    NightjarMessageCard(
                      key: const ValueKey('mobile_nightjar_assets_notice'),
                      text: notice,
                      tone: kNightjarNoticeTone,
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  NightjarAssetsFeed(
                    key: const ValueKey('mobile_nightjar_assets_feed'),
                    sections: sections,
                    collections: collections,
                    collectionsTitle: kNightjarCollectionsSectionTitle,
                    cardWidth: null,
                    isLoading: view == null,
                    errorText: view == null
                        ? null
                        : nightjarListErrorText(view),
                    errorTone: view == null
                        ? NightjarMessageTone.error
                        : nightjarListErrorTone(view),
                    emptyText: kNightjarEmptyText,
                    rowKeyPrefix: 'mobile_nightjar_assets',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
