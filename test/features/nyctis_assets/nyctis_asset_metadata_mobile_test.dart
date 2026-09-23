@Tags(['mobile'])
library;

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/mobile_surface_card.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_asset_metadata.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_metadata_card.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_metadata_copy.dart';

import 'support/nyctis_metadata_fixtures.dart';

const _assetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';

NyctisAssetDetailData _asset() => NyctisAssetDetailData(
  assetId: _assetId,
  name: 'NYCTIS',
  symbol: 'Ny',
  balance: BigInt.from(100),
  decimals: 8,
  metadataUri: 'https://example.invalid/ny.json',
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: AppTheme(
        data: AppThemeData.dark,
        child: Align(alignment: Alignment.topCenter, child: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the card uses the mobile surface and still gates the logo', (
    tester,
  ) async {
    await _pump(
      tester,
      NyctisAssetMetadataCard(
        data: buildNyctisMetadataCardData(
          asset: _asset(),
          acceptance: const NyctisAssetAcceptance.empty(),
          view: NyctisAssetMetadataView(
            assetId: _assetId,
            metadata: const NyctisAssetMetadata(description: 'hidden'),
            documentPinned: false,
            sourceOrigin: 'example.invalid',
            logoBytes: kOnePixelPng,
          ),
        ),
        onAccept: () {},
      ),
    );

    expect(find.byType(MobileSurfaceCard), findsOneWidget);
    expect(find.byKey(const ValueKey('nyctis_logo_image')), findsNothing);
    expect(find.text(kNyctisMetadataAcceptAction), findsOneWidget);
  });

  testWidgets('an accepted asset draws the logo and the id on mobile too', (
    tester,
  ) async {
    await _pump(
      tester,
      NyctisAssetMetadataCard(
        data: buildNyctisMetadataCardData(
          asset: _asset(),
          acceptance: const NyctisAssetAcceptance([
            NyctisAcceptedAsset(assetId: _assetId, name: 'NYCTIS'),
          ]),
          view: NyctisAssetMetadataView(
            assetId: _assetId,
            metadata: const NyctisAssetMetadata(description: 'shown'),
            documentPinned: false,
            sourceOrigin: 'example.invalid',
            logoBytes: kOnePixelPng,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('nyctis_logo_image')), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('nyctis_metadata_header_asset_id')),
          )
          .data,
      contains(truncateNyctisAssetId(_assetId)),
    );
    // Beside the logo, unfolded: none of it is proof.
    expect(find.text(kNyctisMetadataNotEvidenceText), findsOneWidget);

    // The host, the pin and what an unpinned document means are behind
    // "What this means" on mobile as on desktop.
    final toggle = find.byKey(const ValueKey('nyctis_metadata_details_toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text(kNyctisMetadataUnpinnedValue), findsOneWidget);
    expect(find.text(kNyctisMetadataUnpinnedNote), findsOneWidget);
    expect(find.text(kNyctisMetadataPinnedValue), findsNothing);
  });
}
