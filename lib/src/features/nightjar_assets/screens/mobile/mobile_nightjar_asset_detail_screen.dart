/// Mobile `/nightjar/:assetId` — one asset's identity, metadata, supply,
/// and this wallet's own notes of it.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/app_mobile_tab_bar.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../providers/nightjar_assets_view_provider.dart';
import '../../providers/nightjar_proving_key_provider.dart';
import '../../widgets/nightjar_asset_metadata_section.dart';
import '../../widgets/nightjar_collection_sections.dart';
import '../../widgets/nightjar_asset_row_data.dart';
import '../../widgets/nightjar_asset_row_mapper.dart';
import '../nightjar_asset_detail_screen.dart';

class MobileNightjarAssetDetailScreen extends ConsumerWidget {
  const MobileNightjarAssetDetailScreen({required this.assetId, super.key});

  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = resolveNightjarView(ref.watch(nightjarAssetsViewProvider));
    final asset = view?.assetById(assetId);

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          MobileTopNav.back(
            title: asset == null
                ? truncateNightjarAssetId(assetId)
                : nightjarAssetDetailTitle(asset),
            onBack: () => context.pop(),
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
                  NightjarAssetDetailBody(
                    key: const ValueKey('mobile_nightjar_asset_detail'),
                    assetId: assetId,
                    view: view,
                    asset: asset,
                    heroSection: NightjarUniqueItemSection(asset: asset),
                    metadataSection: NightjarAssetMetadataSection(asset: asset),
                    showTitle: false,
                    onSend: () => context.push(nightjarSendRouteFor(assetId)),
                    sendDisabledReason: nightjarSendUnavailableReason(
                      ref.watch(nightjarProvingKeyProvider),
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
