import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/nightjar_config.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_button.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_proving_key_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_send_flow.dart';
import 'package:zcash_wallet/src/features/settings/screens/settings_nightjar_screen.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/nightjar_config_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';

import '../../fakes/fake_sync_notifier.dart';

const _accountState = AccountState(
  accounts: [AccountInfo(uuid: 'account-1', name: 'Account 1', order: 0)],
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
  themeMode: ThemeMode.light,
  privacyModeEnabled: false,
  isPasswordConfigured: true,
  isUnlocked: true,
  passwordRotationRecoveryFailed: false,
  nightjarConfig: config,
);

/// Mirrors the real notifier's contract — including `setEnabled` refusing an
/// unconfigured network — without touching `AppSecureStore`.
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

Widget _harness(NightjarConfig config, {NightjarProvingKeyStatus? provingKey}) {
  final router = GoRouter(
    initialLocation: '/settings/nightjar',
    routes: [
      GoRoute(
        path: '/settings/nightjar',
        builder: (_, _) => const SettingsNightjarScreen(),
      ),
      GoRoute(path: '/settings', builder: (_, _) => const SizedBox()),
      GoRoute(path: '/home', builder: (_, _) => const SizedBox()),
    ],
  );

  return ProviderScope(
    overrides: [
      appBootstrapProvider.overrideWithValue(_bootstrap(config)),
      syncProvider.overrideWith(FakeSyncNotifier.new),
      nightjarConfigProvider.overrideWith(
        () => _FakeNightjarConfigNotifier(config),
      ),
      nightjarProvingKeyProvider.overrideWith(
        (_) async => provingKey ?? _notSetKey,
      ),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      builder: (_, child) => AppTheme(data: AppThemeData.light, child: child!),
    ),
  );
}

Future<void> _pumpAt(
  WidgetTester tester,
  NightjarConfig config, {
  NightjarProvingKeyStatus? provingKey,
}) async {
  await tester.binding.setSurfaceSize(const Size(1512, 1800));
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(_harness(config, provingKey: provingKey));
  await tester.pump();
}

void main() {
  testWidgets('regtest starts off and the switch turns it on', (tester) async {
    await _pumpAt(tester, defaultNightjarConfig('regtest'));

    // The sidebar carries a 'Nightjar' item too, so the title is matched
    // through the pane heading rather than by text alone.
    expect(find.text(kNightjarSettingsTitle), findsWidgets);
    expect(find.text('Regtest'), findsOneWidget);
    expect(find.text(kNightjarSettingsEnabledLabel), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text(kNightjarSettingsEnableCopy), findsOneWidget);

    // The channel is shown rather than hidden: its viewing key is public.
    expect(find.text(kNightjarSettingsChannelTitle), findsOneWidget);
    expect(find.text('Birthday height'), findsOneWidget);
    expect(find.text('$kNightjarRegtestBirthday'), findsOneWidget);
    expect(find.textContaining(kNightjarRegtestIndexerUrl), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey('nightjar_settings_enable_toggle')),
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

    expect(find.text('None on this network'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('nightjar_settings_enable_toggle')),
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
      find.byKey(const ValueKey('nightjar_settings_unavailable')),
      findsOneWidget,
    );
    expect(find.text(config.unconfiguredReason!), findsOneWidget);
    expect(find.text(nightjarSettingsUnavailableCopy('main')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('nightjar_settings_enable_toggle')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('nightjar_indexer_field')), findsNothing);
  });

  testWidgets('a bad custom indexer shows the normalizer message verbatim', (
    tester,
  ) async {
    await _pumpAt(tester, defaultNightjarConfig('regtest'));

    await tester.tap(
      find.byKey(const ValueKey('nightjar_indexer_option_custom')),
    );
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('nightjar_indexer_field')),
      'http://indexer.example',
    );
    await tester.pump();

    expect(find.text('Use an https:// URL.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('nightjar_indexer_field')),
      'https://indexer.example',
    );
    await tester.pump();
    expect(find.text('Use an https:// URL.'), findsNothing);

    final update = find.byKey(const ValueKey('nightjar_indexer_update'));
    await tester.ensureVisible(update);
    await tester.pump();
    await tester.tap(update);
    await tester.pump();

    // Saving a custom origin is what makes the reset affordance appear.
    expect(
      find.byKey(const ValueKey('nightjar_settings_reset')),
      findsOneWidget,
    );
  });

  group('the proving-key folder', () {
    testWidgets('sending is off by default, and the screen says why', (
      tester,
    ) async {
      await _pumpAt(tester, defaultNightjarConfig('regtest'));
      await tester.pumpAndSettle();

      expect(find.text(kNightjarSettingsProvingKeyTitle), findsOneWidget);
      expect(find.text('Not set'), findsOneWidget);
      expect(find.text(kNightjarProvingKeyNotSetText), findsOneWidget);
      expect(find.text(kNightjarSettingsProvingKeyCopy), findsOneWidget);
      // Nothing to save, and no Forget button for a folder that is not set.
      expect(
        tester
            .widget<AppButton>(
              find.byKey(const ValueKey('nightjar_proving_key_save')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const ValueKey('nightjar_proving_key_clear')),
        findsNothing,
      );
    });

    testWidgets('a folder can be saved and comes back on the card', (
      tester,
    ) async {
      await _pumpAt(tester, defaultNightjarConfig('regtest'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('nightjar_proving_key_field')),
        '/devnet/keys',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nightjar_proving_key_save')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('nightjar_proving_key_clear')),
        findsOneWidget,
      );
    });

    testWidgets('a relative path is refused with the reason, not saved', (
      tester,
    ) async {
      await _pumpAt(tester, defaultNightjarConfig('regtest'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('nightjar_proving_key_field')),
        'keys',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nightjar_proving_key_save')));
      await tester.pumpAndSettle();

      expect(find.text('Enter the full path to the folder.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nightjar_proving_key_clear')),
        findsNothing,
      );
    });

    testWidgets('a checked folder shows the key it would prove with', (
      tester,
    ) async {
      await _pumpAt(
        tester,
        defaultNightjarConfig('regtest').copyWith(provingKeyDir: '/keys'),
        provingKey: NightjarProvingKeyStatus(
          state: NightjarProvingKeyState.ready,
          dir: '/keys',
          circuit: 'constraints=136119;instances=30',
          vkHash: 'ab' * 32,
          channelVkHash: 'ab' * 32,
          provingKeyBytes: BigInt.from(87031808),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('constraints=136119;instances=30'), findsOneWidget);
      expect(find.text('Verifying key'), findsOneWidget);
      expect(find.text('83 MiB'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nightjar_settings_proving_key_unverified')),
        findsNothing,
      );
    });

    testWidgets('a key set the channel rejects says so in full', (
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

      expect(find.text('Wrong key set'), findsOneWidget);
      expect(find.text(message), findsOneWidget);
    });

    testWidgets('a folder nobody compared with the channel says so', (
      tester,
    ) async {
      await _pumpAt(
        tester,
        defaultNightjarConfig('regtest').copyWith(provingKeyDir: '/keys'),
        provingKey: NightjarProvingKeyStatus(
          state: NightjarProvingKeyState.ready,
          dir: '/keys',
          vkHash: 'ab' * 32,
          provingKeyBytes: BigInt.from(87031808),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(kNightjarSettingsProvingKeyUnverifiedCopy),
        findsOneWidget,
      );
    });
  });
}
