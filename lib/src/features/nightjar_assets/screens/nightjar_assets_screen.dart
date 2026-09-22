/// Desktop `/nightjar` — the Nightjar assets this wallet holds.
///
/// Mirrors `activity_screen.dart`: the screen watches the provider, the
/// mapper turns the view into rows and copy, and [NightjarAssetsFeed] is
/// handed plain values. All three degraded states (not configured, indexer
/// unreachable, indexer stale) arrive as text, not as widget branches.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_icon.dart';
import '../providers/nightjar_asset_metadata_provider.dart';
import '../providers/nightjar_collection_artwork_provider.dart';
import '../providers/nightjar_assets_view_provider.dart';
import '../providers/nightjar_collections_provider.dart';
import '../widgets/nightjar_asset_row_mapper.dart';
import '../widgets/nightjar_assets_feed.dart';
import '../widgets/nightjar_collection_data.dart';
import '../widgets/nightjar_collection_mapper.dart';
import 'nightjar_collection_screen.dart';

class NightjarAssetsScreen extends StatelessWidget {
  const NightjarAssetsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppDesktopShell(
      sidebar: AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NightjarAssetsPane(),
      ),
    );
  }
}

/// The pane body, without the sidebar, so it can be rendered on its own in
/// tests and in Widgetbook.
class NightjarAssetsPane extends ConsumerWidget {
  const NightjarAssetsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(nightjarAssetsViewProvider);
    final view = resolveNightjarView(async);
    // Grouped once per view rather than once per frame; a hundred-piece
    // collection is a hundred assets to walk.
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

    return AppPaneScrollScaffold(
      toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: kNightjarCardWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _NightjarAssetsHeader(),
              const SizedBox(height: AppSpacing.base),
              if (notice != null) ...[
                NightjarMessageCard(
                  key: const ValueKey('nightjar_assets_notice'),
                  text: notice,
                  width: kNightjarCardWidth,
                  tone: kNightjarNoticeTone,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              NightjarAssetsFeed(
                key: const ValueKey('nightjar_assets_feed'),
                sections: sections,
                collections: collections,
                collectionsTitle: kNightjarCollectionsSectionTitle,
                isLoading: view == null,
                errorText: view == null ? null : nightjarListErrorText(view),
                errorDetail: view == null
                    ? null
                    : nightjarListErrorDetail(view),
                errorTone: view == null
                    ? NightjarMessageTone.error
                    : nightjarListErrorTone(view),
                emptyText: kNightjarEmptyText,
                rowKeyPrefix: 'nightjar_assets',
              ),
              const SizedBox(height: AppSpacing.base),
            ],
          ),
        ),
      ),
    );
  }
}

class _NightjarAssetsHeader extends ConsumerWidget {
  const _NightjarAssetsHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Nightjar assets',
              style: AppTypography.headlineSmall.copyWith(
                color: colors.text.accent,
              ),
            ),
          ),
          // A channel is read once and cached, and there is nothing else that
          // invalidates it: a note that arrives while this screen is open, or
          // one that arrives between opening it and looking again, is simply
          // not there. Without this the only way to re-read was to restart the
          // app, and "I refreshed and it still says zero" is what that looks
          // like from the outside.
          AppButton(
            key: const ValueKey('nightjar_assets_refresh_button'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.ghost,
            onPressed: () => ref.invalidate(nightjarAssetsViewProvider),
            leading: const AppIcon(AppIcons.renew, size: AppIconSize.medium),
            child: const Text('Refresh'),
          ),
          const SizedBox(width: AppSpacing.xs),
          AppButton(
            key: const ValueKey('nightjar_assets_receive_button'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.secondary,
            onPressed: () => context.push('/nightjar/receive'),
            leading: const AppIcon(AppIcons.qr, size: AppIconSize.medium),
            child: const Text('Receive'),
          ),
        ],
      ),
    );
  }
}
