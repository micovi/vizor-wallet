/// Mobile `/nyctis/:assetId` — one asset's identity, metadata, supply,
/// and this wallet's own notes of it.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../providers/nyctis_assets_view_provider.dart';
import '../../providers/nyctis_proving_key_provider.dart';
import '../../widgets/nyctis_asset_metadata_section.dart';
import '../../widgets/nyctis_collection_sections.dart';
import '../../widgets/nyctis_asset_row_data.dart';
import '../../widgets/nyctis_asset_row_mapper.dart';
import '../nyctis_asset_detail_screen.dart';
import 'mobile_nyctis_scaffold.dart';

class MobileNyctisAssetDetailScreen extends ConsumerWidget {
  const MobileNyctisAssetDetailScreen({required this.assetId, super.key});

  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = resolveNyctisView(ref.watch(nyctisAssetsViewProvider));
    final asset = view?.assetById(assetId);

    return MobileNyctisScaffold(
      topNav: MobileTopNav.back(
        title: asset == null
            ? truncateNyctisAssetId(assetId)
            : nyctisAssetDetailTitle(asset),
        onBack: () => context.pop(),
      ),
      body: ListView(
        padding: kNyctisMobileListPadding,
        children: [
          NyctisAssetDetailBody(
            key: const ValueKey('mobile_nyctis_asset_detail'),
            assetId: assetId,
            view: view,
            asset: asset,
            heroSection: NyctisUniqueItemSection(asset: asset),
            metadataSection: NyctisAssetMetadataSection(asset: asset),
            showTitle: false,
            onSend: () => context.push(nyctisSendRouteFor(assetId)),
            onReceive: () => context.push(kNyctisReceiveRoute),
            sendDisabledReason: nyctisSendUnavailableReason(
              ref.watch(nyctisProvingKeyProvider),
            ),
          ),
        ],
      ),
    );
  }
}
