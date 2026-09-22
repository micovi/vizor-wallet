/// Shared scaffolding for the Nightjar send screens, so the desktop and
/// mobile lanes drive the same widgets from the same fixtures.
///
/// Every seam that would otherwise reach Rust is overridden here: the view
/// loader, the proving-key check, the chain tip, and the broadcast runner.
/// Nothing in these tests touches the network or the native library.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' show MaterialApp, Material, MaterialType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/nightjar_config.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_button.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_proving_key_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/screens/nightjar_send_status_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_send_flow.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/providers/nightjar_config_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';

/// The asset every send fixture is about.
const kHarnessAssetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';

const kHarnessChannelAddress = 'uregtestchanneladdress';
const kHarnessRecipient = 'njreg1recipient';

/// A regtest configuration with a channel and a proving-key folder, so the
/// screens have something to refuse or accept.
final harnessConfig = defaultNightjarConfig(ZcashNetwork.regtest.name).copyWith(
  enabled: true,
  channelAddress: kHarnessChannelAddress,
  provingKeyDir: '/keys',
);

/// A proving key that matches the channel's.
const readyProvingKey = NightjarProvingKeyStatus(
  state: NightjarProvingKeyState.ready,
  dir: '/keys',
  circuit: 'constraints=136119;instances=30',
  vkHash: '19efd525dc3cf96796bbb760ef38c03f244a51f04e528d85835c2f262496d37b',
  channelVkHash:
      '19efd525dc3cf96796bbb760ef38c03f244a51f04e528d85835c2f262496d37b',
);

/// A replayed view holding one named asset at six decimals.
NightjarViewData harnessReadyView({BigInt? balance}) {
  final held = balance ?? BigInt.from(1250000);
  return NightjarViewData(
    status: NightjarViewStatus.ready,
    vkHash: '19efd525dc3cf96796bbb760ef38c03f244a51f04e528d85835c2f262496d37b',
    assets: [
      NightjarAssetDetailData(
        assetId: kHarnessAssetId,
        name: 'Harbour credit',
        symbol: 'HBC',
        isPublic: true,
        balance: held,
        decimals: 6,
        issuedSupply: BigInt.from(500000000000),
        notes: [
          if (held > BigInt.zero)
            NightjarNoteRowData(
              position: BigInt.from(41),
              amount: held,
              decimals: 6,
              createdHeight: BigInt.from(1240),
            ),
        ],
      ),
    ],
  );
}

/// A built plan, with the memo count the caller wants to reason about.
NightjarSendReviewArgs harnessReviewArgs({
  int memoCount = 2,
  int anchorHeight = 6913,
  int chainTip = 6923,
}) {
  return NightjarSendReviewArgs(
    sendFlowId: 'flow-1',
    accountUuid: 'account-1',
    msgId: '82852615ac3c4e2f9a7d1b6c5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f',
    assetId: kHarnessAssetId,
    assetSymbol: 'HBC',
    assetName: 'Harbour credit',
    assetDecimals: 6,
    amount: BigInt.from(500000),
    change: BigInt.from(750000),
    spent: BigInt.from(1250000),
    inputs: 1,
    recipient: kHarnessRecipient,
    channelAddress: kHarnessChannelAddress,
    memos: [
      for (var i = 0; i < memoCount; i++)
        Uint8List.fromList(List<int>.filled(512, 0xF0 + i)),
    ],
    memoValueZatoshi: BigInt.from(10000),
    bodyBytes: 812,
    anchorHeight: anchorHeight,
    chainTip: chainTip,
    vkHash: '19efd525dc3cf96796bbb760ef38c03f244a51f04e528d85835c2f262496d37b',
    provedMs: 1300,
    builtAt: DateTime(2026, 9, 21),
  );
}

/// A broadcast runner that answers with [outcome], or never answers at all
/// when it is null — which is what the screen looks like mid-send.
NightjarSendBroadcastRunner harnessRunner(NightjarSendOutcome? outcome) {
  return ({
    required WidgetRef ref,
    required NightjarSendReviewArgs args,
    void Function(NightjarSendPhase phase)? onPhase,
    Future<bool> Function()? shouldAbort,
  }) {
    onPhase?.call(NightjarSendPhase.proposing);
    if (outcome == null) return Completer<NightjarSendOutcome>().future;
    return Future<NightjarSendOutcome>.value(outcome);
  };
}

class _HarnessNightjarConfigNotifier extends NightjarConfigNotifier {
  _HarnessNightjarConfigNotifier(this.initial);

  final NightjarConfig initial;

  @override
  NightjarConfig build() => initial;
}

class _HarnessSyncNotifier extends SyncNotifier {
  _HarnessSyncNotifier(this.chainTip);

  final int chainTip;

  @override
  Future<SyncState> build() async => SyncState(chainTipHeight: chainTip);
}

/// Renders [pane] inside a router carrying the routes the send flow pushes to.
Future<void> pumpNightjarSend(
  WidgetTester tester,
  Widget pane, {
  NightjarViewLoader? loader,
  NightjarProvingKeyStatus? provingKey,
  NightjarConfig? config,
  int chainTip = 0,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final router = GoRouter(
    initialLocation: '/host',
    routes: [
      // `AppDesktopShell` and the mobile `Scaffold` each supply the Material
      // ancestor a text field needs; a pane rendered on its own does not.
      GoRoute(
        path: '/host',
        builder: (_, _) =>
            Material(type: MaterialType.transparency, child: pane),
      ),
      GoRoute(
        path: '/nightjar',
        builder: (_, _) => const Text('nightjar assets route'),
      ),
      GoRoute(
        path: '/nightjar/send/review',
        builder: (_, _) => const Text('review route'),
      ),
      GoRoute(
        path: '/nightjar/send/status',
        builder: (_, _) => const Text('status route'),
      ),
      GoRoute(
        path: '/nightjar/:assetId/send',
        builder: (_, state) =>
            Text('send route ${state.pathParameters['assetId']}'),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appBootstrapProvider.overrideWithValue(AppBootstrapState.empty),
        nightjarConfigProvider.overrideWith(
          () => _HarnessNightjarConfigNotifier(config ?? harnessConfig),
        ),
        syncProvider.overrideWith(() => _HarnessSyncNotifier(chainTip)),
        if (loader != null)
          nightjarViewLoaderProvider.overrideWithValue(loader),
        if (provingKey != null)
          nightjarProvingKeyProvider.overrideWith((_) async => provingKey),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => AppTheme(data: AppThemeData.dark, child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The button with [key], so a test can assert it is disabled rather than
/// tapping it and watching nothing happen.
AppButton appButtonWithKey(WidgetTester tester, String key) =>
    tester.widget<AppButton>(find.byKey(ValueKey(key)));

AppButton reviewButton(WidgetTester tester) =>
    appButtonWithKey(tester, 'nightjar_send_review_button');
