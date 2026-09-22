/// The state one piece of artwork can be in, as a tile has to draw it.
///
/// This type exists because the tile used to have one empty state — "Not
/// fetched" — and that single string collapsed at least three different
/// situations: a piece the user had never accepted, a piece whose fetch was in
/// flight, and a piece whose image the wallet had fetched and *refused*. The
/// collapse is what made a missing collection-metadata implementation look
/// like a missing image: every tile said the same thing, so nothing on screen
/// distinguished "we never asked" from "we asked and threw the answer away".
///
/// Two of the five states are the ones the specification cares about by name:
///
/// * [NightjarArtworkStatus.verified] and [NightjarArtworkStatus.unpinned] are
///   both a drawn picture, and `spec/asset-collection-v0.md` section 3.3 says
///   they must not look the same. A missing or short `digests` array leaves
///   those pieces **unpinned, not invalid**, and a wallet **SHOULD** say so
///   where it says where the artwork came from. That sentence is the entire
///   value of the digest: if the UI cannot tell them apart, publishing
///   `digests` bought the user nothing.
/// * [NightjarArtworkStatus.refused] is the one that must never be silent. A
///   digest mismatch is a host serving something other than what the issuer
///   signed for (section 3.3, and `asset-metadata-v0.md` section 2.1), and it
///   is discarded **without retrying**. Rendering that as "not fetched" would
///   describe an attack as a slow network.
///
/// Nothing here is a *reason to show an error*. `asset-metadata-v0.md` section
/// 3.2 still holds: a document or an image that fails is absent, the asset is
/// still an asset, and the signed `name` and `symbol` still render. These
/// states change what the empty frame says, not whether the piece exists.
library;

import 'dart:typed_data';

import '../services/nightjar_metadata_fetcher.dart';

/// Which of the five states a piece's artwork is in.
enum NightjarArtworkStatus {
  /// The user has not accepted this `asset_id`.
  ///
  /// `asset-metadata-v0.md` section 5: a wallet **MUST NOT** display a logo
  /// for an asset the user has not explicitly accepted. Nothing has been
  /// fetched and nothing will be — section 3.1 makes acceptance the trigger,
  /// and holding the piece is explicitly not one.
  notAccepted,

  /// Accepted, and the answer has not arrived yet.
  pending,

  /// Bytes arrived and matched the digest that pins them — `digests[index]`
  /// for a collection member (section 3.3), `logo.b2` for a lone asset
  /// (`asset-metadata-v0.md` section 4.2).
  verified,

  /// Bytes arrived and nothing pinned them.
  ///
  /// Not an error and not a failure: section 3.3 calls these pieces
  /// **unpinned, not invalid**. What it means is that whoever holds the host
  /// today can change the picture, and the issuer's signature would not
  /// notice.
  unpinned,

  /// The wallet would not keep what the host served: a digest mismatch, an
  /// image over 256 KiB, an SVG, a scheme that is not `https:`, a cross-origin
  /// redirect, or a host that could not be reached.
  refused,
}

/// One piece's artwork, and how much the wallet is prepared to claim about it.
class NightjarArtworkData {
  const NightjarArtworkData({
    required this.status,
    this.bytes,
    this.reason,
    this.sourceOrigin,
    this.documentPinned = false,
  });

  /// The state before acceptance, and the default a fixture gets.
  const NightjarArtworkData.notAccepted()
    : status = NightjarArtworkStatus.notAccepted,
      bytes = null,
      reason = null,
      sourceOrigin = null,
      documentPinned = false;

  const NightjarArtworkData.pending()
    : status = NightjarArtworkStatus.pending,
      bytes = null,
      reason = null,
      sourceOrigin = null,
      documentPinned = false;

  final NightjarArtworkStatus status;

  /// Verified `image/png`, `image/jpeg` or `image/webp` bytes, or null.
  ///
  /// Non-null exactly when [status] is [NightjarArtworkStatus.verified] or
  /// [NightjarArtworkStatus.unpinned]. Whoever set it has already checked
  /// acceptance; a widget cannot, and must not try.
  final Uint8List? bytes;

  /// Why there are no bytes, when [status] is
  /// [NightjarArtworkStatus.refused]. Diagnostic — the copy a tile shows is
  /// chosen from [status], not from this.
  final NightjarMetadataAbandonReason? reason;

  /// The host the document came from, e.g. `raw.githubusercontent.com`.
  ///
  /// Section 3.3 ties the pinned/unpinned distinction to "where it says where
  /// the artwork came from", so the two travel together rather than the origin
  /// living somewhere a redesign can drop independently.
  final String? sourceOrigin;

  /// Whether the *document* was pinned by the signed `uri`'s `#b2=`.
  ///
  /// Separate from the image's own pin, and both matter: section 3.3's chain
  /// is `uri` signed → `#b2=` pins the document → `digests` pins the images.
  /// A verified image under an unpinned document is pinned to a document
  /// whoever holds the host could replace.
  final bool documentPinned;

  /// Whether a picture is drawn.
  bool get hasImage => bytes != null;

  /// Whether the picture's bytes are fixed by something the issuer signed.
  bool get isPinned => status == NightjarArtworkStatus.verified;

  /// Builds the state from a fetch that has answered.
  ///
  /// The `outcome` is whichever document shape the `uri` pointed at — the
  /// per-asset document of `asset-metadata-v0.md` or the collection document
  /// of `asset-collection-v0.md`. Both reduce to the same five states here,
  /// which is the point: a member of a collection and a lone asset are drawn
  /// by the same widget and owe the user the same sentence.
  factory NightjarArtworkData.fromOutcome(NightjarArtworkFetchOutcome outcome) {
    final bytes = outcome.imageBytes;
    if (bytes != null) {
      return NightjarArtworkData(
        status: outcome.imagePinned
            ? NightjarArtworkStatus.verified
            : NightjarArtworkStatus.unpinned,
        bytes: bytes,
        sourceOrigin: _origin(outcome),
        documentPinned: _documentPinned(outcome),
      );
    }
    return NightjarArtworkData(
      status: NightjarArtworkStatus.refused,
      reason: _reason(outcome),
      sourceOrigin: _origin(outcome),
      documentPinned: _documentPinned(outcome),
    );
  }

  static String? _origin(NightjarArtworkFetchOutcome outcome) =>
      outcome.assetView?.sourceOrigin ?? outcome.memberView?.sourceOrigin;

  static bool _documentPinned(NightjarArtworkFetchOutcome outcome) =>
      (outcome.assetView?.documentPinned ?? false) ||
      (outcome.memberView?.documentPinned ?? false);

  /// The reason nearest the failure.
  ///
  /// A collection member whose document parsed and whose *image* was refused
  /// carries the reason on the member rather than on the outcome, because the
  /// document itself succeeded — section 3.2 of `asset-collection-v0.md` makes
  /// a bad image the piece's problem and not the collection's.
  static NightjarMetadataAbandonReason? _reason(
    NightjarArtworkFetchOutcome outcome,
  ) =>
      outcome.memberView?.imageReason ??
      outcome.reason ??
      // An asset document that parsed but carried no usable logo. The fetcher
      // does not keep a per-logo reason on the asset path, and `noImage` is
      // the honest summary: there was nothing to draw.
      (outcome.assetView != null
          ? NightjarMetadataAbandonReason.noImage
          : null);
}

/// Where a collection's picture came from.
///
/// Two values, and the distinction is a MUST rather than a nicety. Section
/// 3.5.1: a wallet that falls back to a member's artwork **MUST** mark it as
/// derived rather than declared "wherever it says where a picture came from",
/// for the reason the unpinned badge exists — a declared `logo` is a statement
/// by the issuer about the collection, a derived face is this wallet's
/// inference from one piece, and once drawn the two are the same picture.
enum NightjarCollectionArtworkSource {
  /// The document carried a `logo` (section 3.5) and these are its bytes.
  declared,

  /// The document carried none, so this is [NightjarCollectionArtworkData
  /// .derivedFromIndex]'s own artwork standing in (section 3.5.1).
  derived,
}

/// A collection's face, and how much the wallet is prepared to claim about it.
class NightjarCollectionArtworkData {
  const NightjarCollectionArtworkData({
    required this.artwork,
    this.source,
    this.derivedFromIndex,
    this.declaredLogoRefused = false,
  });

  /// The state before any member is accepted, and the default a fixture gets.
  ///
  /// Section 3.5: a wallet **MUST NOT** fetch or display a collection `logo`
  /// before the user has accepted at least one member, so "nothing accepted"
  /// is not a loading state — it is the answer.
  const NightjarCollectionArtworkData.notAccepted()
    : artwork = const NightjarArtworkData.notAccepted(),
      source = null,
      derivedFromIndex = null,
      declaredLogoRefused = false;

  const NightjarCollectionArtworkData.pending()
    : artwork = const NightjarArtworkData.pending(),
      source = null,
      derivedFromIndex = null,
      declaredLogoRefused = false;

  /// The picture and its five states, exactly as a piece's — the same type on
  /// purpose, so that "verified", "unpinned" and "refused" mean here what they
  /// mean on a tile and a redesign cannot give a collection a sixth state.
  final NightjarArtworkData artwork;

  /// Null when there is no picture.
  final NightjarCollectionArtworkSource? source;

  /// The **on-chain** index of the member the face was taken from, when
  /// [source] is [NightjarCollectionArtworkSource.derived].
  ///
  /// Carried so the copy can name the piece rather than say "a piece": a
  /// derived face the user cannot trace back to a member is a marking that
  /// says something happened without saying what.
  final int? derivedFromIndex;

  /// Whether the document declared a `logo` and the wallet would not keep it
  /// — a digest mismatch, an SVG, an image over 256 KiB, a host that refused.
  ///
  /// Separate from "there was none", and for the reason the five tile states
  /// are five rather than two: "this collection published no artwork" and "the
  /// wallet fetched the artwork this collection published and threw it away"
  /// are different facts, and reporting the second as the first describes a
  /// host serving something the issuer never signed for as an omission.
  final bool declaredLogoRefused;

  bool get hasImage => artwork.hasImage;

  bool get isDerived => source == NightjarCollectionArtworkSource.derived;
}

