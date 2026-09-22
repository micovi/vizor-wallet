import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/profile_pictures.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/activity/nightjar_activity_provider.dart';
import 'package:zcash_wallet/src/features/activity/screens/activity_screen.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;

import '../../fakes/fake_sync_notifier.dart';

const _dmtAssetId =
    'a3f1c0d29b8e47a5f6031d8c2b7e4906aa11bb22cc33dd44ee55ff6600778899';
const _receiptMsgId =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _sendMsgId =
    '2222222222222222222222222222222222222222222222222222222222222222';

const _accountState = AccountState(
  accounts: [
    AccountInfo(
      uuid: 'account-1',
      name: 'Account1',
      order: 0,
      profilePictureId: kDefaultProfilePictureId,
    ),
  ],
  activeAccountUuid: 'account-1',
  activeAddress: 'u1activityaddress',
);

final _bootstrap = AppBootstrapState(
  initialLocation: '/activity',
  initialAccountState: _accountState,
  initialSyncSnapshot: AppSyncSnapshot.empty,
  network: 'main',
  rpcEndpointConfig: defaultRpcEndpointConfig('main'),
  themeMode: ThemeMode.dark,
  privacyModeEnabled: false,
  isPasswordConfigured: true,
  isUnlocked: true,
  passwordRotationRecoveryFailed: false,
);

rust_sync.TransactionInfo _receivedZec() {
  final seconds = BigInt.from(
    DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000,
  );
  return rust_sync.TransactionInfo(
    txidHex: 'aa',
    minedHeight: BigInt.from(7180),
    expiredUnmined: false,
    accountBalanceDelta: 0,
    fee: BigInt.zero,
    blockTime: seconds,
    isTransparent: false,
    txKind: 'received',
    displayAmount: BigInt.from(125000000),
    displayPool: 'shielded',
    createdTime: seconds,
  );
}

/// The devnet shape: 1 000 NC received at 7 246 and spent at 7 257, leaving
/// 988 NC of change. The feed this replaced showed one row, `+988`.
NightjarViewData _sendAndReceiptView() {
  return NightjarViewData(
    status: NightjarViewStatus.ready,
    viewHeight: BigInt.from(7258),
    assets: [
      NightjarAssetDetailData(
        assetId: _dmtAssetId,
        name: 'Nightcash',
        symbol: 'NC',
        isPublic: true,
        balance: BigInt.from(988),
        decimals: 0,
        notes: [
          NightjarNoteRowData(
            position: BigInt.from(10),
            amount: BigInt.from(1000),
            decimals: 0,
            createdHeight: BigInt.from(7246),
            spent: true,
            createdBy: _receiptMsgId,
            createdInputs: 1,
            createdOutputs: 2,
            spentBy: _sendMsgId,
            spentHeight: BigInt.from(7257),
            spentInputs: 1,
            spentOutputs: 2,
          ),
          NightjarNoteRowData(
            position: BigInt.from(20),
            amount: BigInt.from(988),
            decimals: 0,
            createdHeight: BigInt.from(7257),
            createdBy: _sendMsgId,
            createdInputs: 1,
            createdOutputs: 2,
          ),
        ],
      ),
    ],
  );
}

Future<void> _pumpActivityScreen(
  WidgetTester tester, {
  required List<Override> nightjarOverrides,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final router = GoRouter(
    initialLocation: '/activity',
    routes: [
      GoRoute(
        path: '/activity',
        builder: (_, _) =>
            ActivityScreen(historyLoader: (_) async => [_receivedZec()]),
      ),
      GoRoute(
        path: '/nightjar/:assetId',
        builder: (_, state) =>
            Text('nightjar asset ${state.pathParameters['assetId']}'),
      ),
      GoRoute(
        path: '/activity/nightjar/:messageId',
        builder: (_, state) =>
            Text('nightjar message ${state.pathParameters['messageId']}'),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appBootstrapProvider.overrideWithValue(_bootstrap),
        syncProvider.overrideWith(
          () => FakeSyncNotifier(
            SyncState(accountUuid: 'account-1', hasAccountScopedData: true),
          ),
        ),
        ...nightjarOverrides,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => AppTheme(data: AppThemeData.dark, child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a Nightjar send renders beside the ZEC transactions', (
    tester,
  ) async {
    await _pumpActivityScreen(
      tester,
      nightjarOverrides: [
        nightjarAssetsViewProvider.overrideWith(
          (ref) async => _sendAndReceiptView(),
        ),
        nightjarBlockTimeLoaderProvider.overrideWithValue(
          (heights) async => {
            for (final height in heights)
              height: DateTime.now().subtract(const Duration(hours: 2)),
          },
        ),
      ],
    );

    // What left, not what came back.
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('-12 NC'), findsOneWidget);
    expect(find.text('Nightcash · block 7,257'), findsOneWidget);
    // And the receipt the old feed lost the moment the note was spent.
    expect(find.text('+1,000 NC'), findsOneWidget);
    expect(find.text('Nightcash · block 7,246'), findsOneWidget);
    // The change note is folded into the send and is nobody's arrival.
    expect(find.textContaining('988'), findsNothing);
  });

  testWidgets('tapping a Nightjar row opens the message receipt', (
    tester,
  ) async {
    await _pumpActivityScreen(
      tester,
      nightjarOverrides: [
        nightjarAssetsViewProvider.overrideWith(
          (ref) async => _sendAndReceiptView(),
        ),
        nightjarBlockTimeLoaderProvider.overrideWithValue(
          (heights) async => {
            for (final height in heights)
              height: DateTime.now().subtract(const Duration(hours: 2)),
          },
        ),
      ],
    );

    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();

    expect(find.text('nightjar message $_sendMsgId'), findsOneWidget);
  });

  testWidgets('a failing Nightjar load leaves the ZEC feed untouched', (
    tester,
  ) async {
    await _pumpActivityScreen(
      tester,
      nightjarOverrides: [
        nightjarAssetsViewProvider.overrideWith(
          (ref) async => throw StateError('indexer down'),
        ),
      ],
    );

    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Sent'), findsNothing);
    expect(find.textContaining('Nightcash'), findsNothing);
    expect(find.text('Activity could not be loaded.'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a Nightjar load that never answers does not block the feed', (
    tester,
  ) async {
    await _pumpActivityScreen(
      tester,
      nightjarOverrides: [
        nightjarAssetsViewProvider.overrideWith(
          (ref) => Completer<NightjarViewData>().future,
        ),
      ],
    );

    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Sent'), findsNothing);
  });
}
