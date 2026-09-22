import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/network/network_http_client.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_metadata_transport.dart';

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
  group('NightjarTorOriginGuardBridge', () {
    test('lets a same-origin hop through', () async {
      final inner = _RecordingTorBridge();
      final guard = NightjarTorOriginGuardBridge(
        Uri.parse('https://example.invalid/nj/gold.json'),
        inner: inner,
      );

      await guard.get(
        Uri.parse('https://example.invalid/nj/moved.json'),
        headers: const {},
        timeout: null,
      );

      expect(inner.requested.single.path, '/nj/moved.json');
    });

    test('refuses a hop to a different host before it is made', () async {
      final inner = _RecordingTorBridge();
      final guard = NightjarTorOriginGuardBridge(
        Uri.parse('https://example.invalid/nj/gold.json'),
        inner: inner,
      );

      // Thrown synchronously, before a future exists: the guard refuses the
      // hop rather than starting it and failing.
      expect(
        () => guard.get(
          Uri.parse('https://elsewhere.invalid/nj/gold.json'),
          headers: const {},
          timeout: null,
        ),
        throwsA(isA<NightjarCrossOriginRedirectException>()),
      );
      expect(inner.requested, isEmpty);
    });

    test('refuses a hop to a different port on the same host', () async {
      final inner = _RecordingTorBridge();
      final guard = NightjarTorOriginGuardBridge(
        Uri.parse('https://example.invalid/a'),
        inner: inner,
      );

      expect(
        () => guard.get(
          Uri.parse('https://example.invalid:8443/a'),
          headers: const {},
          timeout: null,
        ),
        throwsA(isA<NightjarCrossOriginRedirectException>()),
      );
    });

    test(
      'spends the section 3.2 budget of one request plus three redirects',
      () async {
        final inner = _RecordingTorBridge();
        final uri = Uri.parse('https://example.invalid/a');
        final guard = NightjarTorOriginGuardBridge(uri, inner: inner);

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
      final guard = NightjarTorOriginGuardBridge(
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

  group('NightjarSingleHopHttpClient', () {
    test('clears followRedirects on every request it opens', () async {
      final inner = _FakeHttpClient();
      final client = NightjarSingleHopHttpClient(inner);

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

  group('NightjarPrivacyTransport', () {
    test('refuses anything that is not https before opening a client', () {
      expect(
        () => const NightjarPrivacyTransport().get(
          Uri.parse('http://example.invalid/a.json'),
          timeout: const Duration(seconds: 1),
          headers: const {},
        ),
        throwsArgumentError,
      );
    });
  });
}
