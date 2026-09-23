/// Shared scaffolding for the Nyctis send screens, so the desktop and
/// mobile lanes drive the same widgets from the same fixtures.
///
/// Every seam that would otherwise reach Rust is overridden here: the view
/// loader, the proving-key check, the chain tip, and the broadcast runner.
/// Nothing in these tests touches the network or the native library.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' show MaterialApp, Material, MaterialType;
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/nyctis_config.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_button.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_in_flight_send_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_proving_key_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/screens/nyctis_send_status_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_send_flow.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/providers/account_models.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/nyctis_config_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';

/// The asset every send fixture is about.
const kHarnessAssetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';

const kHarnessChannelAddress = 'uregtestchanneladdress';

/// A real regtest Nyctis address (the demo-seed vector in
/// `rust/src/nyctis/keys.rs`), so the composer's format check passes.
const kHarnessRecipient =
    'nyreg1qzxdgxkjg4vgjux6rw63t0akwkq03q5stfz9txpjcqx0mgcmpfrqk2per2w388qnr'
    'tc7t5mh9nux7ftrxq0xsc9gjv9shuymray29qq8yqcqxexsz2hwz2f6nmtmvgr46ja60dfg'
    'kasmf5tsg3a3jtq9hs9sxafxqq';

/// The account every harness screen runs as.
const kHarnessAccountUuid = 'account-1';

/// A quote a review can confirm: a 0.00015 ZEC network fee.
NyctisSendQuoter harnessQuoter({
  BigInt? fee,
  String? error,
  Completer<NyctisZecQuote>? gate,
}) {
  return (plan) {
    if (gate != null) return gate.future;
    if (error != null) {
      return Future.value(
        NyctisZecQuote.failed(
          error: error,
          channelZatoshi: plan.channelZatoshi,
        ),
      );
    }
    return Future.value(
      NyctisZecQuote.ready(
        feeZatoshi: fee ?? BigInt.from(15000),
        channelZatoshi: plan.channelZatoshi,
      ),
    );
  };
}

/// A regtest configuration with a channel and a proving-key folder, so the
/// screens have something to refuse or accept.
final harnessConfig = defaultNyctisConfig(ZcashNetwork.regtest.name).copyWith(
  enabled: true,
  channelAddress: kHarnessChannelAddress,
  provingKeyDir: '/keys',
);

/// A proving key that matches the channel's.
const readyProvingKey = NyctisProvingKeyStatus(
  state: NyctisProvingKeyState.ready,
  dir: '/keys',
  circuit: 'constraints=136119;instances=30',
  vkHash: '19efd525dc3cf96796bbb760ef38c03f244a51f04e528d85835c2f262496d37b',
  channelVkHash:
      '19efd525dc3cf96796bbb760ef38c03f244a51f04e528d85835c2f262496d37b',
);

/// A replayed view holding one named asset at six decimals.
NyctisViewData harnessReadyView({
  BigInt? balance,
  List<NyctisNoteRowData>? notes,
  BigInt? viewHeight,
}) {
  final held = balance ?? BigInt.from(1250000);
  return NyctisViewData(
    status: NyctisViewStatus.ready,
    viewHeight: viewHeight,
    vkHash: '19efd525dc3cf96796bbb760ef38c03f244a51f04e528d85835c2f262496d37b',
    assets: [
      NyctisAssetDetailData(
        assetId: kHarnessAssetId,
        name: 'Harbour credit',
        symbol: 'HBC',
        isPublic: true,
        balance: held,
        decimals: 6,
        issuedSupply: BigInt.from(500000000000),
        notes:
            notes ??
            [
              if (held > BigInt.zero)
                NyctisNoteRowData(
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
NyctisSendReviewArgs harnessReviewArgs({
  int memoCount = 2,
  int anchorHeight = 6913,
  int chainTip = 6923,
}) {
  return NyctisSendReviewArgs(
    sendFlowId: 'flow-1',
    accountUuid: kHarnessAccountUuid,
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
NyctisSendBroadcastRunner harnessRunner(NyctisSendOutcome? outcome) {
  return ({
    required WidgetRef ref,
    required NyctisSendReviewArgs args,
    void Function(NyctisSendPhase phase)? onPhase,
    Future<bool> Function()? shouldAbort,
  }) {
    onPhase?.call(NyctisSendPhase.proposing);
    if (outcome == null) return Completer<NyctisSendOutcome>().future;
    return Future<NyctisSendOutcome>.value(outcome);
  };
}

class _HarnessNyctisConfigNotifier extends NyctisConfigNotifier {
  _HarnessNyctisConfigNotifier(this.initial);

  final NyctisConfig initial;

  @override
  NyctisConfig build() => initial;
}

class _HarnessSyncNotifier extends SyncNotifier {
  _HarnessSyncNotifier(this.chainTip, this.spendableZatoshi);

  final int chainTip;

  /// Null leaves balance data unknown, so no ZEC check applies.
  final BigInt? spendableZatoshi;

  @override
  Future<SyncState> build() async => SyncState(
    chainTipHeight: chainTip,
    hasBalanceData: spendableZatoshi != null,
    spendableBalance: spendableZatoshi,
  );
}

class _HarnessAccountNotifier extends AccountNotifier {
  _HarnessAccountNotifier({required this.hardware});

  final bool hardware;

  @override
  FutureOr<AccountState> build() => AccountState(
    accounts: [
      AccountInfo(
        uuid: kHarnessAccountUuid,
        name: 'Account 1',
        order: 0,
        isHardware: hardware,
      ),
    ],
    activeAccountUuid: kHarnessAccountUuid,
  );
}

/// Renders [pane] inside a router carrying the routes the send flow pushes to.
///
/// [inFlight] is the store the in-flight guard restores from and writes to;
/// pass one to seed earlier payments or to inspect what a screen recorded.
Future<ProviderContainer> pumpNyctisSend(
  WidgetTester tester,
  Widget pane, {
  NyctisViewLoader? loader,
  NyctisProvingKeyStatus? provingKey,
  NyctisConfig? config,
  int chainTip = 0,
  BigInt? spendableZatoshi,
  bool hardware = false,
  NyctisSendQuoter? quoter,
  NyctisPayPlanBuilder? planBuilder,
  MemoryNyctisInFlightSendStore? inFlight,
  String initialLocation = '/host',
  List<RouteBase> extraRoutes = const [],
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      ...extraRoutes,
      // `AppDesktopShell` and the mobile `Scaffold` each supply the Material
      // ancestor a text field needs; a pane rendered on its own does not.
      GoRoute(
        path: '/host',
        builder: (_, _) =>
            Material(type: MaterialType.transparency, child: pane),
      ),
      GoRoute(
        path: '/nyctis',
        builder: (_, _) => const Text('nyctis assets route'),
      ),
      GoRoute(
        path: '/nyctis/send/review',
        builder: (_, _) => const Text('review route'),
      ),
      GoRoute(
        path: '/nyctis/send/status',
        builder: (_, _) => const Text('status route'),
      ),
      GoRoute(
        path: '/nyctis/:assetId/send',
        builder: (_, state) =>
            Text('send route ${state.pathParameters['assetId']}'),
      ),
      GoRoute(
        path: '/nyctis/:assetId',
        builder: (_, state) =>
            Text('asset route ${state.pathParameters['assetId']}'),
      ),
      GoRoute(
        path: '/settings/nyctis',
        builder: (_, _) => const Text('nyctis settings route'),
      ),
    ],
  );

  final container = ProviderContainer(
    overrides: [
      appBootstrapProvider.overrideWithValue(AppBootstrapState.empty),
      nyctisConfigProvider.overrideWith(
        () => _HarnessNyctisConfigNotifier(config ?? harnessConfig),
      ),
      syncProvider.overrideWith(
        () => _HarnessSyncNotifier(chainTip, spendableZatoshi),
      ),
      accountProvider.overrideWith(
        () => _HarnessAccountNotifier(hardware: hardware),
      ),
      // Never the real loader: it would read the configured indexer.
      nyctisViewLoaderProvider.overrideWithValue(
        loader ?? () async => harnessReadyView(),
      ),
      // Never the real check: it would call into Rust.
      nyctisProvingKeyProvider.overrideWith(
        (_) async => provingKey ?? readyProvingKey,
      ),
      nyctisSendQuoterProvider.overrideWithValue(quoter ?? harnessQuoter()),
      if (planBuilder != null)
        nyctisPayPlanBuilderProvider.overrideWithValue(planBuilder),
      nyctisInFlightSendStoreProvider.overrideWithValue(
        inFlight ?? MemoryNyctisInFlightSendStore(),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => AppTheme(data: AppThemeData.dark, child: child!),
      ),
    ),
  );
  // A pane that is busy from its first frame — a status pane whose broadcast
  // never finishes — draws the shared loader, which repeats for as long as
  // it is on screen and so never settles. Such a test pumps frames itself.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return container;
}

/// The button with [key], so a test can assert it is disabled rather than
/// tapping it and watching nothing happen.
AppButton appButtonWithKey(WidgetTester tester, String key) =>
    tester.widget<AppButton>(find.byKey(ValueKey(key)));

AppButton reviewButton(WidgetTester tester) =>
    appButtonWithKey(tester, 'nyctis_send_review_button');

/// A plan builder that reports [phases] and then answers with [result], or
/// holds at the proving phase until [gate] completes. Counts its calls, so a
/// test can prove a second Review press started nothing.
class HarnessPlanBuilder {
  HarnessPlanBuilder({this.result, this.gate});

  final NyctisPayPlanResult? result;
  final Completer<void>? gate;
  var calls = 0;

  NyctisPayPlanBuilder get build =>
      ({
        required String assetId,
        required BigInt amount,
        required String recipient,
        String assetName = '',
        void Function(NyctisBuildPhase phase)? onPhase,
      }) async {
        calls++;
        onPhase?.call(NyctisBuildPhase.readingChannel);
        onPhase?.call(NyctisBuildPhase.proving);
        final gate = this.gate;
        if (gate != null) await gate.future;
        return result ?? NyctisPayPlanResult.ready(harnessReviewArgs());
      };
}

/// Screen-reader announcements made while [body] runs.
Future<List<String>> captureAnnouncements(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final said = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (message) async {
      if (message is Map && message['type'] == 'announce') {
        final data = message['data'];
        if (data is Map && data['message'] is String) {
          said.add(data['message'] as String);
        }
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(
          SystemChannels.accessibility,
          null,
        ),
  );
  await body();
  return said;
}
