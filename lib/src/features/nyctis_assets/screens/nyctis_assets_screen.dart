/// Desktop `/nyctis` — the Nyctis assets this wallet holds.
///
/// Mirrors `activity_screen.dart`: the screen watches the provider, the
/// mapper turns the view into rows and copy, and [NyctisAssetsFeed] is
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
import '../providers/nyctis_asset_metadata_provider.dart';
import '../providers/nyctis_collection_artwork_provider.dart';
import '../providers/nyctis_assets_view_provider.dart';
import '../providers/nyctis_collections_provider.dart';
import '../widgets/nyctis_asset_row_mapper.dart';
import '../widgets/nyctis_assets_feed.dart';
import '../widgets/nyctis_collection_data.dart';
import '../widgets/nyctis_collection_mapper.dart';
import 'nyctis_asset_detail_screen.dart' show kNyctisReceiveRoute;
import 'nyctis_collection_screen.dart';

class NyctisAssetsScreen extends StatelessWidget {
  const NyctisAssetsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppDesktopShell(
      sidebar: AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NyctisAssetsPane(),
      ),
    );
  }
}

/// The pane body, without the sidebar, so it can be rendered on its own in
/// tests and in Widgetbook.
class NyctisAssetsPane extends ConsumerWidget {
  const NyctisAssetsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(nyctisAssetsViewProvider);
    final view = resolveNyctisView(async);
    // Grouped once per view rather than once per frame; a hundred-piece
    // collection is a hundred assets to walk.
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

    return AppPaneScrollScaffold(
      toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: kNyctisCardWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _NyctisAssetsHeader(),
              const SizedBox(height: AppSpacing.base),
              if (notice != null) ...[
                NyctisMessageCard(
                  key: const ValueKey('nyctis_assets_notice'),
                  text: notice,
                  width: kNyctisCardWidth,
                  tone: kNyctisNoticeTone,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              NyctisAssetsFeed(
                key: const ValueKey('nyctis_assets_feed'),
                sections: sections,
                collections: collections,
                collectionsTitle: kNyctisCollectionsSectionTitle,
                isLoading: view == null,
                errorText: view == null ? null : nyctisListErrorText(view),
                errorDetail: view == null
                    ? null
                    : nyctisListErrorDetail(view),
                errorTone: view == null
                    ? NyctisMessageTone.error
                    : nyctisListErrorTone(view),
                emptyText: kNyctisEmptyText,
                rowKeyPrefix: 'nyctis_assets',
              ),
              const SizedBox(height: AppSpacing.base),
            ],
          ),
        ),
      ),
    );
  }
}

/// Re-reads the channel and completes when the new view has resolved, for a
/// pull-to-refresh that should stop spinning when the data is back.
///
/// A failed read is not thrown: the view provider folds it into the
/// unreachable state, and the screen renders that.
Future<void> refreshNyctisAssets(WidgetRef ref) async {
  ref.invalidate(nyctisAssetsViewProvider);
  try {
    await ref.read(nyctisAssetsViewProvider.future);
  } catch (_) {}
}

/// The Refresh button's label while a re-read is in flight.
const String kNyctisRefreshingLabel = 'Refreshing…';

class _NyctisAssetsHeader extends ConsumerWidget {
  const _NyctisAssetsHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    // `resolveNyctisView` keeps showing the previous view while a reload
    // runs, so without this the button did nothing visible at all.
    final refreshing = ref.watch(
      nyctisAssetsViewProvider.select((async) => async.isLoading),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
          child: Semantics(
            header: true,
            child: Text(
              'Nyctis assets',
              key: const ValueKey('nyctis_assets_title'),
              textAlign: TextAlign.center,
              style: AppTypography.headlineLarge.copyWith(
                color: colors.text.accent,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            // A channel is read once and cached, and there is nothing else
            // that invalidates it: a note that arrives while this screen is
            // open, or one that arrives between opening it and looking again,
            // is simply not there. Without this the only way to re-read was to
            // restart the app, and "I refreshed and it still says zero" is
            // what that looks like from the outside.
            Semantics(
              liveRegion: true,
              child: AppButton(
                key: const ValueKey('nyctis_assets_refresh_button'),
                size: AppButtonSize.small,
                variant: AppButtonVariant.ghost,
                onPressed: refreshing
                    ? null
                    : () => ref.invalidate(nyctisAssetsViewProvider),
                leading: AppIcon(
                  refreshing ? AppIcons.loader : AppIcons.renew,
                  key: refreshing
                      ? const ValueKey('nyctis_assets_refresh_loader')
                      : null,
                  size: AppIconSize.medium,
                ),
                child: Text(refreshing ? kNyctisRefreshingLabel : 'Refresh'),
              ),
            ),
            AppButton(
              key: const ValueKey('nyctis_assets_receive_button'),
              size: AppButtonSize.small,
              variant: AppButtonVariant.secondary,
              onPressed: () => context.push(kNyctisReceiveRoute),
              leading: const AppIcon(AppIcons.qr, size: AppIconSize.medium),
              child: const Text('Receive'),
            ),
          ],
        ),
      ],
    );
  }
}
