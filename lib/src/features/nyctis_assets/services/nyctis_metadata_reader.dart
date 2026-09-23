/// Reading **one** resource under section 3.2 of `spec/asset-metadata-v0.md`:
/// the limits, the single request budget, and the redirect rule.
///
/// This was inside `nyctis_metadata_fetcher.dart` until the collection
/// document of `spec/asset-collection-v0.md` needed the same reader. It is
/// split out rather than copied for a reason that is not tidiness: the rules
/// here are the ones a second implementation gets subtly wrong. The redirect
/// comparison is against **the origin the fetch started at** and not the
/// previous hop (section 2), the budget is one clock for the whole request and
/// not one per phase (section 3.2), and over-the-limit is *absent* rather than
/// an error worth showing. A collection document fetched through a second
/// reader would be a second chance to get each of those backwards.
///
/// Nothing here knows what a document is. It returns bytes or a named refusal,
/// and the callers above decide what the bytes were supposed to be.
library;

import 'dart:async';
import 'dart:typed_data';

import 'nyctis_metadata_transport.dart';

/// Section 3.2. A metadata document that needs more than this is not a
/// metadata document.
///
/// It binds the collection document too, and `asset-collection-v0.md` section
/// 3.4 is explicit that it must: a publisher whose `items` will not fit
/// **MUST** use the per-piece form rather than have a wallet raise the limit,
/// because raising it would mean buffering more before a wallet can refuse.
const int kNyctisDocumentMaxBytes = 16 * 1024;

/// Section 3.2. Bounded so a wallet can refuse before decoding. The same bound
/// applies to a collection member's artwork: `asset-collection-v0.md` section
/// 3.2 defers to `asset-metadata-v0.md` section 2 for "scheme, redirects,
/// limits", and nothing about there being a hundred of them makes any one
/// bigger.
const int kNyctisLogoMaxBytes = 256 * 1024;

/// Section 3.2. Documents may reference several images.
const int kNyctisAssetTotalMaxBytes = 512 * 1024;

/// Section 3.2 writes this as "connect + read, 10 s each".
///
/// It is applied here as a 10 s budget for the *whole* request, connect
/// included, which is stricter than the spec asks. `NetworkHttpClient` takes
/// one timeout for a request and charges redirects against it, and splitting
/// it would mean either passing 20 s — twice what an unreachable host is
/// allowed to cost a balance screen — or inventing a second clock the
/// transport cannot see.
const Duration kNyctisMetadataTimeout = Duration(seconds: 10);

/// Section 3.2: 3 redirects, same origin.
const int kNyctisMetadataMaxRedirects = 3;

/// Why a fetch produced nothing. Diagnostics: none of these is user-facing
/// copy, and none of them is rendered as a failure.
enum NyctisMetadataAbandonReason {
  /// The `uri` was not one this wallet resolves — absent, `http:`, `ipfs:`,
  /// `data:`, over 255 bytes, or carrying a `#b2=` that cannot be a digest.
  pointerRefused,

  /// A redirect left the origin the fetch started at, or there were more than
  /// [kNyctisMetadataMaxRedirects] of them.
  redirectRefused,

  /// Not 2xx.
  httpStatus,

  /// Over the section 3.2 limit for its kind.
  tooLarge,

  /// Connect or read ran past [kNyctisMetadataTimeout].
  timedOut,

  /// The host could not be reached, TLS failed, or the route is down.
  transport,

  /// The bytes did not hash to the `#b2=`, `b2` or `digests[i]` they were
  /// pinned with. Section 2.1 of `asset-metadata-v0.md` and section 3.3 of
  /// `asset-collection-v0.md`: discarded, and **not** retried from a different
  /// source.
  digestMismatch,

  /// Not JSON, not an object, not UTF-8, or a `schema` this revision does not
  /// recognize. Section 4.4 makes the last one a rejection rather than a
  /// best-effort read.
  documentRefused,

  /// The document resolved to no image for this piece: no `item.image`, a
  /// substituted template that is not an `https:` URI, or one still carrying a
  /// token this specification never defined. `asset-collection-v0.md` section
  /// 3.2 makes this *the piece* having no artwork, never the collection being
  /// invalid.
  noImage,

  /// Bytes arrived and were not a format this wallet draws — `image/svg+xml`,
  /// which section 4.2 refuses by name, or anything that is not PNG, JPEG or
  /// WebP.
  imageFormatRefused,

  /// A PNG, JPEG or WebP whose header declares more pixels than this wallet
  /// will decode (`kNyctisImageMaxPixels`), or whose header could not be
  /// read. The engine decodes a PNG at full size before it scales it, so a
  /// small file declaring a huge canvas is a memory cost paid on draw.
  imageDimensionsRefused,

  /// The host answered with a compressed body (`Content-Encoding` other than
  /// `identity`). Refused unread: the wallet asks for `identity`, and a small
  /// compressed body can inflate past any size limit before the limit is
  /// checked.
  encodingRefused,
}

/// The per-asset total from section 3.2, spent across every resource one
/// document pulls in.
class NyctisResourceBudget {
  NyctisResourceBudget([this.remaining = kNyctisAssetTotalMaxBytes]);

  int remaining;

  bool take(int bytes) {
    if (bytes > remaining) return false;
    remaining -= bytes;
    return true;
  }
}

/// What the reader has put on the wire, across every request it has made.
///
/// Counted per request and per byte *received*, refusals included. A caller
/// that spends a budget across many fetches — the collection warm-up — has to
/// charge what the network actually carried, not what was kept: a host that
/// serves every image one byte over the limit costs the full limit each time,
/// and a budget that counted only accepted bytes would never run out.
class NyctisFetchTraffic {
  int _requests = 0;
  int _bytesReceived = 0;

  /// Transport calls made, one per hop, whatever they returned.
  int get requests => _requests;

  /// Body bytes that arrived, whether they were kept or refused.
  int get bytesReceived => _bytesReceived;

  void _record(int bytes) {
    _requests++;
    _bytesReceived += bytes;
  }
}

/// Bytes, or the reason there are none.
class NyctisReadResult {
  const NyctisReadResult.bytes(Uint8List this.bytes) : reason = null;

  const NyctisReadResult.abandoned(NyctisMetadataAbandonReason this.reason)
    : bytes = null;

  final Uint8List? bytes;
  final NyctisMetadataAbandonReason? reason;
}

/// One resource at a time, over the origin-guarded transport.
class NyctisMetadataReader {
  NyctisMetadataReader({
    NyctisMetadataTransport? transport,
    this.maxRedirects = kNyctisMetadataMaxRedirects,
    this.timeout = kNyctisMetadataTimeout,
    NyctisFetchTraffic? traffic,
  }) : transport = transport ?? const NyctisPrivacyTransport(),
       traffic = traffic ?? NyctisFetchTraffic();

  /// Everything this reader has requested and received.
  final NyctisFetchTraffic traffic;

  /// Always a [NyctisMetadataTransport] and never a raw `HttpClient`.
  /// Section 3.1: a fetch discloses interest, so it **MUST** go through the
  /// wallet's privacy transport when it has one. A raw client here would send
  /// the request straight out of the user's own IP while the settings screen
  /// said otherwise.
  final NyctisMetadataTransport transport;

  final int maxRedirects;
  final Duration timeout;

  /// Reads [start], following at most [maxRedirects] same-origin redirects.
  Future<NyctisReadResult> read(
    Uri start, {
    required int maxBytes,
    required String accept,
    required NyctisResourceBudget budget,
  }) async {
    var uri = start;
    for (var hop = 0; ; hop++) {
      if (hop > maxRedirects) {
        return const NyctisReadResult.abandoned(
          NyctisMetadataAbandonReason.redirectRefused,
        );
      }
      // The most this hop may read: the per-kind limit, or what is left of
      // the per-asset total if that is less. Passed down so the transport can
      // stop reading at it rather than measure after buffering everything.
      final cap = maxBytes < budget.remaining ? maxBytes : budget.remaining;
      final NyctisHttpReply reply;
      try {
        reply = await transport.get(
          uri,
          timeout: timeout,
          headers: {'accept': accept},
          maxBytes: cap,
        );
      } on NyctisResponseTooLargeException catch (error) {
        traffic._record(error.receivedBytes);
        return const NyctisReadResult.abandoned(
          NyctisMetadataAbandonReason.tooLarge,
        );
      } on NyctisCompressedResponseException {
        traffic._record(0);
        return const NyctisReadResult.abandoned(
          NyctisMetadataAbandonReason.encodingRefused,
        );
      } on NyctisCrossOriginRedirectException {
        // On the Tor route the hop that *answered* with the redirect was a
        // real request, so it is charged like any other.
        traffic._record(0);
        return const NyctisReadResult.abandoned(
          NyctisMetadataAbandonReason.redirectRefused,
        );
      } on TimeoutException {
        traffic._record(0);
        return const NyctisReadResult.abandoned(
          NyctisMetadataAbandonReason.timedOut,
        );
      } catch (_) {
        traffic._record(0);
        return const NyctisReadResult.abandoned(
          NyctisMetadataAbandonReason.transport,
        );
      }
      traffic._record(reply.body.length);

      if (reply.isRedirect) {
        final location = reply.location;
        if (location == null) {
          return const NyctisReadResult.abandoned(
            NyctisMetadataAbandonReason.httpStatus,
          );
        }
        final next = uri.resolve(location);
        // Section 2: a different origin is refused, not followed. Compared
        // against where the fetch *started*, not against the previous hop, so
        // a chain cannot walk somewhere one hop at a time.
        if (next.scheme != 'https' || !nyctisSameOrigin(start, next)) {
          return const NyctisReadResult.abandoned(
            NyctisMetadataAbandonReason.redirectRefused,
          );
        }
        uri = next;
        continue;
      }

      if (!reply.isOk) {
        return const NyctisReadResult.abandoned(
          NyctisMetadataAbandonReason.httpStatus,
        );
      }
      // Section 3.2: over the limit is *absent*, not an error worth showing.
      // Checked again here for a transport that returned the whole body
      // rather than streaming to the cap.
      if (reply.body.length > cap || !budget.take(reply.body.length)) {
        return const NyctisReadResult.abandoned(
          NyctisMetadataAbandonReason.tooLarge,
        );
      }
      return NyctisReadResult.bytes(reply.body);
    }
  }
}

/// Scheme, host and port, case-folded — the comparison section 2 of
/// `asset-metadata-v0.md` requires a redirect to survive.
bool nyctisSameOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;
