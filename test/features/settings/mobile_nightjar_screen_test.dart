@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/nightjar_config.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_proving_key_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_send_flow.dart';
import 'package:zcash_wallet/src/features/settings/screens/mobile/mobile_nightjar_screen.dart';
import 'package:zcash_wallet/src/features/settings/screens/settings_nightjar_screen.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/nightjar_config_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';

import '../../fakes/fake_sync_notifier.dart';

const _accountState = AccountState(
  accounts: [AccountInfo(uuid: 'account-1', name: 'John', order: 0)],
  activeAccountUuid: 'account-1',
  activeAddress: 'u1nightjaraddress',
);

AppBootstrapState _bootstrap(NightjarConfig config) => AppBootstrapState(
  initialLocation: '/settings/nightjar',
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
  nightjarConfig: config,
);

/// Same contract as the real notifier — `setEnabled` refuses an unconfigured
/// network — without reaching `AppSecureStore`.
class _FakeNightjarConfigNotifier extends NightjarConfigNotifier {
  _FakeNightjarConfigNotifier(this.initial);

  final NightjarConfig initial;

  @override
  NightjarConfig build() => initial;

  @override
  Future<void> setEnabled(bool enabled) async {
    if (enabled && !state.isConfigured) {
      throw FormatException(
        state.unconfiguredReason ?? kNightjarSettingsNotConfigured,
      );
    }
    state = state.copyWith(enabled: enabled);
  }

  @override
  Future<void> setIndexerUrl(String input) async {
    state = state.copyWith(indexerUrl: normalizeNightjarIndexerUrl(input));
  }

  @override
  Future<void> resetIndexerUrlToDefault() async {
    state = state.copyWith(
      indexerUrl: defaultNightjarIndexerUrl(state.networkName),
    );
  }

  @override
  Future<void> setProvingKeyDir(String input) async {
    state = state.copyWith(
      provingKeyDir: normalizeNightjarProvingKeyDir(input),
    );
  }

  @override
  Future<void> clearProvingKeyDir() async {
    state = state.copyWith(provingKeyDir: '');
  }

  @override
  Future<void> resetToDefault() async {
    state = defaultNightjarConfig(state.networkName);
  }
}

/// The verdict on the configured folder. Overridden in every test so the
/// screen never reaches the native check — or, through it, the indexer.
const _notSetKey = NightjarProvingKeyStatus(
  state: NightjarProvingKeyState.notSet,
  message: kNightjarProvingKeyNotSetText,
);

Widget _app(NightjarConfig config, {NightjarProvingKeyStatus? provingKey}) {
  return ProviderScope(
    overrides: [
      appBootstrapProvider.overrideWithValue(_bootstrap(config)),
      syncProvider.overrideWith(() => FakeSyncNotifier(SyncState())),
      nightjarConfigProvider.overrideWith(
        () => _FakeNightjarConfigNotifier(config),
      ),
      nightjarProvingKeyProvider.overrideWith(
        (_) async => provingKey ?? _notSetKey,
      ),
    ],
    child: MaterialApp(
      builder: (_, child) => AppTheme(data: AppThemeData.dark, child: child!),
      home: const MobileNightjarScreen(),
    ),
  );
}

Future<void> _pumpAt(
  WidgetTester tester,
  NightjarConfig config, {
  NightjarProvingKeyStatus? provingKey,
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
    await _pumpAt(tester, defaultNightjarConfig('regtest'));

    expect(find.text(kNightjarSettingsTitle), findsOneWidget);
    expect(find.text('Regtest'), findsOneWidget);
    expect(find.text(kNightjarSettingsEnabledLabel), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text(kNightjarSettingsEnableCopy), findsOneWidget);
    expect(find.text(kNightjarSettingsChannelTitle), findsOneWidget);
    expect(find.text('Birthday height'), findsOneWidget);
    expect(find.text('$kNightjarRegtestBirthday'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mobile_nightjar_settings_enable_toggle')),
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
      defaultNightjarConfig('regtest').copyWith(indexerUrl: ''),
    );

    await tester.tap(
      find.byKey(const ValueKey('mobile_nightjar_settings_enable_toggle')),
    );
    await tester.pump();

    expect(
      find.text('Add a Nightjar indexer before loading assets.'),
      findsOneWidget,
    );
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('mainnet says Nightjar is not available instead of showing a '
      'switch', (tester) async {
    final config = defaultNightjarConfig('main');
    await _pumpAt(tester, config);

    expect(
      find.byKey(const ValueKey('mobile_nightjar_settings_unavailable')),
      findsOneWidget,
    );
    expect(find.text(config.unconfiguredReason!), findsOneWidget);
    expect(find.text(nightjarSettingsUnavailableCopy('main')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile_nightjar_settings_enable_toggle')),
      findsNothing,
    );
  });

  testWidgets('a bad custom indexer shows the normalizer message verbatim', (
    tester,
  ) async {
    await _pumpAt(tester, defaultNightjarConfig('regtest'));

    // The indexer controls sit below the enable card and the channel facts.
    final customOption = find.byKey(
      const ValueKey('mobile_nightjar_indexer_option_custom'),
    );
    await tester.scrollUntilVisible(customOption, 200);
    await tester.pump();
    await tester.tap(customOption);
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('mobile_nightjar_indexer_field')),
      'http://indexer.example',
    );
    await tester.pump();

    expect(find.text('Use an https:// URL.'), findsOneWidget);
  });

  testWidgets('sending is off by default and the mobile screen says why', (
    tester,
  ) async {
    await _pumpAt(tester, defaultNightjarConfig('regtest'));
    await tester.pumpAndSettle();

    final list = find.byType(ListView);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('mobile_nightjar_proving_key_field_shell')),
      300,
      scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    await tester.pumpAndSettle();

    expect(find.text(kNightjarSettingsProvingKeyTitle), findsOneWidget);
    expect(find.text('Not set'), findsOneWidget);
    expect(find.text(kNightjarProvingKeyNotSetText), findsOneWidget);
  });

  testWidgets('a key set the channel rejects says so on mobile too', (
    tester,
  ) async {
    const message =
        'The proving keys in /keys belong to a different key set than this '
        'channel verifies with.';
    await _pumpAt(
      tester,
      defaultNightjarConfig('regtest').copyWith(provingKeyDir: '/keys'),
      provingKey: const NightjarProvingKeyStatus(
        state: NightjarProvingKeyState.wrongKeySet,
        dir: '/keys',
        message: message,
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('mobile_nightjar_settings_proving_key_status')),
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
