import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/network/network_http_client.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_reader.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_metadata_transport.dart';

import 'support/nyctis_hostile_server.dart';

/// A [TorHttpBridge] that answers 200 and records the hops it was asked for.
class _RecordingTorBridge implements TorHttpBridge {
  final List<Uri> requested = [];

  @override
  Future<NetworkHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) async {
    requested.add(uri);
    return NetworkHttpResponse(statusCode: 200, bodyBytes: Uint8List(0));
  }

  @override
  Future<NetworkHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required List<int> bodyBytes,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) async => throw UnimplementedError();

  @override
  Future<NetworkHttpResponse> download(
    Uri uri, {
    required Map<String, String> headers,
    required String destinationPath,
  }) async => throw UnimplementedError();
}

/// A [TorHttpBridge] that answers every GET with one scripted response, or
/// throws [error] — a Tor route that is starting or broken.
class _ScriptedTorBridge implements TorHttpBridge {
  _ScriptedTorBridge({this.response, this.error});

  final NetworkHttpResponse? response;
  final Object? error;
  final List<Uri> requested = [];
  final List<Map<String, String>> headers = [];

  @override
  Future<NetworkHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) async {
    requested.add(uri);
    this.headers.add(headers);
    final failure = error;
    if (failure != null) throw failure;
    return response!;
  }

  @override
  Future<NetworkHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required List<int> bodyBytes,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) async => throw UnimplementedError();

  @override
  Future<NetworkHttpResponse> download(
    Uri uri, {
    required Map<String, String> headers,
    required String destinationPath,
  }) async => throw UnimplementedError();
}

/// Only [followRedirects] matters here; everything else is left to
/// `noSuchMethod`, which is legal precisely because nothing calls it.
class _FakeRequest implements HttpClientRequest {
  @override
  bool followRedirects = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClient implements HttpClient {
  final List<Uri> opened = [];
  final List<_FakeRequest> requests = [];

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    opened.add(url);
    final request = _FakeRequest();
    requests.add(request);
    return request;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('NyctisTorOriginGuardBridge', () {
    test('lets a same-origin hop through', () async {
      final inner = _RecordingTorBridge();
      final guard = NyctisTorOriginGuardBridge(
        Uri.parse('https://example.invalid/ny/gold.json'),
        inner: inner,
      );

      await guard.get(
        Uri.parse('https://example.invalid/ny/moved.json'),
        headers: const {},
        timeout: null,
      );

      expect(inner.requested.single.path, '/ny/moved.json');
    });

    test('refuses a hop to a different host before it is made', () async {
      final inner = _RecordingTorBridge();
      final guard = NyctisTorOriginGuardBridge(
        Uri.parse('https://example.invalid/ny/gold.json'),
        inner: inner,
      );

      // Thrown synchronously, before a future exists: the guard refuses the
      // hop rather than starting it and failing.
      expect(
        () => guard.get(
          Uri.parse('https://elsewhere.invalid/ny/gold.json'),
          headers: const {},
          timeout: null,
        ),
        throwsA(isA<NyctisCrossOriginRedirectException>()),
      );
      expect(inner.requested, isEmpty);
    });

    test('refuses a hop to a different port on the same host', () async {
      final inner = _RecordingTorBridge();
      final guard = NyctisTorOriginGuardBridge(
        Uri.parse('https://example.invalid/a'),
        inner: inner,
      );

      expect(
        () => guard.get(
          Uri.parse('https://example.invalid:8443/a'),
          headers: const {},
          timeout: null,
        ),
        throwsA(isA<NyctisCrossOriginRedirectException>()),
      );
    });

    test(
      'spends the section 3.2 budget of one request plus three redirects',
      () async {
        final inner = _RecordingTorBridge();
        final uri = Uri.parse('https://example.invalid/a');
        final guard = NyctisTorOriginGuardBridge(uri, inner: inner);

        for (var i = 0; i < 4; i++) {
          await guard.get(uri, headers: const {}, timeout: null);
        }

        expect(
          () => guard.get(uri, headers: const {}, timeout: null),
          throwsA(isA<HttpException>()),
        );
        expect(inner.requested.length, 4);
      },
    );

    test('never carries a POST or a download', () async {
      final guard = NyctisTorOriginGuardBridge(
        Uri.parse('https://example.invalid/a'),
        inner: _RecordingTorBridge(),
      );

      expect(
        () => guard.post(
          Uri.parse('https://example.invalid/a'),
          headers: const {},
          bodyBytes: const [],
          timeout: null,
        ),
        throwsA(isA<TorUnsupportedHttpMethodException>()),
      );
      expect(
        () => guard.download(
          Uri.parse('https://example.invalid/a'),
          headers: const {},
          destinationPath: '/tmp/x',
        ),
        throwsA(isA<TorUnsupportedHttpMethodException>()),
      );
    });
  });

  group('NyctisSingleHopHttpClient', () {
    test('clears followRedirects on every request it opens', () async {
      final inner = _FakeHttpClient();
      final client = NyctisSingleHopHttpClient(inner);

      final opened = await client.openUrl(
        'GET',
        Uri.parse('https://example.invalid/a'),
      );
      final got = await client.getUrl(Uri.parse('https://example.invalid/b'));

      expect(opened.followRedirects, isFalse);
      expect(got.followRedirects, isFalse);
      expect(inner.opened.length, 2);
    });
  });

  group('NyctisPrivacyTransport', () {
    test('refuses anything that is not https before opening a client', () {
      expect(
        () => const NyctisPrivacyTransport().get(
          Uri.parse('http://example.invalid/a.json'),
          timeout: const Duration(seconds: 1),
          headers: const {},
          maxBytes: 1024,
        ),
        throwsArgumentError,
      );
    });
  });
  group('NyctisPrivacyTransport against a hostile host (direct route)', () {
    late NyctisHostileServer server;
    late NyctisPlainHttpClient direct;

    Future<NyctisHttpReply> fetch(String path, {int maxBytes = 16 * 1024}) {
      final transport = NyctisPrivacyTransport.withRoute(
        torDesired: () => false,
        directClient: () => direct,
      );
      return transport.get(
        server.https(path),
        timeout: const Duration(seconds: 10),
        headers: const {'accept': 'application/json'},
        maxBytes: maxBytes,
      );
    }

    setUp(() => direct = NyctisPlainHttpClient());
    tearDown(() => server.close());

    test('an endless body is cut off at the cap, not buffered', () async {
      server = await NyctisHostileServer.start(
        NyctisHostileBehaviour.endless,
      );

      final stopwatch = Stopwatch()..start();
      await expectLater(
        fetch('/c.json'),
        throwsA(
          isA<NyctisResponseTooLargeException>()
              .having((e) => e.maxBytes, 'maxBytes', 16 * 1024)
              // At most the cap plus one socket read crossed into Dart. One
              // read can be as large as the kernel's receive buffer (hundreds
              // of KiB on loopback), which is what bounds it — not the host.
              .having(
                (e) => e.receivedBytes,
                'receivedBytes',
                inInclusiveRange(16 * 1024 + 1, 8 * 1024 * 1024),
              ),
        ),
      );
      // The connection was dropped, so the server stopped writing long before
      // its 1 GiB safety stop: what it got out is the cap plus whatever the
      // loopback socket buffers held.
      await server.clientHungUp.future.timeout(const Duration(seconds: 5));
      expect(server.bytesWritten, lessThan(64 * 1024 * 1024));
      expect(server.requests.single['accept-encoding'], 'identity');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('asks for identity and refuses a gzip bomb unread', () async {
      server = await NyctisHostileServer.start(
        NyctisHostileBehaviour.gzipBomb,
      );

      await expectLater(
        fetch('/logo.png', maxBytes: kNyctisLogoMaxBytes),
        throwsA(
          isA<NyctisCompressedResponseException>().having(
            (e) => e.encoding,
            'encoding',
            'gzip',
          ),
        ),
      );
      expect(server.requests.single['accept-encoding'], 'identity');
    });

    test(
      'refuses a declared Content-Length over the cap before reading',
      () async {
        server = await NyctisHostileServer.start(
          NyctisHostileBehaviour.declaredHuge,
        );

        await expectLater(
          fetch('/c.json'),
          throwsA(
            isA<NyctisResponseTooLargeException>().having(
              (e) => e.receivedBytes,
              'receivedBytes',
              0,
            ),
          ),
        );
      },
    );

    test('a body under the cap still arrives whole', () async {
      server = await NyctisHostileServer.start(NyctisHostileBehaviour.ok);

      final reply = await fetch('/c.json');

      expect(reply.statusCode, 200);
      expect(reply.body, NyctisHostileServer.okBody);
    });

    test(
      'the reader turns a streamed refusal into tooLarge and charges it',
      () async {
        server = await NyctisHostileServer.start(
          NyctisHostileBehaviour.endless,
        );
        final reader = NyctisMetadataReader(
          transport: NyctisPrivacyTransport.withRoute(
            torDesired: () => false,
            directClient: () => direct,
          ),
        );

        final result = await reader.read(
          server.https('/0.png'),
          maxBytes: kNyctisLogoMaxBytes,
          accept: 'image/png',
          budget: NyctisResourceBudget(),
        );

        expect(result.reason, NyctisMetadataAbandonReason.tooLarge);
        expect(reader.traffic.requests, 1);
        // Charged with what arrived, which is the cap and not zero.
        expect(
          reader.traffic.bytesReceived,
          greaterThan(kNyctisLogoMaxBytes),
        );
      },
    );
  });

  group('NyctisPrivacyTransport on the Tor route', () {
    test('never touches the direct client while Tor is on', () async {
      final server = await NyctisHostileServer.start(
        NyctisHostileBehaviour.ok,
      );
      addTearDown(server.close);
      final direct = NyctisPlainHttpClient();
      final bridge = _ScriptedTorBridge(
        response: NetworkHttpResponse(
          statusCode: 200,
          bodyBytes: Uint8List.fromList([1, 2, 3]),
        ),
      );

      final reply =
          await NyctisPrivacyTransport.withRoute(
            torDesired: () => true,
            torBootstrapping: () => false,
            torBridge: bridge,
            directClient: () => direct,
          ).get(
            server.https('/c.json'),
            timeout: const Duration(seconds: 5),
            headers: const {'accept': 'application/json'},
            maxBytes: 1024,
          );

      expect(reply.body, [1, 2, 3]);
      expect(bridge.requested.single, server.https('/c.json'));
      expect(bridge.headers.single['accept-encoding'], 'identity');
      expect(direct.opened, 0);
      expect(server.requests, isEmpty);
    });

    test('fails closed when Tor is broken: no clearnet fallback', () async {
      final server = await NyctisHostileServer.start(
        NyctisHostileBehaviour.ok,
      );
      addTearDown(server.close);
      final direct = NyctisPlainHttpClient();
      final reader = NyctisMetadataReader(
        transport: NyctisPrivacyTransport.withRoute(
          torDesired: () => true,
          torBootstrapping: () => false,
          torBridge: _ScriptedTorBridge(
            error: StateError('Tor is not enabled'),
          ),
          directClient: () => direct,
        ),
      );

      final result = await reader.read(
        server.https('/c.json'),
        maxBytes: kNyctisDocumentMaxBytes,
        accept: 'application/json',
        budget: NyctisResourceBudget(),
      );

      expect(result.reason, NyctisMetadataAbandonReason.transport);
      expect(direct.opened, 0, reason: 'the direct route was never tried');
      expect(server.requests, isEmpty);
    });

    test('refuses a Tor body over the cap on arrival', () async {
      final bridge = _ScriptedTorBridge(
        response: NetworkHttpResponse(
          statusCode: 200,
          bodyBytes: Uint8List(2048),
        ),
      );

      await expectLater(
        NyctisPrivacyTransport.withRoute(
          torDesired: () => true,
          torBootstrapping: () => false,
          torBridge: bridge,
        ).get(
          Uri.parse('https://example.invalid/c.json'),
          timeout: const Duration(seconds: 5),
          headers: const {},
          maxBytes: 1024,
        ),
        throwsA(
          isA<NyctisResponseTooLargeException>().having(
            (e) => e.receivedBytes,
            'receivedBytes',
            2048,
          ),
        ),
      );
    });

    test('refuses a compressed Tor body', () async {
      final bridge = _ScriptedTorBridge(
        response: NetworkHttpResponse(
          statusCode: 200,
          bodyBytes: Uint8List(10),
          headers: const {
            'content-encoding': ['gzip'],
          },
        ),
      );

      await expectLater(
        NyctisPrivacyTransport.withRoute(
          torDesired: () => true,
          torBootstrapping: () => false,
          torBridge: bridge,
        ).get(
          Uri.parse('https://example.invalid/c.json'),
          timeout: const Duration(seconds: 5),
          headers: const {},
          maxBytes: 1024,
        ),
        throwsA(isA<NyctisCompressedResponseException>()),
      );
    });
  });
}
