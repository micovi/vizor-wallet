@Tags(['mobile'])
library;

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/mobile_surface_card.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_asset_metadata.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_metadata_card.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_metadata_copy.dart';

import 'support/nightjar_metadata_fixtures.dart';

const _assetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';

NightjarAssetDetailData _asset() => NightjarAssetDetailData(
  assetId: _assetId,
  name: 'NIGHTJAR',
  symbol: 'Nj',
  balance: BigInt.from(100),
  decimals: 8,
  metadataUri: 'https://example.invalid/nj.json',
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
      NightjarAssetMetadataCard(
        data: buildNightjarMetadataCardData(
          asset: _asset(),
          acceptance: const NightjarAssetAcceptance.empty(),
          view: NightjarAssetMetadataView(
            assetId: _assetId,
            metadata: const NightjarAssetMetadata(description: 'hidden'),
            documentPinned: false,
            sourceOrigin: 'example.invalid',
            logoBytes: kOnePixelPng,
          ),
        ),
        onAccept: () {},
      ),
    );

    expect(find.byType(MobileSurfaceCard), findsOneWidget);
    expect(find.byKey(const ValueKey('nightjar_logo_image')), findsNothing);
    expect(find.text(kNightjarMetadataAcceptAction), findsOneWidget);
  });

  testWidgets('an accepted asset draws the logo and the id on mobile too', (
    tester,
  ) async {
    await _pump(
      tester,
      NightjarAssetMetadataCard(
        data: buildNightjarMetadataCardData(
          asset: _asset(),
          acceptance: const NightjarAssetAcceptance([
            NightjarAcceptedAsset(assetId: _assetId, name: 'NIGHTJAR'),
          ]),
          view: NightjarAssetMetadataView(
            assetId: _assetId,
            metadata: const NightjarAssetMetadata(description: 'shown'),
            documentPinned: false,
            sourceOrigin: 'example.invalid',
            logoBytes: kOnePixelPng,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('nightjar_logo_image')), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('nightjar_metadata_header_asset_id')),
          )
          .data,
      contains(truncateNightjarAssetId(_assetId)),
    );
    expect(find.text(kNightjarMetadataUnpinnedNote), findsOneWidget);
  });
}
