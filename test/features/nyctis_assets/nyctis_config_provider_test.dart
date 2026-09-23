import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/nyctis_config.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/providers/nyctis_config_provider.dart';

/// These exercise only the read side, which is what the startup snapshot
/// feeds. The write side goes through `AppSecureStore.instance` exactly like
/// `ZcashExplorerNotifier`, so it belongs to a storage-backed test rather than
/// this one.
void main() {
  ProviderContainer containerFor(AppBootstrapState bootstrap) {
    final container = ProviderContainer(
      overrides: [appBootstrapProvider.overrideWithValue(bootstrap)],
    );
    addTearDown(container.dispose);
    return container;
  }

  AppBootstrapState bootstrapWith(NyctisConfig? config, {String? network}) {
    final resolvedNetwork = network ?? ZcashNetwork.regtest.name;
    return AppBootstrapState(
      initialLocation: '/home',
      initialAccountState: AppBootstrapState.empty.initialAccountState,
      initialSyncSnapshot: AppSyncSnapshot.empty,
      network: resolvedNetwork,
      rpcEndpointConfig: defaultRpcEndpointConfig(resolvedNetwork),
      nyctisConfig: config,
      themeMode: AppBootstrapState.empty.themeMode,
      privacyModeEnabled: false,
      isPasswordConfigured: true,
      isUnlocked: true,
      passwordRotationRecoveryFailed: false,
    );
  }

  test('starts from the bootstrap snapshot', () {
    final stored = defaultNyctisConfig(
      ZcashNetwork.regtest.name,
    ).copyWith(indexerUrl: 'http://127.0.0.1:9999', enabled: true);
    final container = containerFor(bootstrapWith(stored));

    expect(container.read(nyctisConfigProvider), stored);
    expect(container.read(nyctisConfigProvider).isUsable, isTrue);
    expect(
      container.read(nyctisConfigProvider.notifier).isCustomIndexer,
      isTrue,
    );
    expect(
      container.read(nyctisConfigProvider.notifier).isCustomChannel,
      isFalse,
    );
  });

  test('a snapshot with no Nyctis settings falls back to the network', () {
    final container = containerFor(bootstrapWith(null));

    expect(
      container.read(nyctisConfigProvider),
      defaultNyctisConfig(ZcashNetwork.regtest.name),
    );
    expect(container.read(nyctisConfigProvider).enabled, isFalse);
  });

  test('a network with no channel stays unusable', () {
    final container = containerFor(
      bootstrapWith(null, network: ZcashNetwork.mainnet.name),
    );

    final config = container.read(nyctisConfigProvider);
    expect(config.isConfigured, isFalse);
    expect(config.isUsable, isFalse);
    expect(
      config.unconfiguredReason,
      'Nyctis has no channel on this network yet.',
    );
  });

  test('enabling an unconfigured network is refused, not stored', () async {
    final container = containerFor(
      bootstrapWith(null, network: ZcashNetwork.mainnet.name),
    );
    final notifier = container.read(nyctisConfigProvider.notifier);

    await expectLater(
      notifier.setEnabled(true),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Nyctis has no channel on this network yet.',
        ),
      ),
    );
    expect(container.read(nyctisConfigProvider).enabled, isFalse);
  });
}
