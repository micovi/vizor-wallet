import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_block.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_indexer_client.dart';

import 'support/nightjar_fixtures.dart';

/// `/api/block/{height}` as the devnet indexer serves it, trimmed to the
/// fields a caller reads.
const _blockJson = '''
{
  "height": 7164,
  "hash": "b4abf073876bfc81a05bb8c57737bf85c518e1833d2949db5ae0beba2674fda7",
  "prev_hash": "f9a6f08fd02044a215890af026dbd73ad094210824561a9b3d86eba816654dbc",
  "time": 1789989100,
  "memos": 1,
  "messages": 1,
  "applied": 1,
  "ignored": 0,
  "published": 0,
  "named": 0,
  "canonical": true,
  "state_root": "03d0eda47325ef1c8eb9d8a7a8eae011e8e1e8315bc283fbd7f886de0c05d4a7",
  "preview_state_root": null,
  "memo_list": [],
  "message_list": []
}
''';

void main() {
  final baseUri = Uri.parse('http://127.0.0.1:8787');

  NightjarIndexerClient clientFor(FakeNightjarTorBridge bridge) {
    final networkClient = nightjarTestNetworkClient(bridge);
    addTearDown(() => networkClient.close(force: true));
    return NightjarIndexerClient(
      baseUri: baseUri,
      networkClient: networkClient,
      sleep: (_) async {},
    );
  }

  group('NightjarBlock', () {
    test('reads the block time as a local DateTime', () {
      final block = NightjarBlock.fromJson({
        'height': 7164,
        'hash': 'ab',
        'time': 1789989100,
        'canonical': true,
      });

      expect(block.height, 7164);
      expect(block.canonical, isTrue);
      expect(
        block.minedAt,
        DateTime.fromMillisecondsSinceEpoch(1789989100 * 1000),
      );
    });

    test('a block with no time has no mined-at rather than the epoch', () {
      final block = NightjarBlock.fromJson({'height': 7164, 'hash': 'ab'});

      expect(block.time, 0);
      expect(block.minedAt, isNull);
    });
  });

  group('fetchBlock', () {
    test('asks the indexer for one height and decodes its time', () async {
      final bridge = FakeNightjarTorBridge([nightjarJsonResponse(_blockJson)]);
      final client = clientFor(bridge);

      final block = await client.fetchBlock(7164);

      expect(
        bridge.requests.single,
        Uri.parse('http://127.0.0.1:8787/api/block/7164'),
      );
      expect(block.height, 7164);
      expect(
        block.minedAt,
        DateTime.fromMillisecondsSinceEpoch(1789989100 * 1000),
      );
    });

    test('a height the indexer does not have surfaces as a typed failure', () {
      final bridge = FakeNightjarTorBridge([
        nightjarJsonResponse(
          '{"error":"no such block"}',
          statusCode: HttpStatus.notFound,
        ),
      ]);
      final client = clientFor(bridge);

      expect(
        client.fetchBlock(999999),
        throwsA(
          isA<NightjarIndexerException>()
              .having((e) => e.statusCode, 'statusCode', HttpStatus.notFound)
              .having((e) => e.isTransient, 'isTransient', isFalse),
        ),
      );
    });
  });
}
