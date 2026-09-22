/// Mobile `/nightjar/collection/:collectionId` — the pieces of one
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

import '../../../../core/layout/mobile/app_mobile_tab_bar.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../providers/nightjar_collections_provider.dart';
import '../../widgets/nightjar_asset_row_data.dart';
import '../../widgets/nightjar_collection_mapper.dart';
import '../nightjar_collection_screen.dart';

class MobileNightjarCollectionScreen extends ConsumerWidget {
  const MobileNightjarCollectionScreen({required this.collectionId, super.key});

  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(nightjarCollectionProvider(collectionId));

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          MobileTopNav.back(
            title: collection == null
                ? truncateNightjarAssetId(collectionId)
                : nightjarCollectionTitle(collection),
            onBack: () => context.pop(),
          ),
          Expanded(
            child: MobileBottomSafeArea(
              bottomPadding: kMobileTabBarHeight + AppSpacing.lg,
              child: CustomScrollView(
                slivers: [
                  const SliverToBoxAdapter(
                    child: SizedBox(height: AppSpacing.s),
                  ),
                  ...buildNightjarCollectionSlivers(
                    collectionId: collectionId,
                    collection: collection,
                    // The top nav already carries the title.
                    showTitle: false,
                    horizontalPadding: AppSpacing.s,
                    onMemberTap: (assetId) =>
                        context.push('/nightjar/$assetId'),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: kMobileTabBarHeight + AppSpacing.lg,
                    ),
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
