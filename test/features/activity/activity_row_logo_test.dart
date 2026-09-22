/// An activity row's leading image, and the acceptance gate in front of it.
///
/// The interesting assertions are the negative ones. A logo in an activity row
/// is decoration; the two things that are not decoration are
/// `spec/asset-metadata-v0.md` section 5's rules — a picture only for an asset
/// the user explicitly accepted, and the `asset_id` visible wherever the
/// picture is — so those get tested through the real acceptance provider and
/// the real row widget rather than through a fake in the middle.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_icon.dart';
import 'package:zcash_wallet/src/features/activity/models/activity_row_data.dart';
import 'package:zcash_wallet/src/features/activity/nightjar_activity_row_mapper.dart';
import 'package:zcash_wallet/src/features/activity/widgets/activity_feed.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_asset_acceptance_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_asset_metadata_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_metadata_fetcher_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_transport.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_logo.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';

import '../nightjar_assets/support/nightjar_metadata_fixtures.dart';

const _acceptedId =
    'a3f1c0d29b8e47a5f6031d8c2b7e4906aa11bb22cc33dd44ee55ff6600778899';
const _unacceptedId =
    '00ff11ee22dd33cc44bb55aa6699778800112233445566778899aabbccddeeff';
final _documentUri = Uri.parse('https://example.invalid/nj.json');
final _logoUri = Uri.parse('https://example.invalid/nj.png');

void main() {
  group('the row draws an image when it is given one', () {
    testWidgets('and the icon when it is not', (tester) async {
      await _pumpRows(tester, [
        _row(title: 'Devnet Mint'),
        _row(
          title: 'Devnet Mint',
          image: ActivityRowLeadingImage(
            bytes: kOnePixelPng,
            identityLabel: 'a3f1c0…778899',
          ),
        ),
      ]);

      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(AppIcon), findsOneWidget);
    });

    testWidgets('decoding to a bounded target, never the natural size', (
      tester,
    ) async {
      await _pumpRows(tester, [
        _row(
          title: 'Devnet Mint',
          image: ActivityRowLeadingImage(
            bytes: kOnePixelPng,
            identityLabel: 'a3f1c0…778899',
          ),
        ),
      ]);

      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image;
      expect(
        provider,
        isA<ResizeImage>(),
        reason:
            'Section 4.2: the header dimensions decide the decode, so the '
            'engine must be given a ceiling rather than the image bytes.',
      );
      provider as ResizeImage;
      expect(provider.width, isNotNull);
      expect(provider.height, isNotNull);
      expect(provider.width!, lessThanOrEqualTo(kNightjarLogoMaxDecodePixels));
      expect(provider.height!, lessThanOrEqualTo(kNightjarLogoMaxDecodePixels));
    });

    testWidgets('in the same circular frame, at the same size', (tester) async {
      await _pumpRows(tester, [
        _row(
          title: 'Devnet Mint',
          image: ActivityRowLeadingImage(
            bytes: kOnePixelPng,
            identityLabel: 'a3f1c0…778899',
          ),
        ),
      ]);

      final logo = tester.widget<NightjarAssetLogoImage>(
        find.byType(NightjarAssetLogoImage),
      );
      expect(logo.size, AppAssetSize.size);
      expect(
        tester.getSize(find.byType(NightjarAssetLogoImage)),
        const Size(AppAssetSize.size, AppAssetSize.size),
      );
      // The background the icon sat on is still behind the picture, which is
      // what a logo with transparency and the decode fallback both need.
      final decorated = tester.widgetList<DecoratedBox>(
        find.ancestor(
          of: find.byType(NightjarAssetLogoImage),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect(
        decorated.any(
          (box) =>
              box.decoration is BoxDecoration &&
              (box.decoration as BoxDecoration).shape == BoxShape.circle &&
              (box.decoration as BoxDecoration).color == _leadingBackground,
        ),
        isTrue,
      );
    });
  });

  group('asset-metadata-v0 section 5: the id goes where the logo goes', () {
    testWidgets('the row shows the asset id beside the picture', (
      tester,
    ) async {
      await _pumpRows(tester, [
        _row(
          title: 'Devnet Mint',
          subtitle: 'Held Nightjar note',
          image: ActivityRowLeadingImage(
            bytes: kOnePixelPng,
            identityLabel: 'a3f1c0…778899',
          ),
        ),
      ]);

      // The declared name is the title, and on its own it identifies nothing.
      expect(find.text('Devnet Mint'), findsOneWidget);
      // The id leads the supporting line, so a narrow row shortens the
      // description rather than the identifier.
      expect(
        find.text('a3f1c0…778899 \u00b7 Held Nightjar note'),
        findsOneWidget,
      );
    });

    testWidgets('a row with no picture prints no id', (tester) async {
      await _pumpRows(tester, [
        _row(title: 'Devnet Mint', subtitle: 'Held Nightjar note'),
      ]);

      expect(find.textContaining('a3f1c0…778899'), findsNothing);
      expect(find.text('Held Nightjar note'), findsOneWidget);
    });

    testWidgets('an unnamed asset, already titled by its id, does not repeat '
        'it', (tester) async {
      await _pumpRows(tester, [
        _row(
          title: '00ff11…ddeeff',
          subtitle: 'Held Nightjar note',
          image: ActivityRowLeadingImage(
            bytes: kOnePixelPng,
            identityLabel: '00ff11…ddeeff',
          ),
        ),
      ]);

      expect(find.text('Held Nightjar note'), findsOneWidget);
      expect(find.textContaining('00ff11…ddeeff \u00b7'), findsNothing);
      expect(find.text('00ff11…ddeeff'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });

    test('the id cannot be left out of a leading image', () {
      expect(
        () => ActivityRowLeadingImage(bytes: kOnePixelPng, identityLabel: ''),
        throwsAssertionError,
      );
    });
  });

  group('acceptance decides whether there is an image at all', () {
    testWidgets('an unaccepted asset renders the icon, not an image', (
      tester,
    ) async {
      final harness = _harness();
      // Let the view load settle first. `nightjarAssetLogosProvider` watches the
      // grouped-ids provider, which hangs off the async view; reading it
      // synchronously starts that load and the test would otherwise end with it
      // still in flight, leaving a timer pending after the tree is disposed.
      // The other tests here await a provider future and so drain it already.
      await harness.container.read(nightjarAssetsViewProvider.future);

      // The wallet holds the asset and the asset carries a document uri. The
      // user has not accepted it, so `nightjarAssetLogosProvider` answers
      // nothing for it — no bytes to leak into a row, and no fetch either.
      final logos = harness.container.read(nightjarAssetLogosProvider);
      expect(logos, isEmpty);
      expect(harness.transport.requested, isEmpty);

      final row = await _nightjarRow(
        tester,
        assetId: _acceptedId,
        name: 'Devnet Mint',
        logos: logos,
      );
      expect(row.leadingImage, isNull);

      await _pumpRows(tester, [row]);

      expect(find.byType(Image), findsNothing);
      expect(find.byType(AppIcon), findsOneWidget);
      expect(
        find.textContaining(truncateNightjarAssetId(_acceptedId)),
        findsNothing,
        reason: 'No logo, so section 5 asks for nothing extra on the row.',
      );
    });

    testWidgets('accepting one asset decorates that row and no other', (
      tester,
    ) async {
      final harness = _harness();
      await harness.container
          .read(nightjarAssetAcceptanceProvider.notifier)
          .accept(assetId: _acceptedId, name: 'Devnet Mint', symbol: 'DMT');
      await harness.container.read(
        nightjarAssetMetadataProvider(_acceptedId).future,
      );

      final logos = harness.container.read(nightjarAssetLogosProvider);
      expect(logos.keys, [_acceptedId]);

      final accepted = await _nightjarRow(
        tester,
        assetId: _acceptedId,
        name: 'Devnet Mint',
        logos: logos,
      );
      final unaccepted = await _nightjarRow(
        tester,
        assetId: _unacceptedId,
        logos: logos,
      );

      expect(accepted.leadingImage, isNotNull);
      expect(
        accepted.leadingImage!.identityLabel,
        truncateNightjarAssetId(_acceptedId),
      );
      expect(unaccepted.leadingImage, isNull);

      await _pumpRows(tester, [accepted, unaccepted]);

      expect(find.byType(Image), findsOneWidget);
      expect(
        find.textContaining(truncateNightjarAssetId(_acceptedId)),
        findsOneWidget,
      );
    });
  });
}

const _leadingBackground = Color(0xFFE1E1E1);

var _rowSeq = 0;

ActivityRowData _row({
  required String title,
  String? subtitle,
  ActivityRowLeadingImage? image,
}) {
  return ActivityRowData(
    stableId: 'nightjar-note:$title:${_rowSeq++}',
    title: title,
    leadingIconName: AppIcons.shieldAsset,
    leadingImage: image,
    leadingBackgroundColor: _leadingBackground,
    leadingIconColor: const Color(0xFF4D5252),
    subtitle: subtitle,
    amountText: '+1 DMT',
    statusText: '',
    timestampText: 'Today, 13:11',
  );
}

/// A Nightjar activity row through the real mapper, which is the only place
/// the logo lookup lives: an asset with no bytes in [logos] keeps its icon,
/// and an asset with bytes gets them with its id attached.
Future<ActivityRowData> _nightjarRow(
  WidgetTester tester, {
  required String assetId,
  required Map<String, Uint8List> logos,
  String? name,
}) async {
  late ActivityRowData row;
  await tester.pumpWidget(
    MaterialApp(
      home: AppTheme(
        data: AppThemeData.light,
        child: Builder(
          builder: (context) {
            row = nightjarActivityEntry(
              context: context,
              item: NightjarActivityItem(
                msgId: 'a1b2c3d4e5f60718',
                assetId: assetId,
                name: name,
                symbol: name == null ? null : 'DMT',
                kind: NightjarActivityKind.received,
                delta: BigInt.from(100),
                moved: BigInt.zero,
                decimals: 2,
                height: BigInt.from(7164),
                ownedOutputs: 1,
                totalOutputs: 1,
              ),
              logos: logos,
            ).row;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return row;
}

Future<void> _pumpRows(WidgetTester tester, List<ActivityRowData> rows) {
  return tester.pumpWidget(
    MaterialApp(
      home: AppTheme(
        data: AppThemeData.light,
        child: Center(
          child: SizedBox(
            width: 420,
            child: ActivityFeed(
              sections: [
                ActivityFeedSectionData(title: 'This week', rows: rows),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

NightjarViewData _view() => NightjarViewData(
  status: NightjarViewStatus.ready,
  assets: [
    NightjarAssetDetailData(
      assetId: _acceptedId,
      name: 'Devnet Mint',
      symbol: 'DMT',
      balance: BigInt.from(100),
      decimals: 2,
      metadataUri: _documentUri.toString(),
    ),
    NightjarAssetDetailData(
      assetId: _unacceptedId,
      balance: BigInt.from(5),
      decimals: 0,
      metadataUri: _documentUri.toString(),
    ),
  ],
);

Uint8List _documentBytes() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'schema': 'nightjar-asset-metadata/1',
      'logo': {'uri': _logoUri.toString()},
    }),
  ),
);

({ProviderContainer container, FakeNightjarTransport transport}) _harness() {
  final transport = FakeNightjarTransport({
    _documentUri: NightjarHttpReply(statusCode: 200, body: _documentBytes()),
    _logoUri: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
  });
  final container = ProviderContainer(
    overrides: [
      appBootstrapProvider.overrideWithValue(AppBootstrapState.empty),
      nightjarAcceptanceStoreProvider.overrideWithValue(
        _MemoryAcceptanceStore(),
      ),
      nightjarMetadataFetcherProvider.overrideWithValue(
        NightjarAssetMetadataFetcher(transport: transport),
      ),
      nightjarViewLoaderProvider.overrideWithValue(() async => _view()),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, transport: transport);
}

class _MemoryAcceptanceStore implements NightjarAcceptanceStore {
  String? value;

  @override
  Future<void> write(String encoded) async => value = encoded;

  @override
  Future<void> clear() async => value = null;
}
