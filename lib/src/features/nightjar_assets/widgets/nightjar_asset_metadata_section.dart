/// The provider-connected issuer-metadata card.
///
/// This is the only place in the app that turns "the user pressed a button"
/// into a metadata fetch, which is what `spec/asset-metadata-v0.md` section
/// 3.1 asks for: acceptance is the trigger, and it is the *only* trigger.
/// [NightjarAssetMetadataCard] below it is presentational and the providers
/// above it fetch nothing for an asset that is not accepted, so there is no
/// path from "this wallet holds a note" to a request.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../providers/nightjar_asset_acceptance_provider.dart';
import '../providers/nightjar_asset_metadata_provider.dart';
import 'nightjar_asset_metadata_card.dart';
import 'nightjar_asset_row_data.dart';

class NightjarAssetMetadataSection extends ConsumerWidget {
  const NightjarAssetMetadataSection({required this.asset, super.key});

  /// Null while the view is loading, or when it does not hold this asset.
  final NightjarAssetDetailData? asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = this.asset;
    if (asset == null) return const SizedBox.shrink();

    final acceptance = ref.watch(nightjarAssetAcceptanceProvider);
    final accepted = acceptance.isAccepted(asset.assetId);
    // Watched only once accepted. Watching it regardless would be harmless
    // today — the provider checks acceptance itself — but it would put a
    // second, weaker gate in the call graph, and the next person to simplify
    // one of the two would have to notice the other.
    final metadata = accepted
        ? ref.watch(nightjarAssetMetadataProvider(asset.assetId))
        : const AsyncValue<Null>.data(null);

    final data = buildNightjarMetadataCardData(
      asset: asset,
      acceptance: acceptance,
      view: accepted ? metadata.value : null,
      isLoading: accepted && metadata.isLoading,
    );
    if (!data.hasAnythingToSay) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: NightjarAssetMetadataCard(
        key: const ValueKey('nightjar_asset_detail_issuer_metadata'),
        data: data,
        onAccept: () => unawaited(
          ref
              .read(nightjarAssetAcceptanceProvider.notifier)
              .accept(
                assetId: asset.assetId,
                name: asset.name,
                symbol: asset.symbol,
              ),
        ),
        onForget: () => unawaited(
          ref
              .read(nightjarAssetAcceptanceProvider.notifier)
              .revoke(asset.assetId),
        ),
        onOpenLink: (uri) =>
            unawaited(launchUrl(uri, mode: LaunchMode.externalApplication)),
      ),
    );
  }
}
