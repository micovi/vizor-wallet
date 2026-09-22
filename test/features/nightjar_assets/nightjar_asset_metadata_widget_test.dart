import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_asset_metadata.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_logo.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_metadata_card.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_assets_feed.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_metadata_copy.dart';

import 'support/nightjar_metadata_fixtures.dart';

const _assetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
const _otherAssetId =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

NightjarAssetDetailData _asset({String? uri}) => NightjarAssetDetailData(
  assetId: _assetId,
  name: 'NIGHTJAR',
  symbol: 'Nj',
  balance: BigInt.from(100),
  decimals: 8,
  metadataUri: uri ?? 'https://example.invalid/nj.json',
);

NightjarAssetMetadataView _view({bool withLogo = true}) =>
    NightjarAssetMetadataView(
      assetId: _assetId,
      metadata: NightjarAssetMetadata(
        description: 'A demonstration asset on the regtest devnet.',
        website: Uri.parse('https://example.invalid/'),
        links: [
          NightjarAssetLink(
            rel: 'github',
            uri: Uri.parse('https://github.com/example'),
          ),
          NightjarAssetLink(
            rel: 'newplatform',
            uri: Uri.parse('https://newplatform.invalid/example'),
          ),
        ],
      ),
      documentPinned: true,
      sourceOrigin: 'example.invalid',
      logoBytes: withLogo ? kOnePixelPng : null,
      logoPinned: withLogo,
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: AppTheme(
        data: AppThemeData.dark,
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: 396, child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'before acceptance there is no logo, no description and a button',
    (tester) async {
      await _pump(
        tester,
        NightjarAssetMetadataCard(
          data: buildNightjarMetadataCardData(
            asset: _asset(),
            acceptance: const NightjarAssetAcceptance.empty(),
            // Even handed a fetched document, an unaccepted asset renders none
            // of it: `buildNightjarMetadataCardData` drops it.
            view: _view(),
          ),
          onAccept: () {},
        ),
      );

      expect(
        find.byKey(const ValueKey('nightjar_metadata_not_fetched')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('nightjar_logo_image')), findsNothing);
      expect(
        find.byKey(const ValueKey('nightjar_metadata_description')),
        findsNothing,
      );
      expect(find.text(kNightjarMetadataAcceptAction), findsOneWidget);
      expect(find.text(kNightjarMetadataNotEvidenceText), findsOneWidget);
      // Section 5: the id is on screen wherever the decision is being made.
      expect(find.text(truncateNightjarAssetId(_assetId)), findsOneWidget);
      expect(find.text('example.invalid'), findsOneWidget);
    },
  );

  testWidgets('the collision warning is shown before the accept button', (
    tester,
  ) async {
    await _pump(
      tester,
      NightjarAssetMetadataCard(
        data: buildNightjarMetadataCardData(
          asset: _asset(),
          acceptance: const NightjarAssetAcceptance([
            NightjarAcceptedAsset(
              assetId: _otherAssetId,
              name: 'nightjar',
              symbol: 'nj',
            ),
          ]),
        ),
        onAccept: () {},
      ),
    );

    final collision = find.byKey(const ValueKey('nightjar_metadata_collision'));
    expect(collision, findsOneWidget);
    expect(tester.widget<Text>(collision).data, contains('already accepted'));
  });

  testWidgets('accepting is an explicit tap', (tester) async {
    var accepted = 0;
    await _pump(
      tester,
      NightjarAssetMetadataCard(
        data: buildNightjarMetadataCardData(
          asset: _asset(),
          acceptance: const NightjarAssetAcceptance.empty(),
        ),
        onAccept: () => accepted++,
      ),
    );

    expect(accepted, 0);
    await tester.tap(
      find.byKey(const ValueKey('nightjar_metadata_accept_button')),
    );
    await tester.pump();
    expect(accepted, 1);
  });

  testWidgets('after acceptance the logo, the asset id and the links render', (
    tester,
  ) async {
    final opened = <Uri>[];
    await _pump(
      tester,
      NightjarAssetMetadataCard(
        data: buildNightjarMetadataCardData(
          asset: _asset(),
          acceptance: const NightjarAssetAcceptance([
            NightjarAcceptedAsset(assetId: _assetId, name: 'NIGHTJAR'),
          ]),
          view: _view(),
        ),
        onOpenLink: opened.add,
      ),
    );

    expect(find.byKey(const ValueKey('nightjar_logo_image')), findsOneWidget);
    // Section 5, first bullet: the id is beside the logo.
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('nightjar_metadata_header_asset_id')),
          )
          .data,
      contains(truncateNightjarAssetId(_assetId)),
    );
    expect(
      find.byKey(const ValueKey('nightjar_metadata_description')),
      findsOneWidget,
    );

    // Section 4.3: the origin is in the label, and a recognized rel renders
    // while an unrecognized one does not.
    expect(find.text('Website · example.invalid'), findsOneWidget);
    expect(find.text('GitHub · github.com'), findsOneWidget);
    expect(find.textContaining('newplatform'), findsNothing);

    // Nothing opened by rendering.
    expect(opened, isEmpty);
    await tester.tap(find.byKey(const ValueKey('nightjar_metadata_website')));
    await tester.pump();
    expect(opened, [Uri.parse('https://example.invalid/')]);
  });

  testWidgets('a pinned document is never presented as evidence', (
    tester,
  ) async {
    await _pump(
      tester,
      NightjarAssetMetadataCard(
        data: buildNightjarMetadataCardData(
          asset: _asset(),
          acceptance: const NightjarAssetAcceptance([
            NightjarAcceptedAsset(assetId: _assetId),
          ]),
          view: _view(),
        ),
      ),
    );

    expect(find.text(kNightjarMetadataPinnedValue), findsOneWidget);
    expect(find.text(kNightjarMetadataPinnedNote), findsOneWidget);
    expect(find.text(kNightjarMetadataNotEvidenceText), findsOneWidget);
    expect(find.textContaining('verified'), findsNothing);
    expect(find.textContaining('trusted'), findsNothing);
  });

  testWidgets('an abandoned fetch says so without calling it an error', (
    tester,
  ) async {
    await _pump(
      tester,
      NightjarAssetMetadataCard(
        data: buildNightjarMetadataCardData(
          asset: _asset(),
          acceptance: const NightjarAssetAcceptance([
            NightjarAcceptedAsset(assetId: _assetId),
          ]),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('nightjar_metadata_absent')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('nightjar_logo_image')), findsNothing);
  });

  testWidgets('an http uri is refused in words, with no accept button', (
    tester,
  ) async {
    await _pump(
      tester,
      NightjarAssetMetadataCard(
        data: buildNightjarMetadataCardData(
          asset: _asset(uri: 'http://example.invalid/nj.json'),
          acceptance: const NightjarAssetAcceptance.empty(),
        ),
        onAccept: () {},
      ),
    );

    expect(
      find.byKey(const ValueKey('nightjar_metadata_refused')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('nightjar_metadata_accept_button')),
      findsNothing,
    );
  });

  testWidgets('an asset with no uri renders no card at all', (tester) async {
    await _pump(
      tester,
      NightjarAssetMetadataCard(
        data: buildNightjarMetadataCardData(
          asset: NightjarAssetDetailData(
            assetId: _assetId,
            balance: BigInt.zero,
            decimals: 0,
          ),
          acceptance: const NightjarAssetAcceptance.empty(),
        ),
      ),
    );

    expect(find.text(kNightjarMetadataTitle), findsNothing);
  });

  group('the assets list row', () {
    testWidgets('draws no logo for an asset with none', (tester) async {
      await _pump(
        tester,
        NightjarAssetRow(
          row: NightjarAssetRowData(
            assetId: _assetId,
            name: 'NIGHTJAR',
            symbol: 'Nj',
            balance: BigInt.from(100),
            decimals: 8,
            noteCount: 1,
          ),
        ),
      );

      expect(find.byType(NightjarAssetLogoImage), findsNothing);
      expect(find.text('Nj'), findsOneWidget);
    });

    testWidgets('shows the asset id beside a logo it does draw', (
      tester,
    ) async {
      final row = NightjarAssetRowData(
        assetId: _assetId,
        name: 'NIGHTJAR',
        symbol: 'Nj',
        balance: BigInt.from(100),
        decimals: 8,
        noteCount: 1,
        logoBytes: kOnePixelPng,
      );
      await _pump(tester, NightjarAssetRow(row: row));

      expect(find.byKey(const ValueKey('nightjar_logo_image')), findsOneWidget);
      expect(
        nightjarAssetRowSubtitle(row),
        'Nj · ${truncateNightjarAssetId(_assetId)}',
      );
      expect(find.text(nightjarAssetRowSubtitle(row)), findsOneWidget);
    });
  });
}
