/// The `uri` of an `ASSET` message, read as a pointer at a metadata document
/// (`spec/asset-metadata-v0.md` section 2).
///
/// The signature on an `ASSET` message covers the **pointer**, not the bytes
/// at the end of it (section 2.1). An issuer who signs today and loses the
/// domain tomorrow has signed whatever the new owner serves — which is why a
/// pointer that carries a `#b2=` digest is worth more than one that does not,
/// and why this type makes the difference impossible to ignore.
library;

import 'nightjar_asset_metadata.dart';

/// Section 2: at most 255 bytes of US-ASCII
/// (`crates/nightjar-codec/src/asset.rs`, `MAX_URI`).
///
/// 255 is the ceiling of the wire format rather than a chosen number —
/// `uri_len` is a `u8`, so nothing larger can be expressed at all — which is
/// why this constant can be written down here without the two copies drifting
/// the way a *preference* would. A `uri` this wallet refuses is one it will not
/// **fetch**; the signed name, symbol and decimals still render, because those
/// came from the channel and not from the document.
const int kNightjarUriMaxBytes = 255;

/// Why a `uri` is not one this wallet will resolve. Every value here is a
/// refusal to *fetch*, never a fault in the asset: the signed name and symbol
/// still render and the balance is still the balance.
enum NightjarPointerRejection {
  /// Empty, or whitespace only. The normal state for an asset whose issuer
  /// published no document.
  absent,

  /// Longer than [kNightjarUriMaxBytes], or not US-ASCII.
  malformed,

  /// `http:`. Section 2 makes this a MUST reject.
  insecureScheme,

  /// `ipfs:`, which section 2 permits a wallet to accept. This one does not:
  /// it has no gateway, and resolving through somebody's public HTTPS gateway
  /// would disclose the fetch to a host neither the issuer nor the user chose.
  unsupportedScheme,

  /// `data:`, `file:`, or anything else. Section 2 makes this a MUST reject.
  forbiddenScheme,

  /// A `#b2=` fragment that is not 43 base64url characters. A pin that can
  /// never match is not the same as no pin: section 2.1 says a document that
  /// does not match the fragment is discarded, and this one never could.
  malformedDigest,
}

/// A `uri` this wallet will resolve, and the digest that pins what comes back.
class NightjarMetadataPointer {
  const NightjarMetadataPointer({
    required this.requestUri,
    required this.digestB2,
  });

  /// The URI to request: the pointer with its fragment removed. Fragments are
  /// not sent on the wire anyway; dropping it here keeps the cache key and
  /// the request from disagreeing.
  final Uri requestUri;

  /// `BLAKE2b-256` of the document's exact bytes, base64url unpadded, or null
  /// for an unpinned pointer.
  final String? digestB2;

  /// Section 2.1: an unpinned document is not invalid, it is revocable by
  /// someone who is not the issuer — and a wallet SHOULD say so wherever it
  /// says where the metadata came from.
  bool get isPinned => digestB2 != null;

  /// `example.invalid` — the host that learns about a fetch.
  String get origin => nightjarUriOrigin(requestUri);

  @override
  String toString() => 'NightjarMetadataPointer($requestUri, pinned=$isPinned)';
}

/// The outcome of reading one `uri`: a pointer, or the reason there is none.
class NightjarPointerResult {
  const NightjarPointerResult.pointer(NightjarMetadataPointer this.pointer)
    : rejection = null;

  const NightjarPointerResult.rejected(NightjarPointerRejection this.rejection)
    : pointer = null;

  final NightjarMetadataPointer? pointer;
  final NightjarPointerRejection? rejection;

  bool get isResolvable => pointer != null;
}

/// Reads the `uri` of an `ASSET` message.
///
/// Never throws: every input is either a pointer or a named refusal, because
/// the caller's only reasonable response to a bad one is to draw the asset
/// without decoration.
NightjarPointerResult readNightjarMetadataUri(String? raw) {
  final trimmed = (raw ?? '').trim();
  if (trimmed.isEmpty) {
    return const NightjarPointerResult.rejected(
      NightjarPointerRejection.absent,
    );
  }
  if (trimmed.length > kNightjarUriMaxBytes) {
    return const NightjarPointerResult.rejected(
      NightjarPointerRejection.malformed,
    );
  }
  for (final unit in trimmed.codeUnits) {
    if (unit < 0x21 || unit > 0x7E) {
      return const NightjarPointerResult.rejected(
        NightjarPointerRejection.malformed,
      );
    }
  }

  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) {
    return const NightjarPointerResult.rejected(
      NightjarPointerRejection.malformed,
    );
  }
  switch (uri.scheme.toLowerCase()) {
    case 'https':
      break;
    case 'http':
      return const NightjarPointerResult.rejected(
        NightjarPointerRejection.insecureScheme,
      );
    case 'ipfs':
      return const NightjarPointerResult.rejected(
        NightjarPointerRejection.unsupportedScheme,
      );
    default:
      return const NightjarPointerResult.rejected(
        NightjarPointerRejection.forbiddenScheme,
      );
  }
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return const NightjarPointerResult.rejected(
      NightjarPointerRejection.malformed,
    );
  }

  String? digest;
  final fragment = uri.fragment;
  if (fragment.startsWith('b2=')) {
    final candidate = fragment.substring(3);
    if (!isNightjarB2Digest(candidate)) {
      return const NightjarPointerResult.rejected(
        NightjarPointerRejection.malformedDigest,
      );
    }
    digest = candidate;
  }

  return NightjarPointerResult.pointer(
    NightjarMetadataPointer(requestUri: uri.removeFragment(), digestB2: digest),
  );
}
