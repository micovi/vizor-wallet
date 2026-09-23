/// Fetching a metadata document, under section 3 of
/// `spec/asset-metadata-v0.md` and section 5 of `spec/asset-collection-v0.md`.
///
/// **A fetch discloses interest, and interest is close to holding.** Every
/// other part of Nyctis is built so that holders are invisible; a wallet
/// that asks `example.invalid` for `gold.json` has just told that host that
/// someone, at that address, at that moment, is looking at that asset. On a
/// channel carrying a handful of assets that request is close to identifying,
/// and it is made by the one participant the whole design is for.
///
/// So this class is deliberately hard to trigger:
///
/// * it takes an `assetId`, a `uri` and — for a collection member — an
///   `index`, and no view, no balance and no note. There is nothing here for
///   "fetch the ones we hold" to be written against, which is the
///   implementation section 3.1 exists to forbid, and `asset-collection-v0.md`
///   section 5 sharpens rather than relaxes for a collection: the pattern of
///   requests would otherwise disclose which pieces are held;
/// * every caller in this feature is behind [NyctisAssetAcceptance], and
///   acceptance is a button a user presses;
/// * results are cached for the life of the object, successes *and* refusals,
///   so a rebuild is not a second request and a dead host is not a heartbeat.
///
/// **The collection document is fetched once for the whole collection.** That
/// is the point of the shared form (`asset-collection-v0.md` section 2), and
/// it only holds if the cache is keyed by the *document* rather than by the
/// asset — so [_documents] is keyed by the pointer and [_cache] by the asset,
/// and forty accepted pieces of one collection make one document request
/// between them.
///
/// Every failure is an **abandonment**, never an error the screen shows.
/// Section 3.2 is explicit: a document that exceeds a limit is treated as
/// absent, because the asset is still an asset and the signed `name` and
/// `symbol` still render. The reason is kept for logs, for tests, and — new
/// here — for a tile that has to distinguish "not fetched" from "refused"; it
/// is still not copy.
library;

import 'dart:async';
import 'dart:typed_data';

import '../models/nyctis_asset_metadata.dart';
import '../models/nyctis_collection_metadata.dart';
import '../models/nyctis_metadata_pointer.dart';
import 'nyctis_image_format.dart';
import 'nyctis_metadata_digest.dart';
import 'nyctis_metadata_reader.dart';
import 'nyctis_metadata_transport.dart';

export 'nyctis_metadata_reader.dart'
    show
        NyctisFetchTraffic,
        NyctisMetadataAbandonReason,
        kNyctisAssetTotalMaxBytes,
        kNyctisDocumentMaxBytes,
        kNyctisLogoMaxBytes,
        kNyctisMetadataMaxRedirects,
        kNyctisMetadataTimeout;

/// The `accept` header sent for an image. Advisory: section 4.2 requires the
/// format to be determined from the bytes, so nothing downstream believes it.
const String _imageAccept = 'image/png, image/jpeg, image/webp';

/// What the UI is allowed to draw once the user has accepted an asset.
class NyctisAssetMetadataView {
  const NyctisAssetMetadataView({
    required this.assetId,
    required this.metadata,
    required this.documentPinned,
    required this.sourceOrigin,
    this.logoBytes,
    this.logoPinned = false,
  });

  /// The asset this decorates. Carried so that a caller cannot hold a logo
  /// without the one value section 5 requires beside it.
  final String assetId;

  final NyctisAssetMetadata metadata;

  /// Whether the document's bytes were pinned by the signed `uri`'s `#b2=`.
  /// An unpinned document is not invalid; it is revocable by someone who is
  /// not the issuer, and the UI says so.
  final bool documentPinned;

  /// The host the document came from, e.g. `example.invalid`.
  final String sourceOrigin;

  /// Verified `image/png`, `image/jpeg` or `image/webp` bytes, or null when
  /// there was no logo, it was refused, or it did not arrive.
  final Uint8List? logoBytes;

  /// Whether those bytes matched a `logo.b2`.
  final bool logoPinned;

  bool get hasLogo => logoBytes != null;

  /// Everything a metadata document can contribute, or nothing.
  bool get isEmpty => metadata.isEmpty && logoBytes == null;
}

/// One member of a collection, resolved against its on-chain index and fetched
/// (`spec/asset-collection-v0.md`).
///
/// It carries the whole collection document beside the one member, because the
/// surfaces that draw a piece also draw the collection's name and links, and
/// re-parsing 6 KiB of JSON per tile to reach them would undo the point of
/// fetching it once.
class NyctisCollectionMemberView {
  const NyctisCollectionMemberView({
    required this.assetId,
    required this.index,
    required this.collection,
    required this.member,
    required this.documentPinned,
    required this.sourceOrigin,
    this.imageBytes,
    this.imageReason,
    this.collectionLogoBytes,
    this.collectionLogoPinned = false,
  });

  /// The asset this decorates — section 5 of `asset-metadata-v0.md` again:
  /// a wallet **MUST** show `asset_id` wherever it shows a picture, and a grid
  /// of a hundred pictures under a hundred names is the surface that rule is
  /// most worth keeping.
  final String assetId;

  /// The **on-chain** index this was resolved for. Not a document member: it
  /// is hashed into [assetId] through `terms`, which is why the shared form is
  /// safe at all (`asset-collection-v0.md` section 1).
  final int index;

  final NyctisCollectionMetadata collection;

  /// The template resolved for [index].
  final NyctisCollectionMember member;

  /// Whether the collection document's bytes were pinned by the signed `uri`'s
  /// `#b2=`. One signature over the `uri`, plus `#b2=` over the document, plus
  /// `digests` over every image, is what section 3.3 means by "one signature,
  /// transitively, fixes all hundred pieces".
  final bool documentPinned;

  final String sourceOrigin;

  /// Verified image bytes, or null.
  final Uint8List? imageBytes;

  /// Why there are none, when there are none. Null when [imageBytes] is set.
  final NyctisMetadataAbandonReason? imageReason;

  /// The **collection's** own picture (`asset-collection-v0.md` section 3.5),
  /// or null when the document declared none, it was refused, or it did not
  /// arrive.
  ///
  /// It rides on the member view rather than on a view of its own because the
  /// document does: a collection is not a thing a wallet can fetch on its own
  /// terms — there is no "the collection" to request, only a document that
  /// several members' `uri`s name. It is fetched once per document and shared,
  /// so forty accepted pieces of one collection do not make forty requests for
  /// one picture.
  ///
  /// Null is the ordinary case for now. Section 3.5.1's fallback is not
  /// applied here: choosing a member's artwork to stand in for a collection
  /// needs the acceptance record, and nothing in this file is allowed to see
  /// one.
  final Uint8List? collectionLogoBytes;

  /// Whether those bytes matched the `logo.b2` the document published for
  /// them. Section 3.5: absent is **unpinned, not invalid**, on the same terms
  /// as a piece with no `digests` entry, and the UI says which.
  final bool collectionLogoPinned;

  bool get hasImage => imageBytes != null;

  bool get hasCollectionLogo => collectionLogoBytes != null;

  /// Whether these exact bytes matched `digests[index]`.
  ///
  /// The distinction from [isUnpinned] is the entire value of the array
  /// (section 3.3), so it is exposed rather than collapsed into "we have a
  /// picture".
  bool get imagePinned => imageBytes != null && member.isPinned;

  /// Bytes arrived and nothing pinned them: the piece is **unpinned, not
  /// invalid**, and section 3.3 says a wallet SHOULD say so where it says
  /// where the artwork came from.
  bool get isUnpinned => imageBytes != null && !member.isPinned;
}

/// A fetch that produced a document, or the reason it produced none.
class NyctisMetadataFetchOutcome {
  const NyctisMetadataFetchOutcome.fetched(NyctisAssetMetadataView this.view)
    : reason = null;

  const NyctisMetadataFetchOutcome.abandoned(
    NyctisMetadataAbandonReason this.reason,
  ) : view = null;

  final NyctisAssetMetadataView? view;
  final NyctisMetadataAbandonReason? reason;

  bool get hasView => view != null;
}

/// The two document shapes a `uri` can point at, plus the refusal.
///
/// One type rather than two call sites, because a wallet cannot know which
/// shape it is going to get until the bytes arrive: the per-asset document of
/// `asset-metadata-v0.md` and the collection document of
/// `asset-collection-v0.md` are both "the thing at the end of an `ASSET`
/// message's `uri`", and section 4 of `asset-collection-v0.md` makes a
/// collection member point at either one depending on how large the collection
/// is. The `schema` member decides, and it decides after the fetch.
class NyctisArtworkFetchOutcome {
  const NyctisArtworkFetchOutcome.asset(NyctisAssetMetadataView this.assetView)
    : memberView = null,
      reason = null;

  const NyctisArtworkFetchOutcome.collectionMember(
    NyctisCollectionMemberView this.memberView,
  ) : assetView = null,
      reason = null;

  const NyctisArtworkFetchOutcome.abandoned(
    NyctisMetadataAbandonReason this.reason,
  ) : assetView = null,
      memberView = null;

  /// Set when the document was an `asset-metadata-v0.md` one.
  final NyctisAssetMetadataView? assetView;

  /// Set when it was an `asset-collection-v0.md` one and an index was given.
  final NyctisCollectionMemberView? memberView;

  final NyctisMetadataAbandonReason? reason;

  /// The picture to draw, whichever document produced it.
  Uint8List? get imageBytes => assetView?.logoBytes ?? memberView?.imageBytes;

  /// Whether that picture's exact bytes matched a digest the signed `uri`
  /// transitively pins — `logo.b2` for an asset, `digests[index]` for a
  /// collection member.
  bool get imagePinned =>
      (assetView?.logoPinned ?? false) || (memberView?.imagePinned ?? false);

  bool get hasImage => imageBytes != null;
}

/// Fetches and verifies one asset's artwork, once.
class NyctisAssetMetadataFetcher {
  NyctisAssetMetadataFetcher({
    NyctisMetadataTransport? transport,
    int maxRedirects = kNyctisMetadataMaxRedirects,
    Duration timeout = kNyctisMetadataTimeout,
  }) : _reader = NyctisMetadataReader(
         transport: transport,
         maxRedirects: maxRedirects,
         timeout: timeout,
       );

  final NyctisMetadataReader _reader;

  int get maxRedirects => _reader.maxRedirects;

  /// Every request this fetcher has made and every body byte it received,
  /// refused ones included. The collection warm-up spends its budget against
  /// this rather than against the bytes it kept.
  NyctisFetchTraffic get traffic => _reader.traffic;

  Duration get timeout => _reader.timeout;

  /// Keyed by `asset_id` and the pin — section 3.1's "cache a fetched document
  /// indefinitely, keyed by `asset_id` and the document digest". An unpinned
  /// pointer has no digest, so its own URI stands in: it is the only thing
  /// that identifies what was asked for.
  ///
  /// This is a process-lifetime cache and nothing writes it to disk, so the
  /// guarantee it delivers is "at most one request per accepted asset per app
  /// launch" rather than "at most one, ever". That is weaker than the SHOULD
  /// in section 3.1, and it is the honest shape of it.
  final Map<String, NyctisArtworkFetchOutcome> _cache = {};

  /// In-flight per-asset fetches, so two widgets that appear in the same frame
  /// make one request rather than two.
  final Map<String, Future<NyctisArtworkFetchOutcome>> _inFlight = {};

  /// Parsed documents, keyed by the **pointer** rather than by the asset.
  ///
  /// This is what makes `asset-collection-v0.md` section 2 true in this
  /// wallet rather than only in the spec: forty accepted pieces of one
  /// collection name the same `uri`, so they share one entry here and cost one
  /// request between them. Keyed by the pin when there is one, so an unpinned
  /// pointer and a pinned one at the same URL are never conflated — inheriting
  /// a pin is exactly the mistake a shared cache invites.
  final Map<String, _Document> _documents = {};

  /// In-flight document fetches, for the same reason as [_inFlight]: twelve
  /// tiles built in one frame must make one request for the collection
  /// document, not twelve.
  final Map<String, Future<_Document>> _documentsInFlight = {};

  /// Which assets are still relying on each cached document, so that a
  /// document can be dropped once nothing draws from it.
  final Map<String, Set<String>> _documentRequesters = {};

  /// The collection's own picture (`asset-collection-v0.md` section 3.5),
  /// keyed by the same document key as [_documents].
  ///
  /// Keyed by the document and not by the asset because the picture belongs to
  /// the document: a hundred members resolve through one `logo`, and charging
  /// one request per member for one image would undo the saving the shared
  /// form exists for. Refusals are cached here too, for the reason [_document]
  /// gives — a dead host asked once per launch is a disclosure, asked once per
  /// member it is a heartbeat.
  final Map<String, _Image> _collectionLogos = {};

  final Map<String, Future<_Image>> _collectionLogosInFlight = {};

  /// The collection's digest table (`asset-collection-v0.md` section 3.3.1),
  /// resolved into the document that points at it, keyed by the same document
  /// key as [_documents].
  ///
  /// The cached value is the *resolved document* rather than the table's
  /// bytes, so that the `b2` over as much as 512 KiB is computed once per
  /// collection instead of once per member. A document that points at no
  /// table, or at one that failed, is cached here as itself — an unresolved
  /// document answers `digestAt` with null for every index, which is exactly
  /// what section 3.3.1 says a failed table means: the whole collection
  /// unpinned, not some of it.
  final Map<String, NyctisCollectionMetadata> _collectionDocuments = {};

  final Map<String, Future<NyctisCollectionMetadata>>
  _collectionDocumentsInFlight = {};

  /// Whether [assetId] with [uri] already has an answer, without asking for
  /// one. Lets a caller draw a cached logo without being the thing that
  /// triggers a fetch.
  NyctisMetadataFetchOutcome? cached({
    required String assetId,
    required String? uri,
  }) {
    final outcome = cachedArtwork(assetId: assetId, uri: uri);
    if (outcome == null) return null;
    return _asAssetOutcome(outcome);
  }

  /// The same, for either document shape.
  NyctisArtworkFetchOutcome? cachedArtwork({
    required String assetId,
    required String? uri,
  }) {
    final pointer = readNyctisMetadataUri(uri).pointer;
    if (pointer == null) return null;
    return _cache[_cacheKey(assetId, pointer)];
  }

  /// Forgets what was fetched for [assetId]. Called when a user withdraws
  /// acceptance: the wallet stops showing the logo, so it must also stop
  /// holding the bytes.
  ///
  /// The shared collection document goes too, but only once no other asset is
  /// relying on it. Dropping it eagerly would make forgetting one piece cost
  /// the other thirty-nine a fresh request — turning a revocation into
  /// network traffic, which is the opposite of what revoking is for.
  void forget(String assetId) {
    _cache.removeWhere((key, _) => key.startsWith(_cachePrefix(assetId)));
    final emptied = <String>[];
    _documentRequesters.forEach((documentKey, requesters) {
      requesters.remove(assetId);
      if (requesters.isEmpty) emptied.add(documentKey);
    });
    for (final documentKey in emptied) {
      _documentRequesters.remove(documentKey);
      _documents.remove(documentKey);
      // The collection's picture is held on the same terms as the document
      // that named it: revoking the last piece has to stop the wallet holding
      // the bytes, not only stop it drawing them.
      _collectionLogos.remove(documentKey);
      // And so is its digest table, which is the larger of the two by an order
      // of magnitude — as much as 512 KiB per collection under section 3.2's
      // cap. A revocation that left it here would be the one case where
      // forgetting a piece costs more memory than remembering it.
      _collectionDocuments.remove(documentKey);
    }
  }

  /// Fetches the per-asset document [uri] points at.
  ///
  /// **Only call this for an asset the user has explicitly accepted.** Holding
  /// a note of an asset is not a reason (section 3.1) and this class cannot
  /// check for you — it never sees a balance.
  ///
  /// A `uri` that turns out to point at a *collection* document comes back as
  /// [NyctisMetadataAbandonReason.documentRefused], because this entry point
  /// has no index to resolve it against and section 3.2 of
  /// `asset-collection-v0.md` forbids taking one from the document. Use
  /// [fetchArtwork] with the on-chain index for that.
  Future<NyctisMetadataFetchOutcome> fetch({
    required String assetId,
    required String? uri,
  }) async {
    final outcome = await fetchArtwork(assetId: assetId, uri: uri);
    return _asAssetOutcome(outcome);
  }

  /// Fetches whatever [uri] points at, resolving a collection document against
  /// the **on-chain** [index].
  ///
  /// [index] is the `index` field of the member's issuance. It is hashed into
  /// `asset_id` through `terms` (`asset-collection-v0.md` section 1), so a
  /// document cannot lie about which piece is which — and a wallet that took
  /// the index from the document instead would throw that away, which is why
  /// this is a parameter and not something the parser can supply. Null means
  /// "this asset is not a collection member as far as the chain is concerned",
  /// and a collection document is then refused rather than guessed at.
  Future<NyctisArtworkFetchOutcome> fetchArtwork({
    required String assetId,
    required String? uri,
    int? index,
  }) {
    final pointer = readNyctisMetadataUri(uri).pointer;
    if (pointer == null) {
      return Future.value(
        const NyctisArtworkFetchOutcome.abandoned(
          NyctisMetadataAbandonReason.pointerRefused,
        ),
      );
    }
    final key = _cacheKey(assetId, pointer);
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    final running = _inFlight[key];
    if (running != null) return running;
    final future = _fetch(assetId, pointer, index)
        .then((outcome) {
          _cache[key] = outcome;
          return outcome;
        })
        // A block body, not an expression one. `Map.remove` hands back the
        // value it removed, which here is this very future — and a callback
        // that returns a future makes `whenComplete` wait for it, so the
        // expression form deadlocks every fetch on itself.
        .whenComplete(() {
          _inFlight.remove(key);
        });
    _inFlight[key] = future;
    return future;
  }

  /// `<assetId>|` — the asset id cannot contain the separator (it is hex) and
  /// the pin that follows it may contain anything.
  static String _cachePrefix(String assetId) => '$assetId|';

  static String _cacheKey(String assetId, NyctisMetadataPointer pointer) =>
      '${_cachePrefix(assetId)}${_documentKey(pointer)}';

  /// The pin when there is one, the URI when there is not — never both, so
  /// that a pinned and an unpinned pointer at the same URL stay apart.
  static String _documentKey(NyctisMetadataPointer pointer) =>
      pointer.digestB2 ?? '${pointer.requestUri}';

  Future<NyctisArtworkFetchOutcome> _fetch(
    String assetId,
    NyctisMetadataPointer pointer,
    int? index,
  ) async {
    final budget = NyctisResourceBudget();
    final document = await _document(assetId, pointer, budget);

    final reason = document.reason;
    if (reason != null) {
      return NyctisArtworkFetchOutcome.abandoned(reason);
    }

    final collection = document.collection;
    if (collection != null) {
      return _collectionMember(
        assetId: assetId,
        pointer: pointer,
        collection: collection,
        index: index,
        budget: budget,
      );
    }

    final metadata = document.asset!;
    final logo = await _image(
      uri: metadata.logo?.uri,
      expectedDigest: metadata.logo?.digestB2,
      budget: budget,
    );
    return NyctisArtworkFetchOutcome.asset(
      NyctisAssetMetadataView(
        assetId: assetId,
        metadata: metadata,
        documentPinned: pointer.isPinned,
        sourceOrigin: pointer.origin,
        logoBytes: logo.bytes,
        logoPinned: logo.bytes != null && (metadata.logo?.isPinned ?? false),
      ),
    );
  }

  /// Resolves one member of an already-parsed collection document.
  Future<NyctisArtworkFetchOutcome> _collectionMember({
    required String assetId,
    required NyctisMetadataPointer pointer,
    required NyctisCollectionMetadata collection,
    required int? index,
    required NyctisResourceBudget budget,
  }) async {
    if (index == null) {
      // No on-chain index, no substitution. `asset-collection-v0.md` section
      // 3.2 defines exactly one source for it and this wallet has not read
      // one — so the honest answer is a refusal, not a guess at 0 and not a
      // position in a list sorted by `asset_id`, which is a hash order.
      //
      // The collection's `logo` is not fetched on this path either. The
      // document is refused for this asset, and a refused document is not a
      // reason to ask the host for a picture.
      return const NyctisArtworkFetchOutcome.abandoned(
        NyctisMetadataAbandonReason.documentRefused,
      );
    }

    // Section 3.3.1, resolved before anything reads a digest. `collection` is
    // shadowed deliberately: every line below this one must see the resolved
    // document, and leaving the unresolved one reachable under the same name
    // is how a later edit silently reads `digestAt` from a document whose
    // table has not been fetched.
    final resolved = await _collectionDocument(pointer, collection);

    // Section 3.5, resolved before the member so that a collection still has a
    // face when the piece the wallet happened to ask through has none.
    final collectionLogo = await _collectionLogo(pointer, resolved);
    final collectionLogoBytes = collectionLogo.bytes;
    final collectionLogoPinned =
        collectionLogoBytes != null && (resolved.logo?.isPinned ?? false);

    final member = resolved.memberAt(index);
    if (member == null || !member.hasImage) {
      // Section 3.2: a template that does not substitute to a valid absolute
      // `https:` URI is *the piece* having no artwork, never the collection
      // being invalid — so this is a per-member abandonment and the other
      // ninety-nine are unaffected.
      return NyctisArtworkFetchOutcome.collectionMember(
        NyctisCollectionMemberView(
          assetId: assetId,
          index: index,
          collection: resolved,
          member:
              member ??
              NyctisCollectionMember(
                index: index,
                name: null,
                description: null,
                image: null,
                digestB2: null,
                imageRejection: NyctisItemImageRejection.absent,
                attributes: const [],
              ),
          documentPinned: pointer.isPinned,
          sourceOrigin: pointer.origin,
          imageReason: NyctisMetadataAbandonReason.noImage,
          collectionLogoBytes: collectionLogoBytes,
          collectionLogoPinned: collectionLogoPinned,
        ),
      );
    }

    final image = await _image(
      uri: member.image,
      expectedDigest: member.digestB2,
      budget: budget,
    );
    return NyctisArtworkFetchOutcome.collectionMember(
      NyctisCollectionMemberView(
        assetId: assetId,
        index: index,
        collection: resolved,
        member: member,
        documentPinned: pointer.isPinned,
        sourceOrigin: pointer.origin,
        imageBytes: image.bytes,
        imageReason: image.reason,
        collectionLogoBytes: collectionLogoBytes,
        collectionLogoPinned: collectionLogoPinned,
      ),
    );
  }

  /// The collection's own picture (`asset-collection-v0.md` section 3.5),
  /// fetched at most once per document and shared by every member of it.
  ///
  /// **On its own budget, deliberately.** `asset-metadata-v0.md` section 3.2
  /// bounds one *asset* at 512 KiB across every resource its document pulls
  /// in, and this picture is not one of that asset's resources: it belongs to
  /// the document, it is fetched once for a hundred members, and charging it
  /// to whichever member's fetch happened to arrive first would make the
  /// collection's face succeed or fail by a coincidence of ordering — a member
  /// with a 256 KiB image would exhaust the per-asset total and refuse the
  /// collection's picture, while the next member over would get it. Its own
  /// budget still bounds it: 256 KiB by the logo limit and 512 KiB by the
  /// total, for one image fetched once.
  Future<_Image> _collectionLogo(
    NyctisMetadataPointer pointer,
    NyctisCollectionMetadata collection,
  ) {
    final key = _documentKey(pointer);
    final cached = _collectionLogos[key];
    if (cached != null) return Future.value(cached);
    final running = _collectionLogosInFlight[key];
    if (running != null) return running;

    final future =
        _image(
              uri: collection.logo?.uri,
              expectedDigest: collection.logo?.digestB2,
              budget: NyctisResourceBudget(),
            )
            .then((image) {
              _collectionLogos[key] = image;
              return image;
            })
            .whenComplete(() {
              _collectionLogosInFlight.remove(key);
            });
    _collectionLogosInFlight[key] = future;
    return future;
  }

  /// [collection] with its digest table (section 3.3.1) and its items document
  /// (section 3.4.1) resolved, each fetched at most once per document and
  /// shared by every member of it.
  ///
  /// **On its own budget, for section 3.5's reason applied to section 3.3.1.**
  /// The table belongs to the document, not to whichever member's fetch
  /// arrived first: charging 312 KiB of table to one member's 512 KiB total
  /// would make a collection's pinning succeed or fail by a coincidence of
  /// ordering, and `asset-metadata-v0.md` section 3.2 now says so in as many
  /// words.
  ///
  /// **The whole table, never a range.** A range request would be the obvious
  /// optimization — one member needs 32 bytes, not 312 KiB — and section 3.3.1
  /// forbids it because the offset of a digest *is* its index. `Range:
  /// bytes=320-351` tells the host the wallet wants member 10 and nothing
  /// else, which is the section 2.1 disclosure arriving through the mechanism
  /// chosen to avoid it. There is no range request in this method and there
  /// must not be one.
  Future<NyctisCollectionMetadata> _collectionDocument(
    NyctisMetadataPointer pointer,
    NyctisCollectionMetadata collection,
  ) {
    final table = collection.digestTable;
    final itemsDoc = collection.itemsDocument;
    if (table == null && itemsDoc == null) return Future.value(collection);

    final key = _documentKey(pointer);
    final cached = _collectionDocuments[key];
    if (cached != null) return Future.value(cached);
    final running = _collectionDocumentsInFlight[key];
    if (running != null) return running;

    final future =
        Future(() async {
          var value = collection;

          if (table != null) {
            final result = await _reader.read(
              table.uri,
              maxBytes: table.expectedBytes,
              accept: 'application/octet-stream',
              budget: NyctisResourceBudget(),
            );
            final bytes = result.bytes;
            // A failure at any step leaves the *unresolved* document. That is not
            // a fallback to inline digests — a document carrying `digest_table`
            // has no inline digests to fall back to — it is the collection reading
            // as unpinned, which is what section 3.3.1 requires and what the UI
            // already has a state for.
            value =
                (bytes == null ? null : value.resolveDigestTable(bytes)) ??
                value;
          }

          if (itemsDoc != null) {
            // Section 3.4.1's MAY, exercised. `bytes` is declared, so the refusal
            // happens here — before a connection — rather than after the body has
            // arrived. That is the entire reason the member exists, and a wallet
            // that fetched first and measured afterwards would have thrown it away.
            //
            // Declining is a rendering without traits and not a failed collection:
            // traits are decoration (`asset-metadata-v0.md` section 1), so the
            // template still draws every piece.
            if (itemsDoc.bytes <= kNyctisItemsDocumentMaxBytes) {
              final result = await _reader.read(
                itemsDoc.uri,
                maxBytes: itemsDoc.bytes,
                accept: 'application/json',
                budget: NyctisResourceBudget(),
              );
              final bytes = result.bytes;
              value =
                  (bytes == null ? null : value.resolveItemsDocument(bytes)) ??
                  value;
            }
          }

          _collectionDocuments[key] = value;
          return value;
        }).whenComplete(() {
          _collectionDocumentsInFlight.remove(key);
        });
    _collectionDocumentsInFlight[key] = future;
    return future;
  }

  /// The document at [pointer], fetched at most once per pointer and shared by
  /// every asset that names it.
  Future<_Document> _document(
    String assetId,
    NyctisMetadataPointer pointer,
    NyctisResourceBudget budget,
  ) async {
    final key = _documentKey(pointer);
    (_documentRequesters[key] ??= <String>{}).add(assetId);

    final cached = _documents[key];
    // A cache hit costs no bytes and no budget, which is the whole saving of
    // the shared form: the fortieth piece of a collection pays for its image
    // and for nothing else.
    if (cached != null) return cached;
    final running = _documentsInFlight[key];
    if (running != null) return running;

    final future = _readDocument(pointer, budget)
        .then((document) {
          // Refusals are cached too. A dead host asked once per launch is a
          // disclosure; asked once per tile it is a heartbeat, and section
          // 3.1 names that as the thing not to produce.
          _documents[key] = document;
          return document;
        })
        .whenComplete(() {
          _documentsInFlight.remove(key);
        });
    _documentsInFlight[key] = future;
    return future;
  }

  Future<_Document> _readDocument(
    NyctisMetadataPointer pointer,
    NyctisResourceBudget budget,
  ) async {
    final read = await _reader.read(
      pointer.requestUri,
      maxBytes: kNyctisDocumentMaxBytes,
      accept: 'application/json',
      budget: budget,
    );
    final bytes = read.bytes;
    if (bytes == null) return _Document.abandoned(read.reason!);

    final expected = pointer.digestB2;
    if (expected != null && !nyctisB2DigestMatches(expected, bytes)) {
      // Section 2.1: discard, and do not retry a different source. There is no
      // second attempt below this line and there must not be one.
      return const _Document.abandoned(
        NyctisMetadataAbandonReason.digestMismatch,
      );
    }

    // Which specification's document this is, decided by `schema` and by
    // nothing else. A wallet cannot know before the bytes arrive: section 4 of
    // `asset-collection-v0.md` lets a collection member point at either shape.
    if (_declaresCollectionSchema(bytes)) {
      try {
        return _Document.collection(NyctisCollectionMetadata.parseBytes(bytes));
      } on NyctisMetadataFormatException {
        return const _Document.abandoned(
          NyctisMetadataAbandonReason.documentRefused,
        );
      }
    }
    try {
      return _Document.asset(NyctisAssetMetadata.parseBytes(bytes));
    } on NyctisMetadataFormatException {
      return const _Document.abandoned(
        NyctisMetadataAbandonReason.documentRefused,
      );
    }
  }

  /// Whether the document's `schema` names the collection family.
  ///
  /// Parsed rather than substring-matched: a `description` mentioning the
  /// string would otherwise decide which parser runs. Anything unparseable
  /// falls through to the asset parser, which produces the same refusal it
  /// always did.
  static bool _declaresCollectionSchema(Uint8List bytes) {
    final Map<String, Object?> decoded;
    try {
      decoded = nyctisDecodeDocument(bytes);
    } on NyctisMetadataFormatException {
      return false;
    }
    return nyctisSchemaMajor(
          decoded['schema'],
          kNyctisCollectionSchemaFamily,
        ) !=
        null;
  }

  /// One image, verified against [expectedDigest] when there is one.
  ///
  /// A failure costs the picture, never the document: the description and the
  /// links are still worth drawing, and so is the asset. The *reason* is kept
  /// so a tile can tell "nothing to fetch" from "the host served something we
  /// refused", which the single "Not fetched" state could not.
  Future<_Image> _image({
    required Uri? uri,
    required String? expectedDigest,
    required NyctisResourceBudget budget,
  }) async {
    if (uri == null) {
      return const _Image.abandoned(NyctisMetadataAbandonReason.noImage);
    }
    final result = await _reader.read(
      uri,
      maxBytes: kNyctisLogoMaxBytes,
      accept: _imageAccept,
      budget: budget,
    );
    final bytes = result.bytes;
    if (bytes == null) return _Image.abandoned(result.reason!);
    if (expectedDigest != null &&
        !nyctisB2DigestMatches(expectedDigest, bytes)) {
      // `asset-metadata-v0.md` section 4.2 and `asset-collection-v0.md`
      // section 3.3, which is the same MUST twice: verify it, and discard a
      // mismatching image **without retrying**. Nothing below this line tries
      // another source, and nothing above it may.
      return const _Image.abandoned(NyctisMetadataAbandonReason.digestMismatch);
    }
    // Section 4.2: the format comes from the bytes. `mime` was never parsed,
    // so there is nothing here that could have been believed instead.
    if (!sniffNyctisImageFormat(bytes).isRenderable) {
      return const _Image.abandoned(
        NyctisMetadataAbandonReason.imageFormatRefused,
      );
    }
    // The size limit bounds the file, not the bitmap. A PNG decodes at its
    // declared size before any `cacheWidth` scaling, so the declared size is
    // checked here, before a widget can hand the bytes to the engine. An
    // unreadable header is refused on the same terms: its decode is the one
    // that cannot be bounded.
    final dimensions = readNyctisImageDimensions(bytes);
    if (dimensions == null || !dimensions.isWithinDecodeBound) {
      return const _Image.abandoned(
        NyctisMetadataAbandonReason.imageDimensionsRefused,
      );
    }
    return _Image.bytes(bytes);
  }

  /// The per-asset shape of an outcome, for the callers that predate
  /// collections. A collection member has no [NyctisAssetMetadata] to hand
  /// back, so it reads as a refused document — which is what it is to a caller
  /// that has no index.
  static NyctisMetadataFetchOutcome _asAssetOutcome(
    NyctisArtworkFetchOutcome outcome,
  ) {
    final view = outcome.assetView;
    if (view != null) return NyctisMetadataFetchOutcome.fetched(view);
    return NyctisMetadataFetchOutcome.abandoned(
      outcome.reason ?? NyctisMetadataAbandonReason.documentRefused,
    );
  }
}

/// A parsed document of one shape or the other, or the refusal.
class _Document {
  const _Document.asset(NyctisAssetMetadata this.asset)
    : collection = null,
      reason = null;

  const _Document.collection(NyctisCollectionMetadata this.collection)
    : asset = null,
      reason = null;

  const _Document.abandoned(NyctisMetadataAbandonReason this.reason)
    : asset = null,
      collection = null;

  final NyctisAssetMetadata? asset;
  final NyctisCollectionMetadata? collection;
  final NyctisMetadataAbandonReason? reason;
}

class _Image {
  const _Image.bytes(Uint8List this.bytes) : reason = null;

  const _Image.abandoned(NyctisMetadataAbandonReason this.reason)
    : bytes = null;

  final Uint8List? bytes;
  final NyctisMetadataAbandonReason? reason;
}
