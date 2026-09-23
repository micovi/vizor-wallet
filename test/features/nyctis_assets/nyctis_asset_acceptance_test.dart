import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_asset_acceptance_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_asset_metadata_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_metadata_fetcher_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_transport.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_metadata_copy.dart';

import 'support/nyctis_metadata_fixtures.dart';

const _nyctisId = 'aaaa0000';
const _imposterId = 'bbbb1111';
final _documentUri = Uri.parse('https://example.invalid/ny.json');
final _logoUri = Uri.parse('https://example.invalid/ny.png');

/// Records what was written instead of touching a platform keychain.
class _MemoryAcceptanceStore implements NyctisAcceptanceStore {
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

NyctisViewData _view() => NyctisViewData(
  status: NyctisViewStatus.ready,
  assets: [
    NyctisAssetDetailData(
      assetId: _nyctisId,
      name: 'NYCTIS',
      symbol: 'Ny',
      balance: BigInt.from(100),
      decimals: 8,
      metadataUri: _documentUri.toString(),
    ),
    NyctisAssetDetailData(
      assetId: _imposterId,
      name: 'nyctis',
      symbol: 'ny',
      balance: BigInt.from(1),
      decimals: 8,
      metadataUri: _documentUri.toString(),
    ),
  ],
);

Uint8List _documentBytes() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'schema': 'nyctis-asset-metadata/1',
      'description': 'A demonstration asset.',
      'logo': {'uri': _logoUri.toString()},
    }),
  ),
);

({
  ProviderContainer container,
  FakeNyctisTransport transport,
  _MemoryAcceptanceStore store,
})
_harness({
  NyctisAssetAcceptance acceptance = const NyctisAssetAcceptance.empty(),
}) {
  final transport = FakeNyctisTransport({
    _documentUri: NyctisHttpReply(statusCode: 200, body: _documentBytes()),
    _logoUri: NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
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
          nyctisAcceptedAssets: acceptance,
          themeMode: AppBootstrapState.empty.themeMode,
          privacyModeEnabled: false,
          isPasswordConfigured: false,
          isUnlocked: false,
          passwordRotationRecoveryFailed: false,
        ),
      ),
      nyctisAcceptanceStoreProvider.overrideWithValue(store),
      nyctisMetadataFetcherProvider.overrideWithValue(
        NyctisAssetMetadataFetcher(transport: transport),
      ),
      nyctisViewLoaderProvider.overrideWithValue(() async => _view()),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, transport: transport, store: store);
}

void main() {
  group('NyctisAssetAcceptance', () {
    test('round-trips through its stored form', () {
      const acceptance = NyctisAssetAcceptance([
        NyctisAcceptedAsset(assetId: 'a', name: 'Gold', symbol: 'AU'),
        NyctisAcceptedAsset(assetId: 'b'),
      ]);

      final decoded = NyctisAssetAcceptance.decode(acceptance.encode());

      expect(decoded.accepted, acceptance.accepted);
      expect(decoded.isAccepted('a'), isTrue);
      expect(decoded.isAccepted('c'), isFalse);
    });

    test('decodes anything unreadable as empty', () {
      expect(NyctisAssetAcceptance.decode(null).accepted, isEmpty);
      expect(NyctisAssetAcceptance.decode('').accepted, isEmpty);
      expect(NyctisAssetAcceptance.decode('not json').accepted, isEmpty);
      expect(NyctisAssetAcceptance.decode('{"a":1}').accepted, isEmpty);
      expect(
        NyctisAssetAcceptance.decode('[1, "x", {"name":"no id"}]').accepted,
        isEmpty,
      );
    });

    test('collides on a name or a symbol, case-insensitively', () {
      const acceptance = NyctisAssetAcceptance([
        NyctisAcceptedAsset(
          assetId: _nyctisId,
          name: 'NYCTIS',
          symbol: 'Ny',
        ),
      ]);

      final byName = acceptance.collisionsWith(
        assetId: _imposterId,
        name: 'nyctis',
        symbol: 'XX',
      );
      final bySymbol = acceptance.collisionsWith(
        assetId: _imposterId,
        name: 'Something else',
        symbol: ' ny ',
      );

      expect(byName.single.matchesName, isTrue);
      expect(byName.single.matchesSymbol, isFalse);
      expect(bySymbol.single.matchesSymbol, isTrue);
      expect(bySymbol.single.existing.assetId, _nyctisId);
    });

    test('never collides an asset with itself', () {
      const acceptance = NyctisAssetAcceptance([
        NyctisAcceptedAsset(
          assetId: _nyctisId,
          name: 'NYCTIS',
          symbol: 'Ny',
        ),
      ]);

      expect(
        acceptance.collisionsWith(
          assetId: _nyctisId,
          name: 'NYCTIS',
          symbol: 'Ny',
        ),
        isEmpty,
      );
    });

    test('an asset with no name and no symbol collides with nothing', () {
      const acceptance = NyctisAssetAcceptance([
        NyctisAcceptedAsset(assetId: 'a'),
      ]);

      expect(acceptance.collisionsWith(assetId: 'b'), isEmpty);
    });

    test('accepting the same id twice replaces rather than duplicates', () {
      final acceptance = const NyctisAssetAcceptance.empty()
          .accepting(const NyctisAcceptedAsset(assetId: 'a', name: 'One'))
          .accepting(const NyctisAcceptedAsset(assetId: 'a', name: 'Two'));

      expect(acceptance.accepted.single.name, 'Two');
    });
  });

  group('nyctisCollisionWarningText', () {
    test('is null when nothing collides', () {
      expect(
        nyctisCollisionWarningText(collisions: const [], name: 'NYCTIS'),
        isNull,
      );
    });

    test('names the colliding name and says why ids are the answer', () {
      const acceptance = NyctisAssetAcceptance([
        NyctisAcceptedAsset(assetId: _nyctisId, name: 'NYCTIS'),
      ]);

      final text = nyctisCollisionWarningText(
        collisions: acceptance.collisionsWith(
          assetId: _imposterId,
          name: 'NYCTIS',
        ),
        name: 'NYCTIS',
      );

      expect(text, contains('"NYCTIS"'));
      expect(text, contains('asset ids'));
    });
  });

  group('acceptance gates every fetch', () {
    test('an unaccepted asset produces no metadata and no request', () async {
      final harness = _harness();

      final metadata = await harness.container.read(
        nyctisAssetMetadataProvider(_nyctisId).future,
      );

      expect(metadata, isNull);
      expect(harness.transport.requested, isEmpty);
    });

    test('holding a balance is not acceptance', () async {
      final harness = _harness();

      // Both assets are held, both carry a uri, and the logo map is what the
      // list screen renders from. Nothing was accepted, so nothing is fetched.
      final logos = harness.container.read(nyctisAssetLogosProvider);

      expect(logos, isEmpty);
      expect(harness.transport.requested, isEmpty);
    });

    test('accepting is what triggers the one request', () async {
      final harness = _harness();

      await harness.container
          .read(nyctisAssetAcceptanceProvider.notifier)
          .accept(assetId: _nyctisId, name: 'NYCTIS', symbol: 'Ny');

      final metadata = await harness.container.read(
        nyctisAssetMetadataProvider(_nyctisId).future,
      );

      expect(metadata, isNotNull);
      expect(metadata!.hasLogo, isTrue);
      expect(metadata.assetId, _nyctisId);
      expect(harness.transport.requested, [_documentUri, _logoUri]);
      // Nothing was fetched for the asset that was not accepted.
      expect(
        await harness.container.read(
          nyctisAssetMetadataProvider(_imposterId).future,
        ),
        isNull,
      );
    });

    test('acceptance is persisted before the state moves', () async {
      final harness = _harness();

      await harness.container
          .read(nyctisAssetAcceptanceProvider.notifier)
          .accept(assetId: _nyctisId, name: 'NYCTIS', symbol: 'Ny');

      expect(harness.store.writes, 1);
      expect(
        NyctisAssetAcceptance.decode(harness.store.value).accepted.single,
        const NyctisAcceptedAsset(
          assetId: _nyctisId,
          name: 'NYCTIS',
          symbol: 'Ny',
        ),
      );
    });

    test('a hydrated acceptance needs no second acceptance', () async {
      final harness = _harness(
        acceptance: const NyctisAssetAcceptance([
          NyctisAcceptedAsset(assetId: _nyctisId, name: 'NYCTIS'),
        ]),
      );

      final metadata = await harness.container.read(
        nyctisAssetMetadataProvider(_nyctisId).future,
      );

      expect(metadata, isNotNull);
      expect(harness.store.writes, 0);
    });

    test('revoking clears the key and drops the cached bytes', () async {
      final harness = _harness(
        acceptance: const NyctisAssetAcceptance([
          NyctisAcceptedAsset(assetId: _nyctisId, name: 'NYCTIS'),
        ]),
      );
      await harness.container.read(
        nyctisAssetMetadataProvider(_nyctisId).future,
      );
      expect(harness.transport.requested.length, 2);

      await harness.container
          .read(nyctisAssetAcceptanceProvider.notifier)
          .revoke(_nyctisId);

      expect(harness.store.clears, 1);
      expect(
        await harness.container.read(
          nyctisAssetMetadataProvider(_nyctisId).future,
        ),
        isNull,
      );
      expect(
        harness.container
            .read(nyctisMetadataFetcherProvider)
            .cached(assetId: _nyctisId, uri: _documentUri.toString()),
        isNull,
      );
    });

    test('the collision warning fires at the moment of acceptance', () async {
      final harness = _harness();
      final notifier = harness.container.read(
        nyctisAssetAcceptanceProvider.notifier,
      );

      expect(
        notifier.collisionsFor(
          assetId: _imposterId,
          name: 'nyctis',
          symbol: 'ny',
        ),
        isEmpty,
      );

      await notifier.accept(
        assetId: _nyctisId,
        name: 'NYCTIS',
        symbol: 'Ny',
      );

      final collisions = notifier.collisionsFor(
        assetId: _imposterId,
        name: 'nyctis',
        symbol: 'ny',
      );

      expect(collisions.single.existing.assetId, _nyctisId);
      expect(collisions.single.matchesName, isTrue);
      expect(collisions.single.matchesSymbol, isTrue);
    });
  });
}
