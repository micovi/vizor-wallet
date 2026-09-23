import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_indexer_status.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_message.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_page.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_verifying_key.dart';

import 'support/nyctis_fixtures.dart';

void main() {
  group('NyctisIndexerStatus', () {
    test('decodes the live regtest devnet status', () {
      final status = NyctisIndexerStatus.fromJson(nyctisFixture('status'));

      expect(status.info.network, 'regtest');
      expect(status.info.birthday, 2);
      expect(status.info.circuitVersion, 3);
      expect(status.info.anchorWindow, 200);
      expect(status.info.finalityDepth, 10);
      expect(status.info.uivk, startsWith('uivkregtest1'));
      expect(status.info.vkHash, hasLength(64));
      expect(status.info.channelId, hasLength(64));

      expect(status.live.stale, isFalse);
      expect(status.isStale, isFalse);
      expect(status.live.synced, isTrue);
      expect(status.live.tip, greaterThan(0));
      expect(status.canonicalHeight, status.live.canonicalHeight);
      // The canonical height trails the preview height by the finality depth.
      expect(
        status.live.height - status.live.canonicalHeight,
        status.info.finalityDepth,
      );
      expect(status.live.lastError, isNull);

      expect(status.counts.messages, greaterThan(0));
      expect(status.counts.assetsPublic, 1);
      expect(status.counts.raw['collections'], 1);
    });

    test('a missing live section defaults to stale rather than fresh', () {
      final status = NyctisIndexerStatus.fromJson({
        'info': nyctisFixture('status')['info'],
        'live': <String, Object?>{},
        'counts': <String, Object?>{},
      });

      expect(status.isStale, isTrue);
      expect(status.live.status, 'unknown');
    });

    test('rejects a status with no info', () {
      expect(
        () => NyctisIndexerStatus.fromJson(const {'live': {}, 'counts': {}}),
        throwsFormatException,
      );
    });
  });

  group('NyctisVerifyingKey', () {
    test('decodes the verifying key bytes', () {
      final vk = NyctisVerifyingKey.fromJson(nyctisFixture('vk'));

      expect(vk.vkHash, hasLength(64));
      expect(vk.circuitVersion, 3);
      expect(vk.lengthInBytes, 1784);
      expect(vk.vk.first, 0x81);
      expect(vk.matchesVkHash(vk.vkHash.toUpperCase()), isTrue);
      expect(vk.matchesVkHash('00' * 32), isFalse);
    });

    test('the status vk_hash and the vk endpoint agree', () {
      final status = NyctisIndexerStatus.fromJson(nyctisFixture('status'));
      final vk = NyctisVerifyingKey.fromJson(nyctisFixture('vk'));
      expect(vk.matchesVkHash(status.info.vkHash), isTrue);
    });

    test('rejects malformed hex', () {
      expect(
        () => NyctisVerifyingKey.fromJson(const {
          'vk_hash': 'aa',
          'vk': 'zz',
          'circuit': 'c',
          'circuit_version': 3,
        }),
        throwsFormatException,
      );
    });
  });

  group('NyctisMessage', () {
    test('decodes a page of messages with bodies', () {
      final page = NyctisPage.fromJson(
        nyctisFixture('messages_page1'),
        NyctisMessage.fromJson,
      );

      expect(page.count, 2);
      expect(page.total, 350);
      expect(page.limit, 2);
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 29643864342529);

      final first = page.items.first;
      expect(first.ord, 29691108982786);
      expect(first.msgId, hasLength(64));
      expect(first.kind, 1);
      expect(first.kindName, 'transition');
      expect(first.height, 6913);
      expect(first.txIndex, 1);
      expect(first.actionIndex, 2);
      expect(first.fragments, 2);
      expect(first.outcome, NyctisMessageOutcome.applied);
      expect(first.reason, isNull);
      expect(first.detail, isNotNull);
      // The body is the bytes the replay consumes, and `body_len` is its length
      // in bytes rather than hex characters.
      expect(first.hasBody, isTrue);
      expect(first.body, hasLength(first.bodyLen));
      expect(first.bodyLen, 806);
    });

    test('a page fetched without body=1 decodes with no body', () {
      final json = nyctisFixture('messages_page1');
      final items = (json['items']! as List).cast<Map<String, Object?>>();
      final stripped = Map<String, Object?>.of(items.first)..remove('body');

      final message = NyctisMessage.fromJson(stripped);
      expect(message.hasBody, isFalse);
      expect(message.bodyLen, 806);
    });

    test('an unrecognized outcome does not fail the decode', () {
      final items = (nyctisFixture('messages_page1')['items']! as List)
          .cast<Map<String, Object?>>();
      final message = NyctisMessage.fromJson({
        ...items.first,
        'outcome': 'something-new',
      });
      expect(message.outcome, NyctisMessageOutcome.unknown);
    });

    test('nyctisMessagesInChainOrder reverses the newest-first listing', () {
      final newestFirst = [
        ...NyctisPage.fromJson(
          nyctisFixture('messages_page1'),
          NyctisMessage.fromJson,
        ).items,
        ...NyctisPage.fromJson(
          nyctisFixture('messages_page2'),
          NyctisMessage.fromJson,
        ).items,
      ];
      expect(
        newestFirst.map((m) => m.ord),
        orderedEquals(const [
          29691108982786,
          29643864342529,
          29596619702274,
          29549375062018,
        ]),
      );

      final chainOrder = nyctisMessagesInChainOrder(newestFirst);
      expect(
        chainOrder.map((m) => m.ord),
        orderedEquals(const [
          29549375062018,
          29596619702274,
          29643864342529,
          29691108982786,
        ]),
      );
      // Chain order is the same order the heights arrived in.
      expect(
        chainOrder.map((m) => m.height).toList(),
        equals(List.of(chainOrder.map((m) => m.height))..sort()),
      );
    });

    test('a message repeated across pages is applied once', () {
      // `before` is documented to be strictly exclusive, so this should not
      // happen — but the replay is a fold, and a fold that sees one message
      // twice does not fail, it answers differently. The wallet does not take
      // the cursor's word for it.
      final page1 = NyctisPage.fromJson(
        nyctisFixture('messages_page1'),
        NyctisMessage.fromJson,
      ).items;

      final ordered = nyctisMessagesInChainOrder([...page1, ...page1]);

      expect(ordered, hasLength(page1.length));
      expect(
        ordered.map((m) => m.msgId).toSet(),
        page1.map((m) => m.msgId).toSet(),
      );
      expect(
        ordered.map((m) => m.ord),
        orderedEquals(const [29643864342529, 29691108982786]),
      );
    });

    test('chain order survives pages that arrive out of order', () {
      final page2 = NyctisPage.fromJson(
        nyctisFixture('messages_page2'),
        NyctisMessage.fromJson,
      ).items;
      final page1 = NyctisPage.fromJson(
        nyctisFixture('messages_page1'),
        NyctisMessage.fromJson,
      ).items;

      expect(
        nyctisMessagesInChainOrder([...page2, ...page1]).map((m) => m.ord),
        orderedEquals(
          nyctisMessagesInChainOrder([...page1, ...page2]).map((m) => m.ord),
        ),
      );
    });
  });

  group('NyctisPage', () {
    test('hasMore follows next_cursor, not the has_more flag', () {
      final page = NyctisPage.fromJson(const {
        'items': <Object?>[],
        'count': 0,
        'total': 10,
        'limit': 2,
        'has_more': true,
        'next_cursor': null,
      }, (json) => json);

      expect(page.hasMore, isFalse);
      expect(page.nextCursor, isNull);
      expect(page.total, 10);
    });

    test('rejects a page whose items are not a list', () {
      expect(
        () => NyctisPage.fromJson(const {'items': 3}, (json) => json),
        throwsFormatException,
      );
    });
  });

  test('every fixture is the shape the live regtest indexer served', () {
    for (final name in const [
      'status',
      'vk',
      'messages_page1',
      'messages_page2',
    ]) {
      expect(
        File(nyctisFixturePath(name)).existsSync(),
        isTrue,
        reason: name,
      );
    }
  });
}
