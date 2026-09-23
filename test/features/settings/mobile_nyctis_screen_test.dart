@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/nyctis_config.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_proving_key_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_send_flow.dart';
import 'package:zcash_wallet/src/features/settings/screens/mobile/mobile_nyctis_screen.dart';
import 'package:zcash_wallet/src/features/settings/screens/settings_nyctis_screen.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/nyctis_config_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';

import '../../fakes/fake_sync_notifier.dart';

const _accountState = AccountState(
  accounts: [AccountInfo(uuid: 'account-1', name: 'John', order: 0)],
  activeAccountUuid: 'account-1',
  activeAddress: 'u1nyctisaddress',
);

AppBootstrapState _bootstrap(NyctisConfig config) => AppBootstrapState(
  initialLocation: '/settings/nyctis',
  initialAccountState: _accountState,
  initialSyncSnapshot: AppSyncSnapshot.empty,
  network: 'main',
  rpcEndpointConfig: defaultRpcEndpointConfig('main'),
  explorerUrlTemplate: '',
  themeMode: ThemeMode.dark,
  privacyModeEnabled: false,
  isPasswordConfigured: true,
  isUnlocked: true,
  passwordRotationRecoveryFailed: false,
  nyctisConfig: config,
);

/// Same contract as the real notifier — `setEnabled` refuses an unconfigured
/// network — without reaching `AppSecureStore`.
class _FakeNyctisConfigNotifier extends NyctisConfigNotifier {
  _FakeNyctisConfigNotifier(this.initial);

  final NyctisConfig initial;

  @override
  NyctisConfig build() => initial;

  @override
  Future<void> setEnabled(bool enabled) async {
    if (enabled && !state.isConfigured) {
      throw FormatException(
        state.unconfiguredReason ?? kNyctisSettingsNotConfigured,
      );
    }
    state = state.copyWith(enabled: enabled);
  }

  @override
  Future<void> setIndexerUrl(String input) async {
    state = state.copyWith(indexerUrl: normalizeNyctisIndexerUrl(input));
  }

  @override
  Future<void> resetIndexerUrlToDefault() async {
    state = state.copyWith(
      indexerUrl: defaultNyctisIndexerUrl(state.networkName),
    );
  }

  @override
  Future<void> setProvingKeyDir(String input) async {
    state = state.copyWith(
      provingKeyDir: normalizeNyctisProvingKeyDir(input),
    );
  }

  @override
  Future<void> clearProvingKeyDir() async {
    state = state.copyWith(provingKeyDir: '');
  }

  @override
  Future<void> resetToDefault() async {
    state = defaultNyctisConfig(state.networkName);
  }
}

/// The verdict on the configured folder. Overridden in every test so the
/// screen never reaches the native check — or, through it, the indexer.
const _notSetKey = NyctisProvingKeyStatus(
  state: NyctisProvingKeyState.notSet,
  message: kNyctisProvingKeyNotSetText,
);

Widget _app(NyctisConfig config, {NyctisProvingKeyStatus? provingKey}) {
  return ProviderScope(
    overrides: [
      appBootstrapProvider.overrideWithValue(_bootstrap(config)),
      syncProvider.overrideWith(() => FakeSyncNotifier(SyncState())),
      nyctisConfigProvider.overrideWith(
        () => _FakeNyctisConfigNotifier(config),
      ),
      nyctisProvingKeyProvider.overrideWith(
        (_) async => provingKey ?? _notSetKey,
      ),
    ],
    child: MaterialApp(
      builder: (_, child) => AppTheme(data: AppThemeData.dark, child: child!),
      home: const MobileNyctisScreen(),
    ),
  );
}

Future<void> _pumpAt(
  WidgetTester tester,
  NyctisConfig config, {
  NyctisProvingKeyStatus? provingKey,
}) async {
  tester.view
    ..physicalSize = const Size(393, 852)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(_app(config, provingKey: provingKey));
  await tester.pump();
}

void main() {
  testWidgets('regtest starts off and the switch turns it on', (tester) async {
    await _pumpAt(tester, defaultNyctisConfig('regtest'));

    expect(find.text(kNyctisSettingsTitle), findsOneWidget);
    expect(find.text('Regtest'), findsOneWidget);
    expect(find.text(kNyctisSettingsEnabledLabel), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text(kNyctisSettingsEnableCopy), findsOneWidget);
    expect(find.text(kNyctisSettingsChannelTitle), findsOneWidget);
    expect(find.text('Birthday height'), findsOneWidget);
    expect(find.text('$kNyctisRegtestBirthday'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mobile_nyctis_settings_enable_toggle')),
    );
    await tester.pump();

    expect(find.text('On'), findsOneWidget);
    expect(find.text('Turn off'), findsOneWidget);
  });

  testWidgets('enabling without an indexer shows the refusal from setEnabled', (
    tester,
  ) async {
    await _pumpAt(
      tester,
      defaultNyctisConfig('regtest').copyWith(indexerUrl: ''),
    );

    await tester.tap(
      find.byKey(const ValueKey('mobile_nyctis_settings_enable_toggle')),
    );
    await tester.pump();

    expect(
      find.text('Add a Nyctis indexer before loading assets.'),
      findsOneWidget,
    );
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('mainnet says Nyctis is not available instead of showing a '
      'switch', (tester) async {
    final config = defaultNyctisConfig('main');
    await _pumpAt(tester, config);

    expect(
      find.byKey(const ValueKey('mobile_nyctis_settings_unavailable')),
      findsOneWidget,
    );
    expect(find.text(config.unconfiguredReason!), findsOneWidget);
    expect(find.text(nyctisSettingsUnavailableCopy('main')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile_nyctis_settings_enable_toggle')),
      findsNothing,
    );
  });

  testWidgets('a bad custom indexer shows the normalizer message verbatim', (
    tester,
  ) async {
    await _pumpAt(tester, defaultNyctisConfig('regtest'));

    // The indexer controls sit below the enable card and the channel facts.
    final customOption = find.byKey(
      const ValueKey('mobile_nyctis_indexer_option_custom'),
    );
    await tester.scrollUntilVisible(customOption, 200);
    await tester.pump();
    await tester.tap(customOption);
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('mobile_nyctis_indexer_field')),
      'http://indexer.example',
    );
    await tester.pump();

    expect(find.text('Use an https:// URL.'), findsOneWidget);
  });

  testWidgets('sending is off by default and the mobile screen says why', (
    tester,
  ) async {
    await _pumpAt(tester, defaultNyctisConfig('regtest'));
    await tester.pumpAndSettle();

    final list = find.byType(ListView);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('mobile_nyctis_proving_key_field_shell')),
      300,
      scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    await tester.pumpAndSettle();

    expect(find.text(kNyctisSettingsProvingKeyTitle), findsOneWidget);
    expect(find.text('Not set'), findsOneWidget);
    expect(find.text(kNyctisProvingKeyNotSetText), findsOneWidget);
  });

  testWidgets('a key set the channel rejects says so on mobile too', (
    tester,
  ) async {
    const message =
        'The proving keys in /keys belong to a different key set than this '
        'channel verifies with.';
    await _pumpAt(
      tester,
      defaultNyctisConfig('regtest').copyWith(provingKeyDir: '/keys'),
      provingKey: const NyctisProvingKeyStatus(
        state: NyctisProvingKeyState.wrongKeySet,
        dir: '/keys',
        message: message,
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('mobile_nyctis_settings_proving_key_status')),
      300,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Wrong key set'), findsOneWidget);
    expect(find.text(message), findsOneWidget);
  });
}
