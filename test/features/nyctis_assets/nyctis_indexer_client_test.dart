import 'dart:convert';
import 'dart:io';

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/network/network_http_client.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_message.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_indexer_client.dart';

import 'support/nyctis_fixtures.dart';
import 'support/nyctis_hostile_server.dart';

void main() {
  final baseUri = Uri.parse('http://127.0.0.1:8787');

  /// Every backoff the client asked for, in order. Injected everywhere so no
  /// test in this file spends real time asleep.
  late List<Duration> waits;

  setUp(() => waits = <Duration>[]);

  NyctisIndexerClient clientFor(
    FakeNyctisTorBridge bridge, {
    Uri? base,
    int maxAttempts = kNyctisIndexerMaxAttempts,
  }) {
    final networkClient = nyctisTestNetworkClient(bridge);
    addTearDown(() => networkClient.close(force: true));
    return NyctisIndexerClient(
      baseUri: base ?? baseUri,
      networkClient: networkClient,
      maxAttempts: maxAttempts,
      sleep: (duration) async => waits.add(duration),
    );
  }

  group('fetchStatus', () {
    test('decodes the live status and goes through the route policy', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(nyctisFixtureText('status')),
      ]);
      final client = clientFor(bridge);

      final status = await client.fetchStatus();

      expect(status.info.network, 'regtest');
      expect(status.isStale, isFalse);
      expect(
        bridge.requests.single,
        Uri.parse('http://127.0.0.1:8787/api/status'),
      );
      expect(bridge.timeouts.single, isNotNull);
    });

    test('honours a base URI with a path prefix', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(nyctisFixtureText('status')),
      ]);
      final client = clientFor(
        bridge,
        base: Uri.parse('https://indexer.example/nyctis'),
      );

      await client.fetchStatus();

      expect(
        bridge.requests.single,
        Uri.parse('https://indexer.example/nyctis/api/status'),
      );
    });
  });

  test('fetchVerifyingKey decodes the key bytes', () async {
    final bridge = FakeNyctisTorBridge([
      nyctisJsonResponse(nyctisFixtureText('vk')),
    ]);
    final client = clientFor(bridge);

    final vk = await client.fetchVerifyingKey();

    expect(vk.lengthInBytes, 1784);
    expect(bridge.requests.single.path, '/api/vk');
  });

  group('fetchMessages', () {
    test('asks for bodies and clamps limit to the server maximum', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(nyctisFixtureText('messages_page1')),
      ]);
      final client = clientFor(bridge);

      final page = await client.fetchMessages(limit: 5000);

      expect(page.count, 2);
      expect(page.nextCursor, 29643864342529);
      final query = bridge.requests.single.queryParameters;
      expect(query['body'], '1');
      expect(query['limit'], '$kNyctisIndexerMaxLimit');
      expect(query.containsKey('before'), isFalse);
    });

    test('passes the cursor as before=', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(nyctisFixtureText('messages_page2')),
      ]);
      final client = clientFor(bridge);

      await client.fetchMessages(limit: 2, before: 29643864342529);

      expect(
        bridge.requests.single.queryParameters['before'],
        '29643864342529',
      );
    });

    test('omits body=1 when the caller does not want bodies', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(nyctisFixtureText('messages_page1')),
      ]);
      final client = clientFor(bridge);

      await client.fetchMessages(includeBody: false, outcome: 'applied');

      final query = bridge.requests.single.queryParameters;
      expect(query.containsKey('body'), isFalse);
      expect(query['outcome'], 'applied');
    });
  });

  group('fetchAllMessages', () {
    test('pages backwards to completion and returns chain order', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          nyctisMessagesFixtureWithCursor(
            'messages_page1',
            cursor: 29643864342529,
            total: 4,
          ),
        ),
        nyctisJsonResponse(
          nyctisMessagesFixtureWithCursor(
            'messages_page2',
            cursor: null,
            total: 4,
          ),
        ),
      ]);
      final client = clientFor(bridge);

      final messages = await client.fetchAllMessages(pageLimit: 2);

      expect(bridge.requests, hasLength(2));
      expect(
        bridge.requests.first.queryParameters.containsKey('before'),
        isFalse,
      );
      expect(bridge.requests.last.queryParameters['before'], '29643864342529');

      // The API served newest-first across both pages; the replay gets the
      // reverse.
      expect(
        messages.map((m) => m.ord),
        orderedEquals(const [
          29549375062018,
          29596619702274,
          29643864342529,
          29691108982786,
        ]),
      );
      expect(messages.every((m) => m.hasBody), isTrue);
    });

    test(
      'stops at one page when the first page is the whole channel',
      () async {
        final bridge = FakeNyctisTorBridge([
          nyctisJsonResponse(
            nyctisMessagesFixtureWithCursor(
              'messages_page1',
              cursor: null,
              total: 2,
            ),
          ),
        ]);
        final client = clientFor(bridge);

        final messages = await client.fetchAllMessages();

        expect(bridge.requests, hasLength(1));
        expect(messages, hasLength(2));
      },
    );

    test('refuses a cursor that does not advance', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          nyctisMessagesFixtureWithCursor(
            'messages_page1',
            cursor: 29643864342529,
          ),
        ),
        nyctisJsonResponse(
          nyctisMessagesFixtureWithCursor(
            'messages_page1',
            cursor: 29643864342529,
          ),
        ),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchAllMessages(pageLimit: 2),
        throwsA(
          isA<NyctisIndexerException>().having(
            (e) => e.detail,
            'detail',
            'the message cursor did not advance',
          ),
        ),
      );
      expect(bridge.requests, hasLength(2));
    });

    test('refuses a walk that ends short of the advertised total', () async {
      // The captured page says 350 messages match and serves two of them with
      // `has_more: false`. Returning those two is not a short answer to the
      // question; it is a wrong answer to it, and every balance folded out of
      // them is wrong with no error attached.
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          nyctisMessagesFixtureWithCursor('messages_page1', cursor: null),
        ),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchAllMessages(),
        throwsA(
          isA<NyctisIndexerException>()
              .having(
                (e) => e.message,
                'message',
                'The Nyctis indexer served only part of this channel, so '
                    'this wallet cannot replay it.',
              )
              .having(
                (e) => e.detail,
                'detail',
                'the listing reported 350 messages and served 2',
              ),
        ),
      );
    });

    test('a page that repeats rows is not applied twice', () async {
      // The second page advances the cursor but serves the first page's rows
      // again, which the cursor guard alone cannot see. A fold that applies
      // one message twice does not fail; it just answers differently.
      final page1 = nyctisFixture('messages_page1');
      final repeated = jsonEncode({
        ...nyctisFixture('messages_page2'),
        'items': page1['items'],
        'total': 2,
        'has_more': false,
        'next_cursor': null,
      });
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          nyctisMessagesFixtureWithCursor(
            'messages_page1',
            cursor: 29643864342529,
            total: 2,
          ),
        ),
        nyctisJsonResponse(repeated),
      ]);
      final client = clientFor(bridge);

      final messages = await client.fetchAllMessages(pageLimit: 2);

      expect(messages, hasLength(2));
      expect(
        messages.map((m) => m.msgId).toSet(),
        hasLength(2),
        reason: 'each message is handed to the replay exactly once',
      );
      expect(messages.first.ord, lessThan(messages.last.ord));
    });

    test('a row served without its body stops the walk', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          nyctisMessagesFixtureWithout(
            'messages_page1',
            'body',
            cursor: null,
            total: 2,
          ),
        ),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchAllMessages(),
        throwsA(
          isA<NyctisIndexerException>()
              .having((e) => e.message, 'message', contains('without its body'))
              .having((e) => e.detail, 'detail', contains('has no body')),
        ),
      );
    });

    test('a bodyless walk the caller asked for is not policed', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          nyctisMessagesFixtureWithout(
            'messages_page1',
            'body',
            cursor: null,
            total: 2,
          ),
        ),
      ]);
      final client = clientFor(bridge);

      final messages = await client.fetchAllMessages(includeBody: false);

      expect(messages, hasLength(2));
      expect(
        messages.where((m) => !m.hasBody),
        hasLength(1),
        reason: 'a caller that did not ask for bodies is not owed one',
      );
    });

    test('refuses to walk past the message ceiling', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          nyctisMessagesFixtureWithCursor(
            'messages_page1',
            cursor: 29643864342529,
          ),
        ),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchAllMessages(pageLimit: 2, maxMessages: 2),
        throwsA(
          isA<NyctisIndexerException>().having(
            (e) => e.message,
            'message',
            'This channel has more messages than this wallet can load at once.',
          ),
        ),
      );
    });
  });

  group('error mapping', () {
    test('maps a 400 with the indexer error text', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          '{"error":"kind zzz is not a message kind (0..255)"}',
          statusCode: 400,
        ),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchMessages(),
        throwsA(
          isA<NyctisIndexerException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having(
                (e) => e.message,
                'message',
                'The Nyctis indexer rejected this request.',
              )
              .having(
                (e) => e.detail,
                'detail',
                'kind zzz is not a message kind (0..255)',
              )
              .having((e) => e.isTransient, 'isTransient', isFalse),
        ),
      );
    });

    test('maps a 404 that carries no body at all', () async {
      // The indexer's router answers an unknown path with an empty 404, so the
      // `{"error": ...}` envelope cannot be assumed.
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse('', statusCode: 404),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<NyctisIndexerException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having(
                (e) => e.message,
                'message',
                'The Nyctis indexer does not have what this wallet asked '
                    'for.',
              )
              .having((e) => e.detail, 'detail', isNull),
        ),
      );
    });

    test('maps a 429 and keeps Retry-After', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          '{"error":"rate limited"}',
          statusCode: 429,
          headers: const {
            'retry-after': ['7'],
          },
        ),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<NyctisIndexerException>()
              .having((e) => e.isRateLimited, 'isRateLimited', isTrue)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 7),
              )
              .having((e) => e.isTransient, 'isTransient', isTrue),
        ),
      );
    });

    test('maps a 503 from a busy index', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          '{"error":"index busy: no free reader"}',
          statusCode: 503,
        ),
      ]);
      final client = clientFor(bridge, maxAttempts: 1);

      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<NyctisIndexerException>()
              .having((e) => e.isUnavailable, 'isUnavailable', isTrue)
              .having(
                (e) => e.message,
                'message',
                'The Nyctis indexer is busy. Try again in a moment.',
              ),
        ),
      );
    });

    test('maps a body that is not JSON', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse('<html>not json</html>'),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<NyctisIndexerException>().having(
            (e) => e.message,
            'message',
            'The indexer sent a response this wallet could not read.',
          ),
        ),
      );
    });

    test(
      'maps a response that decodes but does not match the contract',
      () async {
        final bridge = FakeNyctisTorBridge([
          nyctisJsonResponse('{"info":{},"live":{},"counts":{}}'),
        ]);
        final client = clientFor(bridge);

        await expectLater(
          client.fetchStatus(),
          throwsA(
            isA<NyctisIndexerException>().having(
              (e) => e.message,
              'message',
              'The indexer response is missing "network".',
            ),
          ),
        );
      },
    );

    test('never leaks a transport exception', () async {
      final bridge = FakeNyctisTorBridge([
        const SocketException('Connection refused'),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<NyctisIndexerException>()
              .having(
                (e) => e.message,
                'message',
                'Could not reach the Nyctis indexer.',
              )
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.isTransient, 'isTransient', isTrue)
              .having((e) => e.cause, 'cause', isA<SocketException>()),
        ),
      );
    });
  });

  test(
    'a caller-supplied network client is not closed by the client',
    () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(nyctisFixtureText('status')),
        nyctisJsonResponse(nyctisFixtureText('status')),
      ]);
      final networkClient = nyctisTestNetworkClient(bridge);
      addTearDown(() => networkClient.close(force: true));

      final first = NyctisIndexerClient(
        baseUri: baseUri,
        networkClient: networkClient,
      );
      await first.fetchStatus();
      first.close();

      final second = NyctisIndexerClient(
        baseUri: baseUri,
        networkClient: networkClient,
      );
      expect(await second.fetchStatus(), isNotNull);
    },
  );

  test(
    'message outcomes decoded through the client keep chain order',
    () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          nyctisMessagesFixtureWithCursor(
            'messages_page1',
            cursor: null,
            total: 2,
          ),
        ),
      ]);
      final client = clientFor(bridge);

      final messages = await client.fetchAllMessages();

      expect(
        messages.map((m) => m.outcome),
        everyElement(isA<NyctisMessageOutcome>()),
      );
      expect(messages.first.ord, lessThan(messages.last.ord));
    },
  );

  group('retrying', () {
    test('a busy index is retried, then surfaced', () async {
      final bridge = FakeNyctisTorBridge([
        for (var i = 0; i < 3; i++)
          nyctisJsonResponse('{"error":"index busy"}', statusCode: 503),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchStatus(),
        throwsA(isA<NyctisIndexerException>()),
      );
      expect(bridge.requests, hasLength(kNyctisIndexerMaxAttempts));
      expect(waits, [
        kNyctisIndexerRetryBackoff,
        kNyctisIndexerRetryBackoff * 2,
      ], reason: 'the backoff doubles rather than hammering the index');
    });

    test('a rate limit waits out a short Retry-After and succeeds', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          '{"error":"slow down"}',
          statusCode: 429,
          headers: const {
            'retry-after': ['2'],
          },
        ),
        nyctisJsonResponse(nyctisFixtureText('status')),
      ]);
      final client = clientFor(bridge);

      final status = await client.fetchStatus();

      expect(status.info.network, 'regtest');
      expect(waits, [const Duration(seconds: 2)]);
    });

    test('a long Retry-After is surfaced rather than slept through', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          '{"error":"slow down"}',
          statusCode: 429,
          headers: const {
            'retry-after': ['600'],
          },
        ),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<NyctisIndexerException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(minutes: 10),
          ),
        ),
      );
      expect(bridge.requests, hasLength(1));
      expect(
        waits,
        isEmpty,
        reason: 'ten minutes behind a spinner is not a retry, it is a hang',
      );
    });

    test('a request that never got an answer is not retried', () async {
      final bridge = FakeNyctisTorBridge([
        const SocketException('connection refused'),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<NyctisIndexerException>()
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.isTransient, 'isTransient', isTrue),
        ),
      );
      expect(
        bridge.requests,
        hasLength(1),
        reason:
            'three timeouts in a row is one refresh the user waits a minute '
            'for',
      );
    });
  });

  group('response size (C20)', () {
    test('a Tor response over the cap is refused and not retried', () async {
      final bridge = FakeNyctisTorBridge([
        NetworkHttpResponse(
          statusCode: 200,
          bodyBytes: Uint8List(kNyctisIndexerMaxResponseBytes + 1),
        ),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<NyctisIndexerException>()
              .having(
                (e) => e.message,
                'message',
                'The Nyctis indexer sent a response too large to read.',
              )
              .having((e) => e.statusCode, 'statusCode', isNull),
        ),
      );
      expect(bridge.requests, hasLength(1));
      expect(waits, isEmpty);
    });

    test('a compressed Tor response is refused', () async {
      final bridge = FakeNyctisTorBridge([
        nyctisJsonResponse(
          nyctisFixtureText('status'),
          headers: const {
            'content-encoding': ['gzip'],
          },
        ),
      ]);
      final client = clientFor(bridge);

      await expectLater(
        client.fetchStatus(),
        throwsA(isA<NyctisIndexerException>()),
      );
    });

    group('against a hostile indexer on the direct route', () {
      late NyctisHostileServer server;

      NyctisIndexerClient directClient() {
        // The default `HttpClient`, `autoUncompress` on, exactly as the
        // indexer client builds one when nothing is injected.
        final networkClient = NetworkHttpClient(
          torDesired: () => false,
          directClient: HttpClient(),
        );
        addTearDown(() => networkClient.close(force: true));
        return NyctisIndexerClient(
          baseUri: server.http(''),
          networkClient: networkClient,
          maxAttempts: 1,
          sleep: (duration) async => waits.add(duration),
        );
      }

      tearDown(() => server.close());

      test('an endless body is cut off while it streams', () async {
        server = await NyctisHostileServer.start(
          NyctisHostileBehaviour.endless,
        );

        await expectLater(
          directClient().fetchStatus(),
          throwsA(
            isA<NyctisIndexerException>().having(
              (e) => e.cause,
              'cause',
              isA<NetworkHttpResponseTooLargeException>().having(
                (e) => e.receivedBytes,
                'receivedBytes',
                lessThan(kNyctisIndexerMaxResponseBytes + 8 * 1024 * 1024),
              ),
            ),
          ),
        );
        await server.clientHungUp.future.timeout(const Duration(seconds: 10));
        expect(
          server.bytesWritten,
          lessThan(kNyctisIndexerMaxResponseBytes * 2),
        );
      });

      test('a gzip bomb is refused before it inflates', () async {
        server = await NyctisHostileServer.start(
          NyctisHostileBehaviour.gzipBomb,
        );

        await expectLater(
          directClient().fetchStatus(),
          throwsA(
            isA<NyctisIndexerException>().having(
              (e) => e.cause,
              'cause',
              isA<NetworkHttpCompressedResponseException>(),
            ),
          ),
        );
        expect(server.requests.single['accept-encoding'], 'identity');
      });
    });
  });

  group('network route', () {
    test('while Tor is on, a broken Tor route fails closed', () async {
      // The would-be clearnet destination. If anything fell back to the
      // direct route it would show up here.
      final server = await NyctisHostileServer.start(
        NyctisHostileBehaviour.ok,
      );
      addTearDown(server.close);
      final direct = NyctisPlainHttpClient();
      final networkClient = NetworkHttpClient(
        torDesired: () => true,
        torBootstrapping: () => false,
        directClient: direct,
        torBridge: FakeNyctisTorBridge([StateError('Tor is not enabled')]),
      );
      addTearDown(() => networkClient.close(force: true));
      final client = NyctisIndexerClient(
        baseUri: server.http(''),
        networkClient: networkClient,
        sleep: (duration) async => waits.add(duration),
      );

      await expectLater(
        client.fetchStatus(),
        throwsA(
          isA<NyctisIndexerException>().having(
            (e) => e.message,
            'message',
            'Could not reach the Nyctis indexer.',
          ),
        ),
      );
      expect(direct.opened, 0);
      expect(server.requests, isEmpty);
    });

    test('no Nyctis service opens a raw HTTP client of its own', () {
      // The constructor guard. Every Dart request Nyctis makes must go
      // through `NetworkHttpClient`, the policy-aware opener; the only file
      // allowed to construct an `HttpClient` is the metadata transport, which
      // hands it straight to `NetworkHttpClient` as the direct route.
      final roots = [
        Directory('lib/src/features/nyctis_assets'),
        Directory('lib/src/features/activity'),
      ];
      final offenders = <String>[];
      for (final root in roots) {
        for (final entity in root.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final source = entity.readAsStringSync();
          final rawClient =
              source.contains('HttpClient()') ||
              source.contains("package:http/") ||
              source.contains('Socket.connect') ||
              source.contains('Image.network') ||
              source.contains('NetworkImage(');
          if (!rawClient) continue;
          if (entity.path.endsWith(
            'nyctis_assets/services/nyctis_metadata_transport.dart',
          )) {
            expect(source, contains('NetworkHttpClient('));
            expect(
              source,
              contains('directClient: NyctisSingleHopHttpClient'),
            );
            continue;
          }
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty);
    });
  });
}
