import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_asset_acceptance_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_asset_metadata_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_metadata_fetcher_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_transport.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_metadata_copy.dart';

import 'support/nightjar_metadata_fixtures.dart';

const _nightjarId = 'aaaa0000';
const _imposterId = 'bbbb1111';
final _documentUri = Uri.parse('https://example.invalid/nj.json');
final _logoUri = Uri.parse('https://example.invalid/nj.png');

/// Records what was written instead of touching a platform keychain.
class _MemoryAcceptanceStore implements NightjarAcceptanceStore {
  String? value;
  var writes = 0;
  var clears = 0;

  @override
  Future<void> write(String encoded) async {
    writes++;
    value = encoded;
  }

  @override
  Future<void> clear() async {
    clears++;
    value = null;
  }
}

NightjarViewData _view() => NightjarViewData(
  status: NightjarViewStatus.ready,
  assets: [
    NightjarAssetDetailData(
      assetId: _nightjarId,
      name: 'NIGHTJAR',
      symbol: 'Nj',
      balance: BigInt.from(100),
      decimals: 8,
      metadataUri: _documentUri.toString(),
    ),
    NightjarAssetDetailData(
      assetId: _imposterId,
      name: 'nightjar',
      symbol: 'nj',
      balance: BigInt.from(1),
      decimals: 8,
      metadataUri: _documentUri.toString(),
    ),
  ],
);

Uint8List _documentBytes() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'schema': 'nightjar-asset-metadata/1',
      'description': 'A demonstration asset.',
      'logo': {'uri': _logoUri.toString()},
    }),
  ),
);

({
  ProviderContainer container,
  FakeNightjarTransport transport,
  _MemoryAcceptanceStore store,
})
_harness({
  NightjarAssetAcceptance acceptance = const NightjarAssetAcceptance.empty(),
}) {
  final transport = FakeNightjarTransport({
    _documentUri: NightjarHttpReply(statusCode: 200, body: _documentBytes()),
    _logoUri: NightjarHttpReply(statusCode: 200, body: kOnePixelPng),
  });
  final store = _MemoryAcceptanceStore();
  final container = ProviderContainer(
    overrides: [
      appBootstrapProvider.overrideWithValue(
        AppBootstrapState(
          initialLocation: '/',
          initialAccountState: AppBootstrapState.empty.initialAccountState,
          initialSyncSnapshot: AppBootstrapState.empty.initialSyncSnapshot,
          network: AppBootstrapState.empty.network,
          rpcEndpointConfig: AppBootstrapState.empty.rpcEndpointConfig,
          nightjarAcceptedAssets: acceptance,
          themeMode: AppBootstrapState.empty.themeMode,
          privacyModeEnabled: false,
          isPasswordConfigured: false,
          isUnlocked: false,
          passwordRotationRecoveryFailed: false,
        ),
      ),
      nightjarAcceptanceStoreProvider.overrideWithValue(store),
      nightjarMetadataFetcherProvider.overrideWithValue(
        NightjarAssetMetadataFetcher(transport: transport),
      ),
      nightjarViewLoaderProvider.overrideWithValue(() async => _view()),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, transport: transport, store: store);
}

void main() {
  group('NightjarAssetAcceptance', () {
    test('round-trips through its stored form', () {
      const acceptance = NightjarAssetAcceptance([
        NightjarAcceptedAsset(assetId: 'a', name: 'Gold', symbol: 'AU'),
        NightjarAcceptedAsset(assetId: 'b'),
      ]);

      final decoded = NightjarAssetAcceptance.decode(acceptance.encode());

      expect(decoded.accepted, acceptance.accepted);
      expect(decoded.isAccepted('a'), isTrue);
      expect(decoded.isAccepted('c'), isFalse);
    });

    test('decodes anything unreadable as empty', () {
      expect(NightjarAssetAcceptance.decode(null).accepted, isEmpty);
      expect(NightjarAssetAcceptance.decode('').accepted, isEmpty);
      expect(NightjarAssetAcceptance.decode('not json').accepted, isEmpty);
      expect(NightjarAssetAcceptance.decode('{"a":1}').accepted, isEmpty);
      expect(
        NightjarAssetAcceptance.decode('[1, "x", {"name":"no id"}]').accepted,
        isEmpty,
      );
    });

    test('collides on a name or a symbol, case-insensitively', () {
      const acceptance = NightjarAssetAcceptance([
        NightjarAcceptedAsset(
          assetId: _nightjarId,
          name: 'NIGHTJAR',
          symbol: 'Nj',
        ),
      ]);

      final byName = acceptance.collisionsWith(
        assetId: _imposterId,
        name: 'nightjar',
        symbol: 'XX',
      );
      final bySymbol = acceptance.collisionsWith(
        assetId: _imposterId,
        name: 'Something else',
        symbol: ' nj ',
      );

      expect(byName.single.matchesName, isTrue);
      expect(byName.single.matchesSymbol, isFalse);
      expect(bySymbol.single.matchesSymbol, isTrue);
      expect(bySymbol.single.existing.assetId, _nightjarId);
    });

    test('never collides an asset with itself', () {
      const acceptance = NightjarAssetAcceptance([
        NightjarAcceptedAsset(
          assetId: _nightjarId,
          name: 'NIGHTJAR',
          symbol: 'Nj',
        ),
      ]);

      expect(
        acceptance.collisionsWith(
          assetId: _nightjarId,
          name: 'NIGHTJAR',
          symbol: 'Nj',
        ),
        isEmpty,
      );
    });

    test('an asset with no name and no symbol collides with nothing', () {
      const acceptance = NightjarAssetAcceptance([
        NightjarAcceptedAsset(assetId: 'a'),
      ]);

      expect(acceptance.collisionsWith(assetId: 'b'), isEmpty);
    });

    test('accepting the same id twice replaces rather than duplicates', () {
      final acceptance = const NightjarAssetAcceptance.empty()
          .accepting(const NightjarAcceptedAsset(assetId: 'a', name: 'One'))
          .accepting(const NightjarAcceptedAsset(assetId: 'a', name: 'Two'));

      expect(acceptance.accepted.single.name, 'Two');
    });
  });

  group('nightjarCollisionWarningText', () {
    test('is null when nothing collides', () {
      expect(
        nightjarCollisionWarningText(collisions: const [], name: 'NIGHTJAR'),
        isNull,
      );
    });

    test('names the colliding name and says why ids are the answer', () {
      const acceptance = NightjarAssetAcceptance([
        NightjarAcceptedAsset(assetId: _nightjarId, name: 'NIGHTJAR'),
      ]);

      final text = nightjarCollisionWarningText(
        collisions: acceptance.collisionsWith(
          assetId: _imposterId,
          name: 'NIGHTJAR',
        ),
        name: 'NIGHTJAR',
      );

      expect(text, contains('"NIGHTJAR"'));
      expect(text, contains('asset ids'));
    });
  });

  group('acceptance gates every fetch', () {
    test('an unaccepted asset produces no metadata and no request', () async {
      final harness = _harness();

      final metadata = await harness.container.read(
        nightjarAssetMetadataProvider(_nightjarId).future,
      );

      expect(metadata, isNull);
      expect(harness.transport.requested, isEmpty);
    });

    test('holding a balance is not acceptance', () async {
      final harness = _harness();

      // Both assets are held, both carry a uri, and the logo map is what the
      // list screen renders from. Nothing was accepted, so nothing is fetched.
      final logos = harness.container.read(nightjarAssetLogosProvider);

      expect(logos, isEmpty);
      expect(harness.transport.requested, isEmpty);
    });

    test('accepting is what triggers the one request', () async {
      final harness = _harness();

      await harness.container
          .read(nightjarAssetAcceptanceProvider.notifier)
          .accept(assetId: _nightjarId, name: 'NIGHTJAR', symbol: 'Nj');

      final metadata = await harness.container.read(
        nightjarAssetMetadataProvider(_nightjarId).future,
      );

      expect(metadata, isNotNull);
      expect(metadata!.hasLogo, isTrue);
      expect(metadata.assetId, _nightjarId);
      expect(harness.transport.requested, [_documentUri, _logoUri]);
      // Nothing was fetched for the asset that was not accepted.
      expect(
        await harness.container.read(
          nightjarAssetMetadataProvider(_imposterId).future,
        ),
        isNull,
      );
    });

    test('acceptance is persisted before the state moves', () async {
      final harness = _harness();

      await harness.container
          .read(nightjarAssetAcceptanceProvider.notifier)
          .accept(assetId: _nightjarId, name: 'NIGHTJAR', symbol: 'Nj');

      expect(harness.store.writes, 1);
      expect(
        NightjarAssetAcceptance.decode(harness.store.value).accepted.single,
        const NightjarAcceptedAsset(
          assetId: _nightjarId,
          name: 'NIGHTJAR',
          symbol: 'Nj',
        ),
      );
    });

    test('a hydrated acceptance needs no second acceptance', () async {
      final harness = _harness(
        acceptance: const NightjarAssetAcceptance([
          NightjarAcceptedAsset(assetId: _nightjarId, name: 'NIGHTJAR'),
        ]),
      );

      final metadata = await harness.container.read(
        nightjarAssetMetadataProvider(_nightjarId).future,
      );

      expect(metadata, isNotNull);
      expect(harness.store.writes, 0);
    });

    test('revoking clears the key and drops the cached bytes', () async {
      final harness = _harness(
        acceptance: const NightjarAssetAcceptance([
          NightjarAcceptedAsset(assetId: _nightjarId, name: 'NIGHTJAR'),
        ]),
      );
      await harness.container.read(
        nightjarAssetMetadataProvider(_nightjarId).future,
      );
      expect(harness.transport.requested.length, 2);

      await harness.container
          .read(nightjarAssetAcceptanceProvider.notifier)
          .revoke(_nightjarId);

      expect(harness.store.clears, 1);
      expect(
        await harness.container.read(
          nightjarAssetMetadataProvider(_nightjarId).future,
        ),
        isNull,
      );
      expect(
        harness.container
            .read(nightjarMetadataFetcherProvider)
            .cached(assetId: _nightjarId, uri: _documentUri.toString()),
        isNull,
      );
    });

    test('the collision warning fires at the moment of acceptance', () async {
      final harness = _harness();
      final notifier = harness.container.read(
        nightjarAssetAcceptanceProvider.notifier,
      );

      expect(
        notifier.collisionsFor(
          assetId: _imposterId,
          name: 'nightjar',
          symbol: 'nj',
        ),
        isEmpty,
      );

      await notifier.accept(
        assetId: _nightjarId,
        name: 'NIGHTJAR',
        symbol: 'Nj',
      );

      final collisions = notifier.collisionsFor(
        assetId: _imposterId,
        name: 'nightjar',
        symbol: 'nj',
      );

      expect(collisions.single.existing.assetId, _nightjarId);
      expect(collisions.single.matchesName, isTrue);
      expect(collisions.single.matchesSymbol, isTrue);
    });
  });
}
