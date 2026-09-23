/// A local HTTP server that misbehaves on purpose, and a client that lets the
/// `https:`-only metadata transport talk to it.
///
/// The size caps exist for hosts that do not play fair, so they are tested
/// against one: a real socket, the real `dart:io` client and the real
/// `NetworkHttpClient` streaming path, not a fake that hands back a finished
/// buffer.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// What the server does with each request.
enum NyctisHostileBehaviour {
  /// 200, no `Content-Length`, and 64 KiB chunks until the client hangs up.
  endless,

  /// 200 with `Content-Encoding: gzip` and a small body that inflates to
  /// [NyctisHostileServer.bombInflatedBytes].
  gzipBomb,

  /// 200 with a `Content-Length` far over any cap, then nothing.
  declaredHuge,

  /// 200 with [NyctisHostileServer.okBody].
  ok,
}

class NyctisHostileServer {
  NyctisHostileServer._(this.behaviour);

  static const int chunkBytes = 64 * 1024;

  /// 64 MiB of zeros, which gzip carries in about 64 KiB.
  static const int bombInflatedBytes = 64 * 1024 * 1024;

  static final Uint8List okBody = Uint8List.fromList(
    List<int>.generate(1000, (i) => i % 251),
  );

  HttpServer? _http;
  ServerSocket? _raw;
  final NyctisHostileBehaviour behaviour;

  /// The headers of every request that reached the server, in order, with
  /// lower-cased names.
  final List<Map<String, String>> requests = [];

  /// Bytes the server handed to the operating system before the client went
  /// away. On the endless body this is a raw socket, whose `flush` waits for
  /// the kernel to take the bytes, so the number is real backpressure and not
  /// a Dart-side buffer.
  int bytesWritten = 0;

  /// Completes once the client has closed the connection on an endless body.
  final Completer<void> clientHungUp = Completer<void>();

  static List<int>? _bomb;

  static Future<NyctisHostileServer> start(
    NyctisHostileBehaviour behaviour,
  ) async {
    final hostile = NyctisHostileServer._(behaviour);
    if (behaviour == NyctisHostileBehaviour.endless) {
      // A raw socket, so the server's write loop feels the client's hang-up.
      // `HttpResponse.flush` completes against Dart's own buffer and would
      // report a gigabyte "written" to a client that left after 64 KiB.
      final raw = hostile._raw = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      raw.listen(hostile._endless);
      return hostile;
    }
    final server = hostile._http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    // The server must not compress on its own; the tests decide the encoding.
    server.autoCompress = false;
    server.listen(hostile._handle);
    return hostile;
  }

  int get port => _http?.port ?? _raw!.port;

  /// `http://127.0.0.1:<port><path>`.
  Uri http(String path) => Uri.parse('http://127.0.0.1:$port$path');

  /// The same address spelled `https:`, for the metadata transport, which
  /// refuses anything else. [NyctisPlainHttpClient] turns it back.
  Uri https(String path) => Uri.parse('https://127.0.0.1:$port$path');

  Future<void> close() async {
    await _http?.close(force: true);
    await _raw?.close();
  }

  void _hungUp() {
    if (!clientHungUp.isCompleted) clientHungUp.complete();
  }

  Future<void> _endless(Socket socket) async {
    final head = StringBuffer();
    final headDone = Completer<void>();
    socket.listen(
      (data) {
        if (headDone.isCompleted) return;
        head.write(String.fromCharCodes(data));
        if (head.toString().contains('\r\n\r\n')) headDone.complete();
      },
      onError: (_) => _hungUp(),
      onDone: _hungUp,
      cancelOnError: true,
    );
    await headDone.future;
    requests.add(_parseHead(head.toString()));
    final chunk = Uint8List(chunkBytes);
    try {
      socket.add(
        'HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n'
                'Connection: close\r\n\r\n'
            .codeUnits,
      );
      // Bounded only so a broken cap fails the test instead of hanging it:
      // 1 GiB is far past anything a capped client should read.
      while (!clientHungUp.isCompleted && bytesWritten < 1024 * 1024 * 1024) {
        socket.add(chunk);
        await socket.flush();
        bytesWritten += chunk.length;
      }
    } catch (_) {
      _hungUp();
    } finally {
      socket.destroy();
    }
  }

  static Map<String, String> _parseHead(String head) => {
    for (final line in head.split('\r\n').skip(1))
      if (line.contains(':'))
        line.substring(0, line.indexOf(':')).trim().toLowerCase(): line
            .substring(line.indexOf(':') + 1)
            .trim(),
  };

  Future<void> _handle(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    requests.add(headers);
    final response = request.response;
    switch (behaviour) {
      case NyctisHostileBehaviour.endless:
        throw StateError('served by _endless');
      case NyctisHostileBehaviour.gzipBomb:
        final bomb = _bomb ??= gzip.encode(Uint8List(bombInflatedBytes));
        response.statusCode = 200;
        response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        response.contentLength = bomb.length;
        try {
          response.add(bomb);
          bytesWritten += bomb.length;
          await response.close();
        } catch (_) {
          // The client refused and hung up, which is the point.
        }
      case NyctisHostileBehaviour.declaredHuge:
        response.statusCode = 200;
        response.contentLength = 1024 * 1024 * 1024;
        unawaited(response.done.then((_) {}, onError: (_) => _hungUp()));
        try {
          response.add(Uint8List(chunkBytes));
          await Future.any([response.flush(), clientHungUp.future]);
          bytesWritten += chunkBytes;
        } catch (_) {
          _hungUp();
        }
      case NyctisHostileBehaviour.ok:
        response.statusCode = 200;
        response.contentLength = okBody.length;
        response.add(okBody);
        await response.close();
    }
  }
}

/// An [HttpClient] that opens `https:` URLs as `http:` on the same host and
/// port, so the transport's `https:` rule can be kept while the bytes come
/// from [NyctisHostileServer]. Everything the transport touches is
/// delegated; nothing else is expected to be called.
class NyctisPlainHttpClient implements HttpClient {
  NyctisPlainHttpClient([HttpClient? inner]) : _inner = inner ?? HttpClient();

  final HttpClient _inner;

  /// How many requests this client opened. Zero proves a route never used it.
  int opened = 0;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    opened++;
    return _inner.openUrl(
      method,
      url.scheme == 'https' ? url.replace(scheme: 'http') : url,
    );
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;

  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;

  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  void close({bool force = false}) => _inner.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
