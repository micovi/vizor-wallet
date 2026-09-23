import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../rust/api/network_privacy.dart' as rust_network_privacy;
import '../../rust/network_privacy.dart' as rust_types;

class NetworkHttpResponse {
  const NetworkHttpResponse({
    required this.statusCode,
    required this.bodyBytes,
    this.headers = const {},
  });

  final int statusCode;
  final Uint8List bodyBytes;
  final Map<String, List<String>> headers;

  String? header(String name) {
    final values = headers[name.toLowerCase()];
    return values == null || values.isEmpty ? null : values.first;
  }
}

class TorUnsupportedHttpMethodException implements Exception {
  const TorUnsupportedHttpMethodException(this.method);

  final String method;

  @override
  String toString() =>
      'The $method request was blocked because the embedded Tor transport '
      'does not support this method.';
}

class DirectNetworkRequestsBlockedException implements Exception {
  const DirectNetworkRequestsBlockedException();

  @override
  String toString() =>
      'Direct network requests are blocked while the app switches to Tor.';
}

class NetworkHttpRequestCancelledException implements Exception {
  const NetworkHttpRequestCancelledException();

  @override
  String toString() => 'Network HTTP request cancelled';
}

/// A response body ran past the `maxBodyBytes` the caller passed to
/// [NetworkHttpClient.request].
///
/// On the direct route the request is aborted as soon as the count passes the
/// cap, so [receivedBytes] is at most the cap plus one socket read (bounded by
/// the kernel receive buffer, not by the server), and the chunk that crossed
/// the cap is never added to the body. On the Tor route the Rust bridge hands
/// the body over whole, so the check happens on arrival and [receivedBytes] is
/// the full length.
class NetworkHttpResponseTooLargeException implements Exception {
  const NetworkHttpResponseTooLargeException({
    required this.maxBodyBytes,
    required this.receivedBytes,
  });

  final int maxBodyBytes;

  /// Bytes that crossed the wire before the refusal. Zero when a declared
  /// `Content-Length` already exceeded the cap and nothing was read.
  final int receivedBytes;

  @override
  String toString() =>
      'The response body was refused after $receivedBytes bytes; '
      'the limit is $maxBodyBytes.';
}

/// A capped request got a response with a `Content-Encoding` other than
/// `identity`.
///
/// A capped request asks for `identity`, and a compressed answer is refused
/// before any of it is read: a few kilobytes of gzip can inflate past any cap
/// faster than the cap can be checked, so the only bounded way to read one is
/// not to.
class NetworkHttpCompressedResponseException implements Exception {
  const NetworkHttpCompressedResponseException(this.encoding);

  final String encoding;

  @override
  String toString() =>
      'Refusing a response with Content-Encoding "$encoding" on a '
      'size-capped request.';
}

class _DirectRequestOperation<T> {
  _DirectRequestOperation({required this.result, required Future<T> source})
    : drained = source.then<void>((_) {}, onError: (_, _) {});

  factory _DirectRequestOperation.fromFuture(Future<T> source) =>
      _DirectRequestOperation(result: source, source: source);

  final Future<T> result;
  final Future<void> drained;
}

/// Tor transport boundary used after the process-wide route selects Tor.
///
/// Implementations must apply each timeout to the underlying transport
/// operation, not only to the Future returned to Dart.
abstract interface class TorHttpBridge {
  Future<NetworkHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration? timeout,
    Future<void>? cancelSignal,
  });

  Future<NetworkHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required List<int> bodyBytes,
    required Duration? timeout,
    Future<void>? cancelSignal,
  });

  Future<NetworkHttpResponse> download(
    Uri uri, {
    required Map<String, String> headers,
    required String destinationPath,
  });
}

class RustTorHttpBridge implements TorHttpBridge {
  const RustTorHttpBridge();

  static const _requestTimeoutError = 'Tor HTTP request timed out';

  @override
  Future<NetworkHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) {
    return _request(
      timeout,
      cancelSignal,
      (requestId) => rust_network_privacy.torHttpGet(
        url: uri.toString(),
        headers: _rustHeaders(headers),
        timeoutMilliseconds: _timeoutMilliseconds(timeout),
        requestId: requestId,
      ),
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
    return _request(
      timeout,
      cancelSignal,
      (requestId) => rust_network_privacy.torHttpPost(
        url: uri.toString(),
        headers: _rustHeaders(headers),
        body: bodyBytes,
        timeoutMilliseconds: _timeoutMilliseconds(timeout),
        requestId: requestId,
      ),
    );
  }

  @override
  Future<NetworkHttpResponse> download(
    Uri uri, {
    required Map<String, String> headers,
    required String destinationPath,
  }) async {
    final response = await rust_network_privacy.torHttpDownload(
      url: uri.toString(),
      headers: _rustHeaders(headers),
      destinationPath: destinationPath,
    );
    return networkHttpResponseFromRust(response);
  }

  static BigInt? _timeoutMilliseconds(Duration? timeout) {
    if (timeout == null) return null;
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    return BigInt.from(timeout.inMilliseconds < 1 ? 1 : timeout.inMilliseconds);
  }

  Future<NetworkHttpResponse> _request(
    Duration? timeout,
    Future<void>? cancelSignal,
    Future<rust_network_privacy.NetworkHttpResponse> Function(BigInt? requestId)
    send,
  ) async {
    final signal = cancelSignal;
    final requestId = signal == null
        ? null
        : rust_network_privacy.torHttpBeginRequest();
    var completed = false;
    if (requestId != null) {
      unawaited(
        signal!.then((_) {
          if (!completed) {
            rust_network_privacy.torHttpCancelRequest(requestId: requestId);
          }
        }, onError: (_, _) {}),
      );
    }
    try {
      return networkHttpResponseFromRust(await send(requestId));
    } catch (error, stackTrace) {
      if (error.toString().contains(_requestTimeoutError)) {
        throw TimeoutException(_requestTimeoutError, timeout);
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      completed = true;
      if (requestId != null) {
        rust_network_privacy.torHttpCancelRequest(requestId: requestId);
      }
    }
  }

  static List<rust_network_privacy.NetworkHttpHeader> _rustHeaders(
    Map<String, String> headers,
  ) => [
    for (final entry in headers.entries)
      rust_network_privacy.NetworkHttpHeader(
        name: entry.key,
        value: entry.value,
      ),
  ];
}

/// Converts the generated Rust response while preserving the concrete nested
/// generic types. Leaving either collection inferred through `unmodifiable`
/// produces `Map<dynamic, dynamic>` / `List<dynamic>` at runtime and breaks
/// every successful Tor HTTP response when it is read as typed headers.
NetworkHttpResponse networkHttpResponseFromRust(
  rust_network_privacy.NetworkHttpResponse response,
) {
  final headers = <String, List<String>>{};
  for (final header in response.headers) {
    (headers[header.name.toLowerCase()] ??= <String>[]).add(header.value);
  }
  final immutableHeaders = <String, List<String>>{
    for (final entry in headers.entries)
      entry.key: List<String>.unmodifiable(entry.value),
  };
  return NetworkHttpResponse(
    statusCode: response.statusCode,
    bodyBytes: response.body,
    headers: Map<String, List<String>>.unmodifiable(immutableHeaders),
  );
}

/// Routes app-owned HTTP traffic through the process-wide network privacy
/// policy. Tor mode never falls back to [HttpClient] when Tor is unavailable.
class NetworkHttpClient {
  NetworkHttpClient({
    HttpClient? directClient,
    bool Function()? torDesired,
    bool Function()? torBootstrapping,
    TorHttpBridge? torBridge,
  }) : _directClient = directClient ?? HttpClient(),
       _torDesired = torDesired ?? rust_network_privacy.isTorEnabled,
       _torBootstrapping = torBootstrapping ?? _rustTorBootstrapping,
       _torBridge = torBridge ?? const RustTorHttpBridge() {
    _instances.add(this);
  }

  static bool _rustTorBootstrapping() =>
      rust_network_privacy.getNetworkPrivacyStatus() ==
      rust_types.NetworkPrivacyStatus.bootstrapping;

  static final Set<NetworkHttpClient> _instances = {};
  static bool _directRequestsBlocked = false;

  HttpClient _directClient;
  final bool Function() _torDesired;
  final bool Function() _torBootstrapping;
  final TorHttpBridge _torBridge;
  var _activeDirectRequests = 0;
  var _directClientNeedsReset = false;
  var _closed = false;
  Completer<void>? _directRequestsDrained;

  /// Prevents new direct HTTP work, force-closes every app-owned direct
  /// client, and waits until the interrupted operations have unwound.
  static Future<void> quiesceDirectRequests() async {
    _directRequestsBlocked = true;
    await Future.wait([
      for (final client in List<NetworkHttpClient>.of(_instances))
        client._quiesceDirectRequests(),
    ]);
  }

  /// Reopens direct HTTP routing only after Rust has confirmed the route
  /// switch away from Tor.
  static void allowDirectRequests() {
    for (final client in List<NetworkHttpClient>.of(_instances)) {
      client._resetDirectClientAfterQuiesce();
    }
    _directRequestsBlocked = false;
  }

  /// Sends one request on the route the process-wide policy selects.
  ///
  /// [maxBodyBytes] bounds every response body this request reads, redirects
  /// included. When it is set the request asks for `Accept-Encoding:
  /// identity`, a response with any other `Content-Encoding` fails with
  /// [NetworkHttpCompressedResponseException] before its body is read, and a
  /// body past the cap fails with [NetworkHttpResponseTooLargeException]. On
  /// the direct route that happens while streaming, so no more than the cap
  /// is ever buffered, and no more than one socket read past it is received.
  /// The Tor bridge returns bodies whole, so there the cap is checked on
  /// arrival and memory is bounded only by the request's timeout, which the
  /// bridge applies to the whole exchange.
  Future<NetworkHttpResponse> request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int> bodyBytes = const [],
    Duration? timeout,
    Future<void>? cancelSignal,
    int? maxBodyBytes,
  }) {
    _requirePositiveTimeout(timeout);
    if (maxBodyBytes != null && maxBodyBytes < 0) {
      throw ArgumentError.value(
        maxBodyBytes,
        'maxBodyBytes',
        'must not be negative',
      );
    }
    final normalizedMethod = method.toUpperCase();
    final requestHeaders = maxBodyBytes == null
        ? headers
        : _withIdentityEncoding(headers);
    return _torDesired()
        ? _requestViaTorWithTimeoutRetry(
            normalizedMethod,
            uri,
            headers: requestHeaders,
            bodyBytes: bodyBytes,
            timeout: timeout,
            cancelSignal: cancelSignal,
            maxBodyBytes: maxBodyBytes,
          )
        : _runDirectRequest(
            () => _requestDirect(
              normalizedMethod,
              uri,
              headers: requestHeaders,
              bodyBytes: bodyBytes,
              timeout: timeout,
              cancelSignal: cancelSignal,
              maxBodyBytes: maxBodyBytes,
            ),
          );
  }

  Future<NetworkHttpResponse> _requestViaTorWithTimeoutRetry(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    required List<int> bodyBytes,
    required Duration? timeout,
    required Future<void>? cancelSignal,
    required int? maxBodyBytes,
  }) async {
    try {
      return await _requestViaTorWithRedirects(
        method,
        uri,
        headers: headers,
        bodyBytes: bodyBytes,
        timeout: timeout,
        cancelSignal: cancelSignal,
        maxBodyBytes: maxBodyBytes,
      );
    } on TimeoutException {
      if (method != 'GET') rethrow;
      // Each bridge GET resolves another isolated Tor client. Restarting the
      // redirect chain therefore avoids the circuit that timed out.
      return _requestViaTorWithRedirects(
        method,
        uri,
        headers: headers,
        bodyBytes: bodyBytes,
        timeout: timeout,
        cancelSignal: cancelSignal,
        maxBodyBytes: maxBodyBytes,
      );
    }
  }

  /// Streams a GET response to [destination] without retaining the response
  /// body in Dart memory. Tor mode performs the file write inside Rust so large
  /// downloads do not cross the FFI boundary as a whole-body byte array.
  Future<NetworkHttpResponse> downloadToFile(
    Uri uri,
    File destination, {
    Map<String, String> headers = const {},
    Duration? timeout,
  }) {
    final future = _torDesired()
        ? _requestViaTorWithRedirects(
            'GET',
            uri,
            headers: headers,
            bodyBytes: const [],
            destinationPath: destination.path,
            timeout: null,
            cancelSignal: null,
          )
        : _runDirectRequest(
            () => _DirectRequestOperation.fromFuture(
              _downloadDirect(uri, destination, headers: headers),
            ),
          );
    return timeout == null ? future : future.timeout(timeout);
  }

  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _directClient.close(force: force);
    if (_activeDirectRequests == 0) _instances.remove(this);
  }

  Future<T> _runDirectRequest<T>(
    _DirectRequestOperation<T> Function() request,
  ) {
    if (_directRequestsBlocked || _closed) {
      return Future.error(const DirectNetworkRequestsBlockedException());
    }
    _activeDirectRequests++;
    final _DirectRequestOperation<T> operation;
    try {
      operation = request();
    } catch (error, stackTrace) {
      _finishDirectRequest();
      return Future.error(error, stackTrace);
    }
    unawaited(operation.drained.whenComplete(_finishDirectRequest));
    return operation.result;
  }

  void _finishDirectRequest() {
    _activeDirectRequests--;
    if (_activeDirectRequests == 0) {
      _directRequestsDrained?.complete();
      _directRequestsDrained = null;
      if (_closed) _instances.remove(this);
    }
  }

  Future<void> _quiesceDirectRequests() {
    _directClient.close(force: true);
    if (!_closed) _directClientNeedsReset = true;
    if (_activeDirectRequests == 0) return Future.value();
    return (_directRequestsDrained ??= Completer<void>()).future;
  }

  void _resetDirectClientAfterQuiesce() {
    if (_closed || !_directClientNeedsReset) return;
    _directClient = HttpClient();
    _directClientNeedsReset = false;
  }

  Future<NetworkHttpResponse> _requestViaTorWithRedirects(
    String method,
    Uri initialUri, {
    required Map<String, String> headers,
    required List<int> bodyBytes,
    String? destinationPath,
    required Duration? timeout,
    required Future<void>? cancelSignal,
    int? maxBodyBytes,
  }) async {
    if (method != 'GET' && method != 'POST') {
      throw TorUnsupportedHttpMethodException(method);
    }

    var currentMethod = method;
    var currentUri = initialUri;
    var currentHeaders = Map<String, String>.of(headers);
    var currentBody = bodyBytes;
    // Every hop is charged to the redirect budget, except a first hop that
    // is about to park inside Rust waiting for a Tor bootstrap: that wait is
    // outside the per-request timeout too, and billing it would leave a
    // redirect no budget. Dart cannot see when the wait ends, so the clock
    // then starts at the first response.
    final stopwatch = Stopwatch();
    if (!_torBootstrapping()) stopwatch.start();
    for (var redirectCount = 0; redirectCount <= 5; redirectCount++) {
      final remainingTimeout = _remainingTimeout(timeout, stopwatch);
      final response = destinationPath != null
          ? await _torBridge.download(
              currentUri,
              headers: currentHeaders,
              destinationPath: destinationPath,
            )
          : currentMethod == 'GET'
          ? await _torBridge.get(
              currentUri,
              headers: currentHeaders,
              timeout: remainingTimeout,
              cancelSignal: cancelSignal,
            )
          : await _torBridge.post(
              currentUri,
              headers: currentHeaders,
              bodyBytes: currentBody,
              timeout: remainingTimeout,
              cancelSignal: cancelSignal,
            );
      if (!stopwatch.isRunning) stopwatch.start();
      if (maxBodyBytes != null) {
        // The bridge has already buffered this body in full; what the cap can
        // still do here is keep it from reaching the caller.
        _checkEncoding(
          response.headers[HttpHeaders.contentEncodingHeader]?.join(', '),
        );
        if (response.bodyBytes.length > maxBodyBytes) {
          throw NetworkHttpResponseTooLargeException(
            maxBodyBytes: maxBodyBytes,
            receivedBytes: response.bodyBytes.length,
          );
        }
      }
      final location = response.header(HttpHeaders.locationHeader);
      if (!_isRedirect(response.statusCode) || location == null) {
        return response;
      }
      if (redirectCount == 5) {
        throw const HttpException('Too many HTTP redirects');
      }
      final nextUri = currentUri.resolve(location);
      if (currentUri.scheme == 'https' && nextUri.scheme != 'https') {
        throw HttpException(
          'Refusing HTTPS redirect to ${nextUri.scheme}',
          uri: nextUri,
        );
      }
      currentHeaders = _headersForRedirect(currentUri, nextUri, currentHeaders);
      if (currentMethod == 'POST' &&
          (response.statusCode == HttpStatus.movedPermanently ||
              response.statusCode == HttpStatus.found ||
              response.statusCode == HttpStatus.seeOther)) {
        currentMethod = 'GET';
        currentBody = const [];
      }
      currentUri = nextUri;
    }
    throw const HttpException('Too many HTTP redirects');
  }

  _DirectRequestOperation<NetworkHttpResponse> _requestDirect(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    required List<int> bodyBytes,
    required Duration? timeout,
    required Future<void>? cancelSignal,
    required int? maxBodyBytes,
  }) {
    HttpClientRequest? activeRequest;
    StreamSubscription<List<int>>? responseSubscription;
    Completer<Uint8List>? responseBody;
    Object? terminationError;
    var sourceCompleted = false;
    Future<void> abort(Object error) async {
      try {
        activeRequest?.abort(error);
      } catch (_) {
        // Continue cleanup and preserve the original public failure.
      }
      try {
        await responseSubscription?.cancel();
      } catch (_) {
        // Continue cleanup and preserve the original public failure.
      }
      final body = responseBody;
      if (body != null && !body.isCompleted) body.completeError(error);
    }

    final request = () async {
      try {
        final request = await _directClient.openUrl(method, uri);
        activeRequest = request;
        final pendingError = terminationError;
        if (pendingError != null) {
          final error = pendingError;
          request.abort(error);
          throw error;
        }
        headers.forEach(request.headers.set);
        if (bodyBytes.isNotEmpty) request.add(bodyBytes);
        final response = await request.close();
        if (maxBodyBytes != null) {
          final refusal = _refusalBeforeBody(response, maxBodyBytes);
          if (refusal != null) {
            terminationError ??= refusal;
            try {
              request.abort(refusal);
            } catch (_) {
              // The refusal is the public failure; cleanup is best effort.
            }
            try {
              await response.listen(null, onError: (_, _) {}).cancel();
            } catch (_) {
              // As above.
            }
            throw refusal;
          }
        }
        final body = responseBody = Completer<Uint8List>();
        final bytes = BytesBuilder();
        var received = 0;
        responseSubscription = response.listen(
          (chunk) {
            if (body.isCompleted) return;
            received += chunk.length;
            if (maxBodyBytes != null && received > maxBodyBytes) {
              // Abort while streaming: the chunk that crossed the cap is the
              // last one read, and nothing past it is buffered.
              final error = NetworkHttpResponseTooLargeException(
                maxBodyBytes: maxBodyBytes,
                receivedBytes: received,
              );
              terminationError ??= error;
              unawaited(abort(error));
              return;
            }
            bytes.add(chunk);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!body.isCompleted) body.completeError(error, stackTrace);
          },
          onDone: () {
            if (!body.isCompleted) body.complete(bytes.takeBytes());
          },
          cancelOnError: true,
        );
        final responseHeaders = <String, List<String>>{};
        response.headers.forEach((name, values) {
          responseHeaders[name.toLowerCase()] = List.unmodifiable(values);
        });
        return NetworkHttpResponse(
          statusCode: response.statusCode,
          bodyBytes: await body.future,
          headers: Map.unmodifiable(responseHeaders),
        );
      } finally {
        sourceCompleted = true;
      }
    }();
    final signal = cancelSignal;
    final cancellation = signal == null
        ? null
        : Completer<NetworkHttpResponse>();
    if (cancellation != null) {
      unawaited(
        signal!.then((_) async {
          if (sourceCompleted) return;
          final error = terminationError ??=
              const NetworkHttpRequestCancelledException();
          await abort(error);
          if (!cancellation.isCompleted) {
            cancellation.completeError(error);
          }
        }, onError: (_, _) {}),
      );
    }
    final cancellableRequest = cancellation == null
        ? request
        : Future.any([request, cancellation.future]);
    final result = timeout == null
        ? cancellableRequest
        : cancellableRequest.timeout(
            timeout,
            onTimeout: () async {
              final error = terminationError ??= _timeoutException(timeout);
              await abort(error);
              throw error;
            },
          );
    return _DirectRequestOperation(result: result, source: request);
  }

  Future<NetworkHttpResponse> _downloadDirect(
    Uri uri,
    File destination, {
    required Map<String, String> headers,
  }) async {
    final request = await _directClient.getUrl(uri);
    headers.forEach(request.headers.set);
    final response = await request.close();
    await response.pipe(destination.openWrite());
    final responseHeaders = <String, List<String>>{};
    response.headers.forEach((name, values) {
      responseHeaders[name.toLowerCase()] = List.unmodifiable(values);
    });
    return NetworkHttpResponse(
      statusCode: response.statusCode,
      bodyBytes: Uint8List(0),
      headers: Map.unmodifiable(responseHeaders),
    );
  }

  static Duration? _remainingTimeout(Duration? timeout, Stopwatch stopwatch) {
    if (timeout == null) return null;
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) throw _timeoutException(timeout);
    return remaining;
  }

  static void _requirePositiveTimeout(Duration? timeout) {
    if (timeout != null && timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
  }

  static TimeoutException _timeoutException(Duration timeout) =>
      TimeoutException('Network HTTP request timed out', timeout);

  /// [headers] with any caller `Accept-Encoding` replaced by `identity`.
  static Map<String, String> _withIdentityEncoding(
    Map<String, String> headers,
  ) => {
    for (final entry in headers.entries)
      if (entry.key.toLowerCase() != HttpHeaders.acceptEncodingHeader)
        entry.key: entry.value,
    HttpHeaders.acceptEncodingHeader: 'identity',
  };

  static void _checkEncoding(String? encoding) {
    final value = encoding?.trim().toLowerCase();
    if (value == null || value.isEmpty || value == 'identity') return;
    throw NetworkHttpCompressedResponseException(encoding!);
  }

  /// Why a capped direct response must not be read at all, or null.
  ///
  /// `compressionState` is checked as well as the header because it is what
  /// decides whether `dart:io` inflates the stream; an injected client with
  /// `autoUncompress` left on would otherwise hand the listener inflated
  /// bytes, and the cap would be counting the wrong thing.
  static Object? _refusalBeforeBody(
    HttpClientResponse response,
    int maxBodyBytes,
  ) {
    // `headers.value` throws on a repeated header; a hostile host can repeat
    // one, so every value is read and any non-identity one refuses.
    final encodings = response.headers[HttpHeaders.contentEncodingHeader];
    final encoding = encodings?.join(', ');
    try {
      _checkEncoding(encoding);
    } on NetworkHttpCompressedResponseException catch (error) {
      return error;
    }
    if (response.compressionState !=
        HttpClientResponseCompressionState.notCompressed) {
      return NetworkHttpCompressedResponseException(encoding ?? 'unknown');
    }
    if (response.contentLength > maxBodyBytes) {
      return NetworkHttpResponseTooLargeException(
        maxBodyBytes: maxBodyBytes,
        receivedBytes: 0,
      );
    }
    return null;
  }

  static Map<String, String> _headersForRedirect(
    Uri from,
    Uri to,
    Map<String, String> headers,
  ) {
    if (_sameOrigin(from, to)) return headers;
    const sensitive = {
      HttpHeaders.authorizationHeader,
      HttpHeaders.cookieHeader,
      HttpHeaders.proxyAuthorizationHeader,
    };
    return {
      for (final entry in headers.entries)
        if (!sensitive.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
  }

  static bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  static bool _isRedirect(int statusCode) =>
      statusCode == HttpStatus.movedPermanently ||
      statusCode == HttpStatus.found ||
      statusCode == HttpStatus.seeOther ||
      statusCode == HttpStatus.temporaryRedirect ||
      statusCode == HttpStatus.permanentRedirect;
}
