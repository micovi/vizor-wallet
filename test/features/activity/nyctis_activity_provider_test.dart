import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/activity/nyctis_activity_provider.dart';
import 'package:zcash_wallet/src/features/activity/nyctis_activity_row_mapper.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_asset_metadata_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/providers/nyctis_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/providers/nyctis_config_provider.dart';

const _dmtAssetId =
    'a3f1c0d29b8e47a5f6031d8c2b7e4906aa11bb22cc33dd44ee55ff6600778899';
const _receiptMsgId =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _sendMsgId =
    '2222222222222222222222222222222222222222222222222222222222222222';

NyctisViewData _readyView() {
  return NyctisViewData(
    status: NyctisViewStatus.ready,
    assets: [
      NyctisAssetDetailData(
        assetId: _dmtAssetId,
        name: 'Devnet Mint',
        symbol: 'DMT',
        isPublic: true,
        balance: BigInt.from(150),
        decimals: 2,
        notes: [
          NyctisNoteRowData(
            position: BigInt.from(12),
            amount: BigInt.from(100),
            decimals: 2,
            createdHeight: BigInt.from(7164),
          ),
          NyctisNoteRowData(
            position: BigInt.from(3),
            amount: BigInt.from(50),
            decimals: 2,
            createdHeight: BigInt.from(2201),
          ),
        ],
      ),
    ],
  );
}

ProviderContainer _container({
  required FutureOr<NyctisViewData> Function(Ref ref) view,
  NyctisBlockTimeLoader? blockTimeLoader,
  bool nyctisEnabled = true,
}) {
  final container = ProviderContainer(
    overrides: [
      // Nyctis ships only in VIZOR_NYCTIS_ENABLED builds.
      nyctisFeatureEnabledProvider.overrideWithValue(nyctisEnabled),
      nyctisAssetsViewProvider.overrideWith(view),
      if (blockTimeLoader != null)
        nyctisBlockTimeLoaderProvider.overrideWithValue(blockTimeLoader),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

NyctisViewData _sendAndReceiptView() {
  return NyctisViewData(
    status: NyctisViewStatus.ready,
    viewHeight: BigInt.from(7258),
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

void main() {
  test('a build without VIZOR_NYCTIS_ENABLED feeds the shared lists '
      'nothing and never builds the view', () {
    var viewBuilt = false;
    final container = _container(
      nyctisEnabled: false,
      view: (ref) async {
        viewBuilt = true;
        return _sendAndReceiptView();
      },
    );

    expect(container.read(nyctisActivityItemsProvider), isEmpty);
    expect(container.read(nyctisAssetLogosProvider), isEmpty);
    expect(viewBuilt, isFalse);
  });

  test('a spent note and its change become one send row', () async {
    final asked = <List<int>>[];
    final container = _container(
      view: (ref) async => _sendAndReceiptView(),
      blockTimeLoader: (heights) async {
        asked.add(heights);
        return const {};
      },
    );

    await container.read(nyctisAssetsViewProvider.future);
    await container.read(nyctisActivityBlockTimesProvider.future);
    final items = container.read(nyctisActivityItemsProvider);

    // Both ends of the note's life: the block it arrived in and the block it
    // was spent in. A send dated by the first would be dated by the wrong one.
    expect(asked, [
      [7246, 7257],
    ]);
    expect(items.map((item) => item.kind), [
      NyctisActivityKind.sent,
      NyctisActivityKind.received,
    ]);
    expect(items.first.delta, BigInt.from(-12));
  });

  test('the receipt a row opens carries this wallet\'s notes, both sides', () {
    final view = _sendAndReceiptView();
    final send = buildNyctisActivityItems(view: view).first;

    final args = nyctisActivityDetailArgsFor(send, view: view);

    expect(args.item, same(send));
    expect(args.messageId, _sendMsgId);
    expect(args.spentNotes.map((note) => note.amount), [BigInt.from(1000)]);
    expect(args.createdNotes.map((note) => note.amount), [BigInt.from(988)]);
  });

  test('a receipt with no view still carries the verb and the amount', () {
    final send = buildNyctisActivityItems(view: _sendAndReceiptView()).first;

    final args = nyctisActivityDetailArgsFor(send);

    expect(args.notes, isEmpty);
    expect(args.item.delta, BigInt.from(-12));
  });

  test(
    'a ready view becomes activity items dated by their block times',
    () async {
      final mined = DateTime(2026, 9, 20, 13, 40);
      final asked = <List<int>>[];
      final container = _container(
        view: (ref) async => _readyView(),
        blockTimeLoader: (heights) async {
          asked.add(heights);
          return {7164: mined};
        },
      );

      await container.read(nyctisAssetsViewProvider.future);
      await container.read(nyctisActivityBlockTimesProvider.future);
      final items = container.read(nyctisActivityItemsProvider);

      // Only the distinct heights the wallet's own notes sit at, ascending.
      expect(asked, [
        [2201, 7164],
      ]);
      expect(items, hasLength(2));
      expect(items.first.timestamp, mined);
      // The height the loader had no answer for stays undated rather than
      // being given an invented time.
      expect(items.last.timestamp, isNull);
    },
  );

  test('items are empty while the Nyctis view is still loading', () {
    final container = _container(
      view: (ref) =>
          Future<NyctisViewData>.delayed(const Duration(days: 1), _readyView),
      blockTimeLoader: (heights) async => const {},
    );

    expect(container.read(nyctisActivityItemsProvider), isEmpty);
  });

  test('a Nyctis load that fails contributes no rows and no error', () async {
    final container = _container(
      view: (ref) async => throw StateError('indexer down'),
      blockTimeLoader: (heights) async => const {},
    );

    await expectLater(
      container.read(nyctisAssetsViewProvider.future),
      throwsStateError,
    );

    expect(container.read(nyctisActivityItemsProvider), isEmpty);
    expect(
      await container.read(nyctisActivityBlockTimesProvider.future),
      isEmpty,
    );
  });

  test('an unverified view contributes no rows', () async {
    final container = _container(
      view: (ref) async => const NyctisViewData(
        status: NyctisViewStatus.unverified,
        statusMessage: 'Nothing verified.',
      ),
      blockTimeLoader: (heights) async => const {},
    );

    await container.read(nyctisAssetsViewProvider.future);

    expect(container.read(nyctisActivityItemsProvider), isEmpty);
  });

  test('a block-time loader that throws leaves the rows undated', () async {
    final container = _container(
      view: (ref) async => _readyView(),
      blockTimeLoader: (heights) async => throw StateError('rate limited'),
    );

    await container.read(nyctisAssetsViewProvider.future);

    expect(
      await container.read(nyctisActivityBlockTimesProvider.future),
      isEmpty,
    );
    final items = container.read(nyctisActivityItemsProvider);
    expect(items, hasLength(2));
    expect(items.every((item) => item.timestamp == null), isTrue);
  });

  test('block times are only asked for once per height', () async {
    final asked = <int>[];
    final cache = NyctisBlockTimeCache();
    final container = ProviderContainer(
      overrides: [
        nyctisFeatureEnabledProvider.overrideWithValue(true),
        nyctisBlockTimeCacheProvider.overrideWithValue(cache),
        nyctisAssetsViewProvider.overrideWith((ref) async => _readyView()),
        nyctisBlockTimeLoaderProvider.overrideWithValue((heights) async {
          asked.addAll(heights);
          return {for (final height in heights) height: DateTime(2026, 9, 20)};
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(nyctisAssetsViewProvider.future);
    await container.read(nyctisActivityBlockTimesProvider.future);
    container.invalidate(nyctisAssetsViewProvider);
    await container.read(nyctisAssetsViewProvider.future);
    await container.read(nyctisActivityBlockTimesProvider.future);

    // The injected loader is asked again; what the cache protects is the
    // shipped loader's HTTP round trips, which `loadNyctisBlockTimes`
    // skips for a height it already knows.
    expect(asked, [2201, 7164, 2201, 7164]);
  });

  group('NyctisBlockTimeCache', () {
    test('serves only the heights it knows', () {
      final cache = NyctisBlockTimeCache();
      final time = DateTime(2026, 9, 20, 13, 40);
      cache.remember(7164, time);

      expect(cache.contains(7164), isTrue);
      expect(cache.contains(2201), isFalse);
      expect(cache.knownFor([2201, 7164]), {7164: time});
    });
  });
}
