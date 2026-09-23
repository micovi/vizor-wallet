/// Mobile `/nyctis/collection/:collectionId` — the pieces of one
/// collection.
///
/// Same slivers as the desktop pane, in the phone's own `CustomScrollView`.
/// The scroll view is here rather than a `ListView` wrapping a grid for the
/// reason the desktop file gives: this is the surface that decides whether a
/// hundred-piece collection decodes twelve images or a hundred.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../providers/nyctis_assets_view_provider.dart';
import '../../providers/nyctis_collections_provider.dart';
import '../../widgets/nyctis_asset_row_data.dart';
import '../../widgets/nyctis_collection_mapper.dart';
import '../nyctis_collection_screen.dart';
import 'mobile_nyctis_scaffold.dart';

class MobileNyctisCollectionScreen extends ConsumerWidget {
  const MobileNyctisCollectionScreen({required this.collectionId, super.key});

  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(nyctisCollectionProvider(collectionId));
    final view = resolveNyctisView(ref.watch(nyctisAssetsViewProvider));

    return MobileNyctisScaffold(
      topNav: MobileTopNav.back(
        title: collection != null
            ? nyctisCollectionTitle(collection)
            : view == null
            ? kNyctisCollectionsSectionTitle
            : truncateNyctisAssetId(collectionId),
        onBack: () => context.pop(),
      ),
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.s)),
          ...buildNyctisCollectionSlivers(
            collectionId: collectionId,
            collection: collection,
            view: view,
            // The top nav already carries the title.
            showTitle: false,
            horizontalPadding: kNyctisMobileSidePadding,
            onMemberTap: (assetId) => context.push('/nyctis/$assetId'),
          ),
          const SliverToBoxAdapter(
            child: SizedBox(height: kNyctisMobileBottomPadding),
          ),
        ],
      ),
    );
  }
}
