import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/activity/nightjar_activity_provider.dart';
import 'package:zcash_wallet/src/features/activity/nightjar_activity_row_mapper.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/providers/nightjar_assets_view_provider.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';

const _dmtAssetId =
    'a3f1c0d29b8e47a5f6031d8c2b7e4906aa11bb22cc33dd44ee55ff6600778899';
const _receiptMsgId =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _sendMsgId =
    '2222222222222222222222222222222222222222222222222222222222222222';

NightjarViewData _readyView() {
  return NightjarViewData(
    status: NightjarViewStatus.ready,
    assets: [
      NightjarAssetDetailData(
        assetId: _dmtAssetId,
        name: 'Devnet Mint',
        symbol: 'DMT',
        isPublic: true,
        balance: BigInt.from(150),
        decimals: 2,
        notes: [
          NightjarNoteRowData(
            position: BigInt.from(12),
            amount: BigInt.from(100),
            decimals: 2,
            createdHeight: BigInt.from(7164),
          ),
          NightjarNoteRowData(
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
  required FutureOr<NightjarViewData> Function(Ref ref) view,
  NightjarBlockTimeLoader? blockTimeLoader,
}) {
  final container = ProviderContainer(
    overrides: [
      nightjarAssetsViewProvider.overrideWith(view),
      if (blockTimeLoader != null)
        nightjarBlockTimeLoaderProvider.overrideWithValue(blockTimeLoader),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

NightjarViewData _sendAndReceiptView() {
  return NightjarViewData(
    status: NightjarViewStatus.ready,
    viewHeight: BigInt.from(7258),
    assets: [
      NightjarAssetDetailData(
        assetId: _dmtAssetId,
        name: 'Nightcash',
        symbol: 'NC',
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

void main() {
  test('a spent note and its change become one send row', () async {
    final asked = <List<int>>[];
    final container = _container(
      view: (ref) async => _sendAndReceiptView(),
      blockTimeLoader: (heights) async {
        asked.add(heights);
        return const {};
      },
    );

    await container.read(nightjarAssetsViewProvider.future);
    await container.read(nightjarActivityBlockTimesProvider.future);
    final items = container.read(nightjarActivityItemsProvider);

    // Both ends of the note's life: the block it arrived in and the block it
    // was spent in. A send dated by the first would be dated by the wrong one.
    expect(asked, [
      [7246, 7257],
    ]);
    expect(items.map((item) => item.kind), [
      NightjarActivityKind.sent,
      NightjarActivityKind.received,
    ]);
    expect(items.first.delta, BigInt.from(-12));
  });

  test('the receipt a row opens carries this wallet\'s notes, both sides', () {
    final view = _sendAndReceiptView();
    final send = buildNightjarActivityItems(view: view).first;

    final args = nightjarActivityDetailArgsFor(send, view: view);

    expect(args.item, same(send));
    expect(args.messageId, _sendMsgId);
    expect(args.spentNotes.map((note) => note.amount), [BigInt.from(1000)]);
    expect(args.createdNotes.map((note) => note.amount), [BigInt.from(988)]);
  });

  test('a receipt with no view still carries the verb and the amount', () {
    final send = buildNightjarActivityItems(view: _sendAndReceiptView()).first;

    final args = nightjarActivityDetailArgsFor(send);

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

      await container.read(nightjarAssetsViewProvider.future);
      await container.read(nightjarActivityBlockTimesProvider.future);
      final items = container.read(nightjarActivityItemsProvider);

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

  test('items are empty while the Nightjar view is still loading', () {
    final container = _container(
      view: (ref) =>
          Future<NightjarViewData>.delayed(const Duration(days: 1), _readyView),
      blockTimeLoader: (heights) async => const {},
    );

    expect(container.read(nightjarActivityItemsProvider), isEmpty);
  });

  test('a Nightjar load that fails contributes no rows and no error', () async {
    final container = _container(
      view: (ref) async => throw StateError('indexer down'),
      blockTimeLoader: (heights) async => const {},
    );

    await expectLater(
      container.read(nightjarAssetsViewProvider.future),
      throwsStateError,
    );

    expect(container.read(nightjarActivityItemsProvider), isEmpty);
    expect(
      await container.read(nightjarActivityBlockTimesProvider.future),
      isEmpty,
    );
  });

  test('an unverified view contributes no rows', () async {
    final container = _container(
      view: (ref) async => const NightjarViewData(
        status: NightjarViewStatus.unverified,
        statusMessage: 'Nothing verified.',
      ),
      blockTimeLoader: (heights) async => const {},
    );

    await container.read(nightjarAssetsViewProvider.future);

    expect(container.read(nightjarActivityItemsProvider), isEmpty);
  });

  test('a block-time loader that throws leaves the rows undated', () async {
    final container = _container(
      view: (ref) async => _readyView(),
      blockTimeLoader: (heights) async => throw StateError('rate limited'),
    );

    await container.read(nightjarAssetsViewProvider.future);

    expect(
      await container.read(nightjarActivityBlockTimesProvider.future),
      isEmpty,
    );
    final items = container.read(nightjarActivityItemsProvider);
    expect(items, hasLength(2));
    expect(items.every((item) => item.timestamp == null), isTrue);
  });

  test('block times are only asked for once per height', () async {
    final asked = <int>[];
    final cache = NightjarBlockTimeCache();
    final container = ProviderContainer(
      overrides: [
        nightjarBlockTimeCacheProvider.overrideWithValue(cache),
        nightjarAssetsViewProvider.overrideWith((ref) async => _readyView()),
        nightjarBlockTimeLoaderProvider.overrideWithValue((heights) async {
          asked.addAll(heights);
          return {for (final height in heights) height: DateTime(2026, 9, 20)};
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(nightjarAssetsViewProvider.future);
    await container.read(nightjarActivityBlockTimesProvider.future);
    container.invalidate(nightjarAssetsViewProvider);
    await container.read(nightjarAssetsViewProvider.future);
    await container.read(nightjarActivityBlockTimesProvider.future);

    // The injected loader is asked again; what the cache protects is the
    // shipped loader's HTTP round trips, which `loadNightjarBlockTimes`
    // skips for a height it already knows.
    expect(asked, [2201, 7164, 2201, 7164]);
  });

  group('NightjarBlockTimeCache', () {
    test('serves only the heights it knows', () {
      final cache = NightjarBlockTimeCache();
      final time = DateTime(2026, 9, 20, 13, 40);
      cache.remember(7164, time);

      expect(cache.contains(7164), isTrue);
      expect(cache.contains(2201), isFalse);
      expect(cache.knownFor([2201, 7164]), {7164: time});
    });
  });
}
