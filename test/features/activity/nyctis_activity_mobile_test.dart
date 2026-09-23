@Tags(['mobile'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/profile_pictures.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/activity/nyctis_activity_provider.dart';
import 'package:zcash_wallet/src/features/activity/screens/mobile/mobile_activity_screen.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_metadata_fetcher_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_fetcher.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_transport.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/nyctis_config_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;

import '../../fakes/fake_sync_notifier.dart';
import '../nyctis_assets/support/nyctis_metadata_fixtures.dart';

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

AppBootstrapState _bootstrap({
  NyctisAssetAcceptance acceptance = const NyctisAssetAcceptance.empty(),
}) => AppBootstrapState(
  initialLocation: '/activity',
  nyctisAcceptedAssets: acceptance,
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

/// A receipt of 1 DMT at block 7 164 that this wallet still holds: one
/// message, one row, and no spend to fold into it.
NyctisViewData _viewWithOneReceipt({String? metadataUri}) {
  return NyctisViewData(
    status: NyctisViewStatus.ready,
    viewHeight: BigInt.from(7258),
    assets: [
      NyctisAssetDetailData(
        assetId: _dmtAssetId,
        name: 'Devnet Mint',
        symbol: 'DMT',
        isPublic: true,
        balance: BigInt.from(100),
        decimals: 2,
        metadataUri: metadataUri,
        notes: [
          NyctisNoteRowData(
            position: BigInt.from(12),
            amount: BigInt.from(100),
            decimals: 2,
            createdHeight: BigInt.from(7164),
            createdBy: _receiptMsgId,
            createdInputs: 1,
            createdOutputs: 1,
          ),
        ],
      ),
    ],
  );
}

/// The devnet pair, plus messages the channel is still settling: 1 000 DMT in
/// at 7 246, spent at 7 257, 988 left as change.
NyctisViewData _sendAndReceiptView({int pendingMessageCount = 0}) {
  return NyctisViewData(
    status: NyctisViewStatus.ready,
    viewHeight: BigInt.from(7258),
    pendingMessageCount: pendingMessageCount,
    assets: [
      NyctisAssetDetailData(
        assetId: _dmtAssetId,
        name: 'Nightcash',
        symbol: 'NC',
        balance: BigInt.from(988),
        decimals: 0,
        notes: [
          NyctisNoteRowData(
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
          NyctisNoteRowData(
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

Widget _app(
  List<Override> nyctisOverrides, {
  NyctisAssetAcceptance acceptance = const NyctisAssetAcceptance.empty(),
  bool nyctisEnabled = true,
}) {
  return ProviderScope(
    overrides: [
      // Nyctis ships only in VIZOR_NYCTIS_ENABLED builds.
      nyctisFeatureEnabledProvider.overrideWithValue(nyctisEnabled),
      appBootstrapProvider.overrideWithValue(
        _bootstrap(acceptance: acceptance),
      ),
      syncProvider.overrideWith(
        () => FakeSyncNotifier(
          SyncState(accountUuid: 'account-1', hasAccountScopedData: true),
        ),
      ),
      ...nyctisOverrides,
    ],
    child: MaterialApp(
      home: AppTheme(
        data: AppThemeData.dark,
        child: MobileActivityScreen(
          historyLoader: (_) async => [_receivedZec()],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a build without VIZOR_NYCTIS_ENABLED shows no Nyctis rows', (
    tester,
  ) async {
    var viewBuilt = false;
    await tester.pumpWidget(
      _app([
        nyctisAssetsViewProvider.overrideWith((ref) async {
          viewBuilt = true;
          return _viewWithOneReceipt();
        }),
      ], nyctisEnabled: false),
    );
    await tester.pumpAndSettle();

    // Only the ZEC receipt: the feed is exactly what it is without Nyctis.
    expect(find.text('Received'), findsOneWidget);
    expect(find.text('+1 DMT'), findsNothing);
    expect(viewBuilt, isFalse);
  });

  testWidgets('the mobile feed shows a Nyctis receipt beside ZEC', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app([
        nyctisAssetsViewProvider.overrideWith(
          (ref) async => _viewWithOneReceipt(),
        ),
        nyctisBlockTimeLoaderProvider.overrideWithValue(
          (heights) async => {
            for (final height in heights)
              height: DateTime.now().subtract(const Duration(hours: 2)),
          },
        ),
      ]),
    );
    await tester.pumpAndSettle();

    // One "Received" for the ZEC transaction and one for the Nyctis
    // message: they are the same verb because they are the same event.
    expect(find.text('Received'), findsNWidgets(2));
    expect(find.text('+1 DMT'), findsOneWidget);
    expect(find.text('Devnet Mint · block 7,164'), findsOneWidget);
    // Both rows land in the same dated section rather than a Nyctis one.
    expect(find.text('This week'), findsOneWidget);
  });

  testWidgets(
    'an undated message falls to "Earlier" instead of inventing a time',
    (tester) async {
      await tester.pumpWidget(
        _app([
          nyctisAssetsViewProvider.overrideWith(
            (ref) async => _viewWithOneReceipt(),
          ),
          // The indexer could not date block 7 164.
          nyctisBlockTimeLoaderProvider.overrideWithValue(
            (heights) async => const {},
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('This week'), findsOneWidget);
      expect(find.text('Earlier'), findsOneWidget);
      // The height is on the row, which is what makes the order legible when
      // the wallet could not date the block at all.
      expect(find.text('Devnet Mint · block 7,164'), findsOneWidget);
    },
  );

  testWidgets('a Nyctis load that never answers leaves the feed alone', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app([
        nyctisAssetsViewProvider.overrideWith(
          (ref) => Completer<NyctisViewData>().future,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Received'), findsOneWidget);
    expect(find.textContaining('Devnet Mint'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a send shows what left, and its change is not a row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app([
        nyctisAssetsViewProvider.overrideWith(
          (ref) async => _sendAndReceiptView(),
        ),
        nyctisBlockTimeLoaderProvider.overrideWithValue(
          (heights) async => const {},
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('-12 NC'), findsOneWidget);
    expect(find.text('Nightcash · block 7,257'), findsOneWidget);
    // Mobile compacts a four-figure amount; the sign and the ticker survive.
    expect(find.text('+1K NC'), findsOneWidget);
    // The 988 of change is inside the send, not an arrival of its own.
    expect(find.textContaining('988'), findsNothing);
  });

  testWidgets('the ten-block window is on screen while it lasts', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app([
        nyctisAssetsViewProvider.overrideWith(
          (ref) async => _sendAndReceiptView(pendingMessageCount: 2),
        ),
        nyctisBlockTimeLoaderProvider.overrideWithValue(
          (heights) async => const {},
        ),
      ]),
    );
    // Pumped rather than settled: the row is in progress and its loader
    // animates forever, which is the point of it.
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Dated now, so it sorts above the settled rows rather than into the
    // fifteen-year-old blocks this devnet mines.
    expect(find.text('Nyctis is settling'), findsOneWidget);
    expect(
      find.text(
        'A payment from the last 10 blocks is not shown yet · 2 messages '
        'above block 7,258',
      ),
      findsOneWidget,
    );
    // Rendered where a settled row shows a time, because the time this row
    // could show is the moment the screen was built.
    expect(find.text('Not final yet'), findsOneWidget);
  });

  testWidgets('an unaccepted asset renders the icon, never a logo', (
    tester,
  ) async {
    // The document and the logo are both reachable. Nothing was accepted, so
    // `spec/asset-metadata-v0.md` section 5 forbids the picture — and the
    // wallet must not have asked for it either (section 3.1).
    final transport = _logoTransport();

    await tester.pumpWidget(
      _app([
        nyctisAssetsViewProvider.overrideWith(
          (ref) async =>
              _viewWithOneReceipt(metadataUri: _documentUri.toString()),
        ),
        nyctisBlockTimeLoaderProvider.overrideWithValue(
          (heights) async => const {},
        ),
        nyctisMetadataFetcherProvider.overrideWithValue(
          NyctisAssetMetadataFetcher(transport: transport),
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Devnet Mint · block 7,164'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(transport.requested, isEmpty);
  });

  testWidgets('an accepted asset draws its logo and its asset id', (
    tester,
  ) async {
    final transport = _logoTransport();

    await tester.pumpWidget(
      _app(
        [
          nyctisAssetsViewProvider.overrideWith(
            (ref) async =>
                _viewWithOneReceipt(metadataUri: _documentUri.toString()),
          ),
          nyctisBlockTimeLoaderProvider.overrideWithValue(
            (heights) async => const {},
          ),
          nyctisMetadataFetcherProvider.overrideWithValue(
            NyctisAssetMetadataFetcher(transport: transport),
          ),
        ],
        acceptance: const NyctisAssetAcceptance([
          NyctisAcceptedAsset(
            assetId: _dmtAssetId,
            name: 'Devnet Mint',
            symbol: 'DMT',
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    // Section 5: the row's title is the verb and its supporting line names the
    // asset, so the id has to be there too — the picture is exactly what makes
    // a declared name persuasive.
    expect(
      find.textContaining(truncateNyctisAssetId(_dmtAssetId)),
      findsOneWidget,
    );
  });
}

final _documentUri = Uri.parse('https://example.invalid/dmt.json');
final _logoUri = Uri.parse('https://example.invalid/dmt.png');

FakeNyctisTransport _logoTransport() {
  return FakeNyctisTransport({
    _documentUri: NyctisHttpReply(
      statusCode: 200,
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'schema': 'nyctis-asset-metadata/1',
            'logo': {'uri': _logoUri.toString()},
          }),
        ),
      ),
    ),
    _logoUri: NyctisHttpReply(statusCode: 200, body: kOnePixelPng),
  });
}
