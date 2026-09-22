import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/nightjar_config.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/providers/nightjar_config_provider.dart';

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

  AppBootstrapState bootstrapWith(NightjarConfig? config, {String? network}) {
    final resolvedNetwork = network ?? ZcashNetwork.regtest.name;
    return AppBootstrapState(
      initialLocation: '/home',
      initialAccountState: AppBootstrapState.empty.initialAccountState,
      initialSyncSnapshot: AppSyncSnapshot.empty,
      network: resolvedNetwork,
      rpcEndpointConfig: defaultRpcEndpointConfig(resolvedNetwork),
      nightjarConfig: config,
      themeMode: AppBootstrapState.empty.themeMode,
      privacyModeEnabled: false,
      isPasswordConfigured: true,
      isUnlocked: true,
      passwordRotationRecoveryFailed: false,
    );
  }

  test('starts from the bootstrap snapshot', () {
    final stored = defaultNightjarConfig(
      ZcashNetwork.regtest.name,
    ).copyWith(indexerUrl: 'http://127.0.0.1:9999', enabled: true);
    final container = containerFor(bootstrapWith(stored));

    expect(container.read(nightjarConfigProvider), stored);
    expect(container.read(nightjarConfigProvider).isUsable, isTrue);
    expect(
      container.read(nightjarConfigProvider.notifier).isCustomIndexer,
      isTrue,
    );
    expect(
      container.read(nightjarConfigProvider.notifier).isCustomChannel,
      isFalse,
    );
  });

  test('a snapshot with no Nightjar settings falls back to the network', () {
    final container = containerFor(bootstrapWith(null));

    expect(
      container.read(nightjarConfigProvider),
      defaultNightjarConfig(ZcashNetwork.regtest.name),
    );
    expect(container.read(nightjarConfigProvider).enabled, isFalse);
  });

  test('a network with no channel stays unusable', () {
    final container = containerFor(
      bootstrapWith(null, network: ZcashNetwork.mainnet.name),
    );

    final config = container.read(nightjarConfigProvider);
    expect(config.isConfigured, isFalse);
    expect(config.isUsable, isFalse);
    expect(
      config.unconfiguredReason,
      'Nightjar has no channel on this network yet.',
    );
  });

  test('enabling an unconfigured network is refused, not stored', () async {
    final container = containerFor(
      bootstrapWith(null, network: ZcashNetwork.mainnet.name),
    );
    final notifier = container.read(nightjarConfigProvider.notifier);

    await expectLater(
      notifier.setEnabled(true),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Nightjar has no channel on this network yet.',
        ),
      ),
    );
    expect(container.read(nightjarConfigProvider).enabled, isFalse);
  });
}
