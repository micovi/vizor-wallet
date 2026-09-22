import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/network/network_http_client.dart';
import '../models/nightjar_asset.dart';
import '../models/nightjar_block.dart';
import '../models/nightjar_indexer_status.dart';
import '../models/nightjar_json.dart';
import '../models/nightjar_message.dart';
import '../models/nightjar_page.dart';
import '../models/nightjar_verifying_key.dart';

/// Server-side clamp on `limit`. Asking for more is not an error; the indexer
/// silently serves this many.
const kNightjarIndexerMaxLimit = 200;

/// Ceiling on a full message walk. A channel longer than this is a product
/// problem (the replay would not finish either), so it fails loudly rather
/// than paging forever.
const kNightjarIndexerMaxMessages = 50000;

/// Pages before a walk is treated as non-terminating. Independent of the
/// message ceiling so a misbehaving cursor is caught even on a short channel.
const kNightjarIndexerMaxPages = 1000;

/// Attempts one request gets before its failure is surfaced.
const kNightjarIndexerMaxAttempts = 3;

/// The longest `Retry-After` this client will sit out rather than surface.
///
/// A rate limit the indexer expects to last minutes is not something to hide
/// behind a spinner: the refresh the user is looking at is the retry.
const kNightjarIndexerMaxRetryWait = Duration(seconds: 5);

/// First backoff step when a transient failure carried no `Retry-After`.
const kNightjarIndexerRetryBackoff = Duration(milliseconds: 250);

/// A failure the Nightjar feature can show a user.
///
/// Every `http`/`dart:io` failure the client can produce is mapped into one of
/// these, so a caller never has to catch `SocketException` to render a message.
class NightjarIndexerException implements Exception {
  const NightjarIndexerException({
    required this.message,
    this.statusCode,
    this.detail,
    this.retryAfter,
    this.cause,
  });

  /// Sentence-case, user-facing.
  final String message;

  /// HTTP status, or `null` when the request never got an answer.
  final int? statusCode;

  /// The indexer's own `{"error": "..."}` text, verbatim. Diagnostics only —
  /// it is not sentence case and is not written by this project.
  final String? detail;

  /// `Retry-After` from a 429, when the indexer sent a parseable one.
  final Duration? retryAfter;

  final Object? cause;

  bool get isRateLimited => statusCode == HttpStatus.tooManyRequests;

  bool get isUnavailable => statusCode == HttpStatus.serviceUnavailable;

  /// Whether retrying the same request could plausibly work.
  bool get isTransient =>
      statusCode == null ||
      isRateLimited ||
      isUnavailable ||
      statusCode! >= 500;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' ($statusCode)';
    final extra = detail == null ? '' : ': $detail';
    return 'NightjarIndexerException$status: $message$extra';
  }
}

/// Typed client over the Nightjar indexer's HTTP API.
///
/// What this gives the wallet is **data availability, not trust**: message
/// bodies and the verifying key. The indexer cannot forge a balance, because
/// the wallet verifies every proof and recomputes the state itself; it can
/// withhold a message, which is the documented limit of this cut.
///
/// All traffic goes through [NetworkHttpClient] so the process-wide Tor route
/// policy applies. A raw `HttpClient` here would quietly bypass it.
class NightjarIndexerClient {
  NightjarIndexerClient({
    required Uri baseUri,
    NetworkHttpClient? networkClient,
    HttpClient? client,
    this.timeout = const Duration(seconds: 20),
    this.maxAttempts = kNightjarIndexerMaxAttempts,
    Future<void> Function(Duration)? sleep,
  }) : _client = networkClient ?? NetworkHttpClient(directClient: client),
       _ownsClient = networkClient == null,
       _baseUri = baseUri,
       _sleep = sleep ?? _wait;

  final NetworkHttpClient _client;
  final bool _ownsClient;
  final Uri _baseUri;
  final Duration timeout;

  /// How many times one request is attempted before its failure is surfaced.
  /// Only a rate limit, a 503, or a 5xx is retried; see [_retryDelay].
  final int maxAttempts;

  final Future<void> Function(Duration) _sleep;

  static Future<void> _wait(Duration duration) =>
      Future<void>.delayed(duration);

  Uri get baseUri => _baseUri;

  /// `GET /api/status`.
  Future<NightjarIndexerStatus> fetchStatus() async {
    final json = await _getJsonObject(_uri('/api/status'));
    return _decode(() => NightjarIndexerStatus.fromJson(json));
  }

  /// `GET /api/vk` — the verifying key the wallet checks proofs with.
  Future<NightjarVerifyingKey> fetchVerifyingKey() async {
    final json = await _getJsonObject(_uri('/api/vk'));
    return _decode(() => NightjarVerifyingKey.fromJson(json));
  }

  /// `GET /api/block/{height}` — one block header row.
  ///
  /// The only field the wallet reads from it is `time`, which is what turns a
  /// note's creation height into a place on the activity timeline. A block the
  /// indexer does not know about answers 404, which surfaces as the usual
  /// [NightjarIndexerException]; callers that only want a timestamp should
  /// treat that as "no time" rather than as a failure, because a missing
  /// timestamp costs a sort position and nothing else.
  Future<NightjarBlock> fetchBlock(int height) async {
    final json = await _getJsonObject(_uri('/api/block/$height'));
    return _decode(() => NightjarBlock.fromJson(json));
  }

  /// One newest-first page of `GET /api/messages`.
  ///
  /// [before] is the previous page's `nextCursor`. [limit] is clamped to
  /// [kNightjarIndexerMaxLimit] server-side.
  Future<NightjarPage<NightjarMessage>> fetchMessages({
    int limit = kNightjarIndexerMaxLimit,
    int? before,
    bool includeBody = true,
    int? height,
    int? kind,
    String? outcome,
  }) async {
    final json = await _getJsonObject(
      _uri('/api/messages', {
        if (includeBody) 'body': '1',
        'limit': '${_clampLimit(limit)}',
        if (before != null) 'before': '$before',
        if (height != null) 'height': '$height',
        if (kind != null) 'kind': '$kind',
        'outcome': ?outcome,
      }),
    );
    return _decode(() => NightjarPage.fromJson(json, NightjarMessage.fromJson));
  }

  /// Every message in the channel, **in chain order**, each with its body.
  ///
  /// The API is newest-first, so this pages backwards through history and then
  /// turns the result around: the replay is a fold and is only meaningful
  /// oldest-first. See [nightjarMessagesInChainOrder].
  ///
  /// Three things make this a walk rather than a loop, because a replay over
  /// the wrong set of messages produces confident wrong balances rather than
  /// an error:
  ///
  /// * the cursor has to strictly decrease, or the walk is not progressing;
  /// * every row has to be distinct — [nightjarMessagesInChainOrder] drops a
  ///   repeat rather than applying it twice;
  /// * and what is collected at the end has to be as many messages as the
  ///   first page said matched the query. `sum(count) == total` is the
  ///   indexer's own completeness check and this is where it is made.
  Future<List<NightjarMessage>> fetchAllMessages({
    bool includeBody = true,
    int pageLimit = kNightjarIndexerMaxLimit,
    int maxMessages = kNightjarIndexerMaxMessages,
    int? height,
    int? kind,
    String? outcome,
  }) async {
    final collected = <NightjarMessage>[];
    int? cursor;
    var pages = 0;
    // Set on the first page and never again; the walk always runs one.
    var expectedTotal = 0;
    var readTotal = false;

    while (true) {
      final page = await fetchMessages(
        limit: pageLimit,
        before: cursor,
        includeBody: includeBody,
        height: height,
        kind: kind,
        outcome: outcome,
      );
      // `total` ignores the page cursor, so the first page's is the size of
      // the whole result set. Reading it once means a channel that grows
      // mid-walk is measured against the set that was there when it started.
      if (!readTotal) {
        expectedTotal = page.total;
        readTotal = true;
      }
      collected.addAll(page.items);
      pages++;

      if (!page.hasMore) break;

      if (collected.length >= maxMessages) {
        throw NightjarIndexerException(
          message:
              'This channel has more messages than this wallet can load at '
              'once.',
          detail: 'stopped after $maxMessages messages',
        );
      }
      if (pages >= kNightjarIndexerMaxPages) {
        throw const NightjarIndexerException(
          message:
              'This channel has more messages than this wallet can load at '
              'once.',
          detail: 'stopped after $kNightjarIndexerMaxPages pages',
        );
      }
      // The cursor is the last served row's `ord`, so it must strictly
      // decrease. A cursor that stands still would page the same boundary
      // forever, and a page with no rows cannot produce a new one.
      final next = page.nextCursor!;
      if (page.isEmpty || (cursor != null && next >= cursor)) {
        throw const NightjarIndexerException(
          message: kNightjarUnreadableResponseMessage,
          detail: 'the message cursor did not advance',
        );
      }
      cursor = next;
    }

    final ordered = nightjarMessagesInChainOrder(collected);

    if (ordered.length != expectedTotal) {
      throw NightjarIndexerException(
        message:
            'The Nightjar indexer served only part of this channel, so this '
            'wallet cannot replay it.',
        detail:
            'the listing reported $expectedTotal messages and served '
            '${ordered.length}',
      );
    }

    // This call site asks for `body=1`. A row without one is a broken
    // response, not a row to drop: every later note position is derived from
    // the ones before it, so one missing message makes every balance after it
    // wrong with nothing to show for it.
    if (includeBody) {
      for (final message in ordered) {
        if (message.hasBody) continue;
        throw NightjarIndexerException(
          message:
              'The Nightjar indexer served a message without its body, so '
              'this wallet cannot replay the channel.',
          detail: 'message ${message.msgId} at ord ${message.ord} has no body',
        );
      }
    }

    return ordered;
  }

  /// One page of `GET /api/assets`, newest activity first.
  ///
  /// Unlike messages, the assets listing is a fold served by offset: [before]
  /// is the previous page's `nextCursor`, which is a row offset rather than a
  /// key.
  Future<NightjarPage<NightjarAsset>> fetchAssets({
    int limit = kNightjarIndexerMaxLimit,
    int? before,
    int? asOf,
  }) async {
    final json = await _getJsonObject(
      _uri('/api/assets', {
        'limit': '${_clampLimit(limit)}',
        if (before != null) 'before': '$before',
        if (asOf != null) 'as_of': '$asOf',
      }),
    );
    return _decode(() => NightjarPage.fromJson(json, NightjarAsset.fromJson));
  }

  /// Every asset the indexer knows about, in the order it serves them.
  Future<List<NightjarAsset>> fetchAllAssets({
    int pageLimit = kNightjarIndexerMaxLimit,
    int? asOf,
  }) async {
    final collected = <NightjarAsset>[];
    int? cursor;
    var pages = 0;

    while (true) {
      final page = await fetchAssets(
        limit: pageLimit,
        before: cursor,
        asOf: asOf,
      );
      collected.addAll(page.items);
      pages++;

      if (!page.hasMore) break;
      if (pages >= kNightjarIndexerMaxPages) {
        throw const NightjarIndexerException(
          message: 'This channel has more assets than this wallet can load.',
          detail: 'stopped after $kNightjarIndexerMaxPages pages',
        );
      }
      final next = page.nextCursor!;
      if (page.isEmpty || (cursor != null && next <= cursor)) {
        throw const NightjarIndexerException(
          message: kNightjarUnreadableResponseMessage,
          detail: 'the asset cursor did not advance',
        );
      }
      cursor = next;
    }

    return List<NightjarAsset>.unmodifiable(collected);
  }

  void close({bool force = false}) {
    if (_ownsClient) _client.close(force: force);
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final basePath = _baseUri.path.endsWith('/')
        ? _baseUri.path.substring(0, _baseUri.path.length - 1)
        : _baseUri.path;
    return _baseUri.replace(
      path: '$basePath$path',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }

  static int _clampLimit(int limit) => limit < 1
      ? 1
      : (limit > kNightjarIndexerMaxLimit ? kNightjarIndexerMaxLimit : limit);

  /// One GET, retried only where retrying is the right answer.
  Future<Map<String, Object?>> _getJsonObject(Uri uri) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await _getJsonObjectOnce(uri);
      } on NightjarIndexerException catch (error) {
        final delay = _retryDelay(error, attempt);
        if (delay == null) rethrow;
        await _sleep(delay);
      }
    }
  }

  /// How long to wait before attempting [error]'s request again, or null when
  /// it should be surfaced instead.
  ///
  /// A failure with no status never got an answer at all — a timeout or a
  /// dead socket — and retrying that inside one refresh only multiplies the
  /// wait the user already sat through. A rate limit or a busy indexer is
  /// different: it answered, it said when to come back, and honouring that is
  /// cheaper than the user tapping refresh into the same limit.
  Duration? _retryDelay(NightjarIndexerException error, int attempt) {
    if (attempt >= maxAttempts) return null;
    if (error.statusCode == null || !error.isTransient) return null;
    final retryAfter = error.retryAfter;
    if (retryAfter != null) {
      return retryAfter > kNightjarIndexerMaxRetryWait ? null : retryAfter;
    }
    return kNightjarIndexerRetryBackoff * (1 << (attempt - 1));
  }

  Future<Map<String, Object?>> _getJsonObjectOnce(Uri uri) async {
    final NetworkHttpResponse response;
    try {
      response = await _client.request(
        'GET',
        uri,
        headers: const {HttpHeaders.acceptHeader: 'application/json'},
        timeout: timeout,
      );
    } on NightjarIndexerException {
      rethrow;
    } on TimeoutException catch (error) {
      throw NightjarIndexerException(
        message: 'The Nightjar indexer did not answer in time.',
        cause: error,
      );
    } catch (error) {
      throw NightjarIndexerException(
        message: 'Could not reach the Nightjar indexer.',
        cause: error,
      );
    }

    final body = _decodeBodyText(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _httpFailure(response, body);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw NightjarIndexerException(
        message: kNightjarUnreadableResponseMessage,
        statusCode: response.statusCode,
        cause: error,
      );
    }
    if (decoded is! Map) {
      throw NightjarIndexerException(
        message: kNightjarUnreadableResponseMessage,
        statusCode: response.statusCode,
        detail: 'the response is not a JSON object',
      );
    }
    return decoded.cast<String, Object?>();
  }

  /// Runs a model decoder and converts its [FormatException] into the typed
  /// error. Model messages are already sentence case and user-facing.
  static T _decode<T>(T Function() decode) {
    try {
      return decode();
    } on FormatException catch (error) {
      throw NightjarIndexerException(
        message: error.message.isEmpty
            ? kNightjarUnreadableResponseMessage
            : error.message,
        cause: error,
      );
    }
  }

  static String _decodeBodyText(NetworkHttpResponse response) {
    try {
      return utf8.decode(response.bodyBytes);
    } on FormatException {
      return '';
    }
  }

  static NightjarIndexerException _httpFailure(
    NetworkHttpResponse response,
    String body,
  ) {
    // Errors come back as `{"error": "..."}` on the handlers that produce
    // them, but the router's own 404 has an empty body, so the detail is
    // optional rather than assumed.
    String? detail;
    if (body.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['error'] is String) {
          detail = decoded['error'] as String;
        }
      } on FormatException {
        detail = null;
      }
    }

    return NightjarIndexerException(
      message: _messageForStatus(response.statusCode),
      statusCode: response.statusCode,
      detail: detail,
      retryAfter: _retryAfter(response),
    );
  }

  static String _messageForStatus(int statusCode) {
    return switch (statusCode) {
      HttpStatus.badRequest => 'The Nightjar indexer rejected this request.',
      HttpStatus.notFound =>
        'The Nightjar indexer does not have what this wallet asked for.',
      HttpStatus.tooManyRequests =>
        'The Nightjar indexer is rate limiting this wallet. Try again in a '
            'moment.',
      HttpStatus.serviceUnavailable =>
        'The Nightjar indexer is busy. Try again in a moment.',
      _ when statusCode >= 500 =>
        'The Nightjar indexer failed to answer. Try again in a moment.',
      _ => 'The Nightjar indexer returned an unexpected response.',
    };
  }

  /// `Retry-After` in seconds. The delta-seconds form is the only one the
  /// indexer sends; an HTTP-date is ignored rather than guessed at.
  static Duration? _retryAfter(NetworkHttpResponse response) {
    final raw = response.header(HttpHeaders.retryAfterHeader)?.trim();
    if (raw == null || raw.isEmpty) return null;
    final seconds = int.tryParse(raw);
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds);
  }
}
