/// The one-hop HTTPS transport the metadata fetcher is allowed to use.
///
/// Two rules from `spec/asset-metadata-v0.md` shape this file, and both are
/// about *who learns something*, not about correctness:
///
/// * Section 3.1 — a fetch discloses interest, so it **MUST** go through the
///   wallet's privacy transport when it has one. That is [NetworkHttpClient],
///   the policy-aware opener: a raw `HttpClient` here would bypass the Tor
///   route entirely and send the request straight out of the user's own IP
///   while the settings screen says otherwise.
/// * Section 2 — a wallet **MUST NOT** follow a redirect to a different
///   origin, because following one hands the choice of host to whoever holds
///   the first one. [NetworkHttpClient] follows redirects itself on both of
///   its routes, so enforcing this means constraining it from the outside on
///   each route separately:
///   - **direct**: the injected client is [NyctisSingleHopHttpClient], which sets
///     `followRedirects = false` on every request it opens. The 3xx comes back
///     to Dart and `NyctisAssetMetadataFetcher` decides whether to take it.
///   - **Tor**: redirect following happens above the bridge, inside
///     [NetworkHttpClient], so it cannot be turned off from here — but every
///     hop is a separate bridge call, and [NyctisTorOriginGuardBridge] refuses one
///     whose origin is not the origin the fetch started at.
///
/// A fresh [NetworkHttpClient] is built per request rather than held. It is
/// cheap, it keeps the per-request Tor origin guard from being shared between
/// concurrent fetches, and it sidesteps `NetworkHttpClient
/// ._resetDirectClientAfterQuiesce`, which replaces an injected direct client
/// with a plain `HttpClient()` after a Tor toggle — on a long-lived instance
/// that would silently restore redirect following.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'dart:typed_data';

import '../../../core/network/network_http_client.dart';

/// One HTTP response, reduced to what the fetcher is allowed to look at.
class NyctisHttpReply {
  const NyctisHttpReply({
    required this.statusCode,
    required this.body,
    this.location,
  });

  final int statusCode;
  final Uint8List body;

  /// `Location`, when the reply was a redirect. Null on the Tor route, where
  /// [NetworkHttpClient] resolves redirects below this layer under the origin
  /// guard.
  final String? location;

  bool get isRedirect =>
      statusCode == HttpStatus.movedPermanently ||
      statusCode == HttpStatus.found ||
      statusCode == HttpStatus.seeOther ||
      statusCode == HttpStatus.temporaryRedirect ||
      statusCode == HttpStatus.permanentRedirect;

  bool get isOk => statusCode >= 200 && statusCode < 300;
}

/// A single HTTPS GET that does not follow a cross-origin redirect.
abstract interface class NyctisMetadataTransport {
  /// [maxBytes] is the most body this request may read. An implementation
  /// that can stream **must** stop reading once it is passed, and throw
  /// [NyctisResponseTooLargeException]; one that cannot may return the
  /// whole body and leave the reader to refuse it.
  Future<NyctisHttpReply> get(
    Uri uri, {
    required Duration timeout,
    required Map<String, String> headers,
    required int maxBytes,
  });
}

/// The body ran past the `maxBytes` the request was allowed.
///
/// [receivedBytes] is what crossed the wire before the refusal, which is what
/// a caller spending a byte budget has to charge: a refused download still
/// cost the bandwidth it took to refuse it.
class NyctisResponseTooLargeException implements Exception {
  const NyctisResponseTooLargeException({
    required this.maxBytes,
    required this.receivedBytes,
  });

  final int maxBytes;
  final int receivedBytes;

  @override
  String toString() =>
      'Nyctis metadata response refused after $receivedBytes bytes '
      '(limit $maxBytes)';
}

/// The host answered with a compressed body, which a capped read refuses
/// rather than inflates (see [NetworkHttpCompressedResponseException]).
class NyctisCompressedResponseException implements Exception {
  const NyctisCompressedResponseException(this.encoding);

  final String encoding;

  @override
  String toString() =>
      'Nyctis metadata response refused: Content-Encoding "$encoding"';
}

/// Refused before a byte left the device: the request was to an origin the
/// fetch is not allowed to reach.
class NyctisCrossOriginRedirectException implements Exception {
  const NyctisCrossOriginRedirectException(this.from, this.to);

  final Uri from;
  final Uri to;

  @override
  String toString() =>
      'Refusing a Nyctis metadata redirect from ${from.host} to ${to.host}';
}

/// The shipped transport: [NetworkHttpClient], constrained to one origin.
///
/// **Bounded as it streams.** `maxBytes` goes to [NetworkHttpClient] as its
/// body cap, so on the direct route the connection is dropped the moment the
/// count passes it, and nothing past the cap is ever buffered. The request
/// asks for `identity`, `dart:io`'s own decompression is off, and a compressed
/// answer is refused before a byte of it is read: a 10 KiB gzip body can
/// inflate to gigabytes, and the only bounded way to read one is not to.
///
/// On the Tor route the Rust bridge returns a body whole, so the cap there is
/// enforced on arrival: the request's deadline, which the bridge applies to
/// the whole exchange, bounds what a hostile host can push through a circuit,
/// and nothing over the cap reaches the fetcher. A streaming cap on that route
/// needs a body limit inside `tor_http_get` itself. Tor bodies are never inflated — hyper
/// does not decompress — so the bomb case does not arise on that route.
class NyctisPrivacyTransport implements NyctisMetadataTransport {
  const NyctisPrivacyTransport()
    : _torDesired = null,
      _torBootstrapping = null,
      _torBridge = null,
      _directClient = null;

  /// The same transport with the route decision and both routes injected, so
  /// a test can prove which one a request took. Production code uses the
  /// default constructor and the process-wide policy.
  @visibleForTesting
  const NyctisPrivacyTransport.withRoute({
    bool Function()? torDesired,
    bool Function()? torBootstrapping,
    TorHttpBridge? torBridge,
    HttpClient Function()? directClient,
  }) : _torDesired = torDesired,
       _torBootstrapping = torBootstrapping,
       _torBridge = torBridge,
       _directClient = directClient;

  final bool Function()? _torDesired;
  final bool Function()? _torBootstrapping;
  final TorHttpBridge? _torBridge;
  final HttpClient Function()? _directClient;

  @override
  Future<NyctisHttpReply> get(
    Uri uri, {
    required Duration timeout,
    required Map<String, String> headers,
    required int maxBytes,
  }) async {
    // Section 2 already forbade every other scheme; this is the assertion that
    // no caller talked its way past it.
    if (uri.scheme != 'https') {
      throw ArgumentError.value(uri, 'uri', 'must be https');
    }
    final direct = (_directClient?.call() ?? HttpClient())
      ..connectionTimeout = timeout
      ..autoUncompress = false
      ..userAgent = null;
    final client = NetworkHttpClient(
      directClient: NyctisSingleHopHttpClient(direct),
      torDesired: _torDesired,
      torBootstrapping: _torBootstrapping,
      torBridge: NyctisTorOriginGuardBridge(uri, inner: _torBridge),
    );
    try {
      final response = await client.request(
        'GET',
        uri,
        headers: headers,
        timeout: timeout,
        maxBodyBytes: maxBytes,
      );
      return NyctisHttpReply(
        statusCode: response.statusCode,
        body: response.bodyBytes,
        location: response.header(HttpHeaders.locationHeader),
      );
    } on NetworkHttpResponseTooLargeException catch (error) {
      throw NyctisResponseTooLargeException(
        maxBytes: error.maxBodyBytes,
        receivedBytes: error.receivedBytes,
      );
    } on NetworkHttpCompressedResponseException catch (error) {
      throw NyctisCompressedResponseException(error.encoding);
    } finally {
      client.close(force: true);
    }
  }
}

/// Wraps the real Tor bridge and refuses any hop that leaves [_origin].
///
/// [NetworkHttpClient] resolves redirects above the bridge, so this is the
/// only place on the Tor route where a hop's destination is visible before the
/// request for it is made.
@visibleForTesting
class NyctisTorOriginGuardBridge implements TorHttpBridge {
  NyctisTorOriginGuardBridge(this._origin, {TorHttpBridge? inner})
    : _inner = inner ?? const RustTorHttpBridge();

  /// Section 3.2 allows 3 redirects; 4 requests is the whole budget.
  static const int _maxHops = 4;

  final Uri _origin;
  final TorHttpBridge _inner;
  int _hops = 0;

  void _check(Uri uri) {
    if (++_hops > _maxHops) {
      throw const HttpException('Too many Nyctis metadata redirects');
    }
    if (!_sameOrigin(_origin, uri)) {
      throw NyctisCrossOriginRedirectException(_origin, uri);
    }
  }

  static bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  @override
  Future<NetworkHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) {
    _check(uri);
    return _inner.get(
      uri,
      headers: headers,
      timeout: timeout,
      cancelSignal: cancelSignal,
    );
  }

  @override
  Future<NetworkHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required List<int> bodyBytes,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) {
    // The fetcher only ever issues GET. A POST here would be somebody else's
    // traffic on a client that exists for one fetch.
    throw const TorUnsupportedHttpMethodException('POST');
  }

  @override
  Future<NetworkHttpResponse> download(
    Uri uri, {
    required Map<String, String> headers,
    required String destinationPath,
  }) {
    throw const TorUnsupportedHttpMethodException('DOWNLOAD');
  }
}

/// An [HttpClient] that never follows a redirect for anybody.
///
/// Everything is delegated except the request openers, which clear
/// `followRedirects` before the caller sees the request. `dart:io` follows
/// redirects inside `HttpClientRequest.close()` and offers no cross-origin
/// hook, so turning it off is the only way a Dart caller gets to decide.
@visibleForTesting
class NyctisSingleHopHttpClient implements HttpClient {
  NyctisSingleHopHttpClient(this._inner);

  final HttpClient _inner;

  Future<HttpClientRequest> _pin(Future<HttpClientRequest> request) async {
    final opened = await request;
    opened.followRedirects = false;
    return opened;
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => _pin(_inner.open(method, host, port, path));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _pin(_inner.openUrl(method, url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _pin(_inner.get(host, port, path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _pin(_inner.getUrl(url));

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _pin(_inner.post(host, port, path));

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _pin(_inner.postUrl(url));

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _pin(_inner.put(host, port, path));

  @override
  Future<HttpClientRequest> putUrl(Uri url) => _pin(_inner.putUrl(url));

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _pin(_inner.delete(host, port, path));

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => _pin(_inner.deleteUrl(url));

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _pin(_inner.patch(host, port, path));

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _pin(_inner.patchUrl(url));

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _pin(_inner.head(host, port, path));

  @override
  Future<HttpClientRequest> headUrl(Uri url) => _pin(_inner.headUrl(url));

  @override
  Duration get idleTimeout => _inner.idleTimeout;

  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;

  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;

  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;

  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) => _inner.authenticate = f;

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addCredentials(url, realm, credentials);

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) => _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
    f,
  ) => _inner.authenticateProxy = f;

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) => _inner.badCertificateCallback = callback;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void close({bool force = false}) => _inner.close(force: force);
}
