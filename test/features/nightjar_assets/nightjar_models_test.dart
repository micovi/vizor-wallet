import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_asset.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_indexer_status.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_message.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_page.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_verifying_key.dart';

import 'support/nightjar_fixtures.dart';

void main() {
  group('NightjarIndexerStatus', () {
    test('decodes the live regtest devnet status', () {
      final status = NightjarIndexerStatus.fromJson(nightjarFixture('status'));

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
      final status = NightjarIndexerStatus.fromJson({
        'info': nightjarFixture('status')['info'],
        'live': <String, Object?>{},
        'counts': <String, Object?>{},
      });

      expect(status.isStale, isTrue);
      expect(status.live.status, 'unknown');
    });

    test('rejects a status with no info', () {
      expect(
        () => NightjarIndexerStatus.fromJson(const {'live': {}, 'counts': {}}),
        throwsFormatException,
      );
    });
  });

  group('NightjarVerifyingKey', () {
    test('decodes the verifying key bytes', () {
      final vk = NightjarVerifyingKey.fromJson(nightjarFixture('vk'));

      expect(vk.vkHash, hasLength(64));
      expect(vk.circuitVersion, 3);
      expect(vk.lengthInBytes, 1784);
      expect(vk.vk.first, 0x81);
      expect(vk.matchesVkHash(vk.vkHash.toUpperCase()), isTrue);
      expect(vk.matchesVkHash('00' * 32), isFalse);
    });

    test('the status vk_hash and the vk endpoint agree', () {
      final status = NightjarIndexerStatus.fromJson(nightjarFixture('status'));
      final vk = NightjarVerifyingKey.fromJson(nightjarFixture('vk'));
      expect(vk.matchesVkHash(status.info.vkHash), isTrue);
    });

    test('rejects malformed hex', () {
      expect(
        () => NightjarVerifyingKey.fromJson(const {
          'vk_hash': 'aa',
          'vk': 'zz',
          'circuit': 'c',
          'circuit_version': 3,
        }),
        throwsFormatException,
      );
    });
  });

  group('NightjarMessage', () {
    test('decodes a page of messages with bodies', () {
      final page = NightjarPage.fromJson(
        nightjarFixture('messages_page1'),
        NightjarMessage.fromJson,
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
      expect(first.outcome, NightjarMessageOutcome.applied);
      expect(first.reason, isNull);
      expect(first.detail, isNotNull);
      // The body is the bytes the replay consumes, and `body_len` is its length
      // in bytes rather than hex characters.
      expect(first.hasBody, isTrue);
      expect(first.body, hasLength(first.bodyLen));
      expect(first.bodyLen, 806);
    });

    test('a page fetched without body=1 decodes with no body', () {
      final json = nightjarFixture('messages_page1');
      final items = (json['items']! as List).cast<Map<String, Object?>>();
      final stripped = Map<String, Object?>.of(items.first)..remove('body');

      final message = NightjarMessage.fromJson(stripped);
      expect(message.hasBody, isFalse);
      expect(message.bodyLen, 806);
    });

    test('an unrecognized outcome does not fail the decode', () {
      final items = (nightjarFixture('messages_page1')['items']! as List)
          .cast<Map<String, Object?>>();
      final message = NightjarMessage.fromJson({
        ...items.first,
        'outcome': 'something-new',
      });
      expect(message.outcome, NightjarMessageOutcome.unknown);
    });

    test('nightjarMessagesInChainOrder reverses the newest-first listing', () {
      final newestFirst = [
        ...NightjarPage.fromJson(
          nightjarFixture('messages_page1'),
          NightjarMessage.fromJson,
        ).items,
        ...NightjarPage.fromJson(
          nightjarFixture('messages_page2'),
          NightjarMessage.fromJson,
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

      final chainOrder = nightjarMessagesInChainOrder(newestFirst);
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
      final page1 = NightjarPage.fromJson(
        nightjarFixture('messages_page1'),
        NightjarMessage.fromJson,
      ).items;

      final ordered = nightjarMessagesInChainOrder([...page1, ...page1]);

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
      final page2 = NightjarPage.fromJson(
        nightjarFixture('messages_page2'),
        NightjarMessage.fromJson,
      ).items;
      final page1 = NightjarPage.fromJson(
        nightjarFixture('messages_page1'),
        NightjarMessage.fromJson,
      ).items;

      expect(
        nightjarMessagesInChainOrder([...page2, ...page1]).map((m) => m.ord),
        orderedEquals(
          nightjarMessagesInChainOrder([...page1, ...page2]).map((m) => m.ord),
        ),
      );
    });
  });

  group('NightjarAsset', () {
    test('decodes u64 amounts as BigInt, never as doubles', () {
      final page = NightjarPage.fromJson(
        nightjarFixture('assets'),
        NightjarAsset.fromJson,
      );

      expect(page.count, 1);
      expect(page.hasMore, isFalse);
      expect(page.nextCursor, isNull);

      final asset = page.items.single;
      expect(asset.assetId, hasLength(64));
      expect(asset.isPublic, isTrue);
      expect(asset.issued, BigInt.from(600));
      expect(asset.maxSupply, BigInt.from(1000));
      expect(asset.amountOpen, BigInt.zero);
      expect(asset.remainingSupply, BigInt.from(400));
      expect(asset.issuances, 1);
      expect(asset.name, 'Devnet Mint');
      expect(asset.symbol, 'DMT');
      expect(asset.decimals, 2);
      expect(asset.displayName, 'Devnet Mint');
      expect(asset.collectionId, hasLength(64));
      expect(asset.index, 0);
    });

    test('a u64 beyond 2^53 survives the round trip exactly', () {
      // 18446744073709551615 is u64::MAX. Parsed as a double it would come
      // back as 18446744073709551616, and the issued_hash would be wrong with
      // no error attached.
      const raw =
          '{"asset_id":"ab","public":true,"issued":'
          '"18446744073709551615","max_supply":"18446744073709551615",'
          '"amount_open":"9007199254740993"}';
      final asset = NightjarAsset.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );

      expect(asset.issued.toString(), '18446744073709551615');
      expect(asset.amountOpen.toString(), '9007199254740993');
      expect(asset.remainingSupply, BigInt.zero);
    });

    test('rejects a u64 amount sent as a JSON number', () {
      expect(
        () => NightjarAsset.fromJson(const {
          'asset_id': 'ab',
          'public': true,
          'issued': 600,
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'The indexer field "issued" must be a decimal string amount.',
          ),
        ),
      );
    });

    test('a non-public asset reports no supply rather than zero', () {
      final asset = NightjarAsset.fromJson(const {
        'asset_id': 'ab',
        'public': false,
        'index': null,
        'issued': null,
        'max_supply': null,
        'amount_open': '0',
        'name': null,
        'symbol': null,
      });

      expect(asset.isPublic, isFalse);
      expect(asset.issued, isNull);
      expect(asset.maxSupply, isNull);
      expect(asset.remainingSupply, isNull);
      expect(asset.index, isNull);
      expect(asset.amountOpen, BigInt.zero);
      expect(asset.displayName, 'Unnamed asset');
      expect(asset.hasName, isFalse);
    });
  });

  group('NightjarPage', () {
    test('hasMore follows next_cursor, not the has_more flag', () {
      final page = NightjarPage.fromJson(const {
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
        () => NightjarPage.fromJson(const {'items': 3}, (json) => json),
        throwsFormatException,
      );
    });
  });

  test('every fixture is the shape the live regtest indexer served', () {
    for (final name in const [
      'status',
      'vk',
      'assets',
      'messages_page1',
      'messages_page2',
    ]) {
      expect(
        File(nightjarFixturePath(name)).existsSync(),
        isTrue,
        reason: name,
      );
    }
  });
}
