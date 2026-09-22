/// Fetching a collection's artwork so that **which pieces** the wallet fetched
/// says nothing about which pieces it holds.
///
/// ## The hole this closes
///
/// `spec/asset-collection-v0.md` section 2 argues that the shared form is the
/// private one: a hundred separate documents means up to a hundred requests
/// whose pattern discloses which pieces the wallet cares about, and "one
/// document for the collection discloses interest in the collection and
/// nothing about which members".
///
/// The first half is true and the second half is not, because **the images are
/// still per-piece URLs**. The document is `pon/c.json` and the artwork is
/// `pon/0.png` … `pon/99.png`, so a wallet that fetches the document once and
/// then seven images has told the host exactly which seven pieces it is
/// interested in — the disclosure the single document was meant to avoid,
/// arriving one hop later on the same connection.
///
/// It matters because of what the set of fetched indices correlates with. The
/// image fetch is gated on acceptance, acceptance is a per-`asset_id` decision
/// the user makes, and a user accepts the pieces they care about — which, for
/// a collection, is overwhelmingly the pieces they hold. Section 5's "**MUST
/// NOT** fetch a collection document because it *holds* a member" is obeyed to
/// the letter and defeated in effect: the wallet does not fetch because it
/// holds, it fetches because the user accepted what they hold.
///
/// The shared form is still better than the per-piece form — it removes the
/// index from the *document* URL and halves the number of index-revealing
/// requests — but the improvement is a constant factor, not the qualitative
/// "nothing about which members" section 2 claims.
///
/// ## What this file does about it, and what was rejected
///
/// **Chosen: fetch every member's image once any member of the collection is
/// accepted.** The request set becomes the whole collection, which is a
/// function of the channel and not of the wallet, so the host learns nothing
/// from it. This is not an invention: `asset-metadata-v0.md` section 3.1
/// already names it as the strongest option — a wallet **MAY** "fetch the
/// documents of *every* asset on the channel regardless of what it holds or
/// has accepted", which "discloses nothing about the wallet". Section 3.1
/// scopes that MAY to a whole channel, where it does not scale; a collection
/// is the scope where it does, because the 16 KiB document limit bounds a
/// shared collection at roughly 300 members (section 3.3).
///
/// Fetching artwork for a piece the user has not accepted is what makes the
/// set holdings-independent, and it is permitted: the MAY above is explicitly
/// "regardless of what it holds **or has accepted**". Section 5 of
/// `asset-metadata-v0.md` forbids *displaying* an unaccepted logo, not
/// fetching one, and nothing here displays anything —
/// [nightjarAssetArtworkProvider] still gates every drawn pixel on acceptance.
///
/// **Rejected: fetch nothing until an individual piece is opened.** It is the
/// worst of the options and it is roughly what the grid did before this file
/// existed. The disclosed set becomes "the pieces the user opened", which is
/// the most holdings-correlated set available — a user opens the piece they
/// own. It costs the least bandwidth and buys the least privacy.
///
/// **Rejected: fetch only the accepted members in bulk.** This is the obvious
/// half-measure and it does not work. Acceptance is per `asset_id` and partial
/// acceptance is a first-class state — the card has a `partial` case for a
/// collection that grew — so "every accepted member" is a user-chosen subset
/// and disclosing it discloses the choice.
///
/// **Rejected: doing nothing in code and only correcting the spec.** Honest,
/// and leaves the hole in the one wallet that implements the document.
///
/// ## What it costs, stated rather than hidden
///
/// Bandwidth, and it is the reason this is bounded rather than unconditional.
/// The reference collection is 100 images of about 2.5 KiB, so 250 KiB. The
/// worst case allowed by `asset-metadata-v0.md` section 3.2 is 256 KiB per
/// image, so a 300-member collection could ask for 75 MiB, and a wallet that
/// spends that on a metered connection has traded a privacy leak for a bill.
/// So the warm-up stops at [kNightjarCollectionWarmupMaxBytes] and the
/// remainder falls back to per-tile fetching.
///
/// That fallback is a **residual leak and is named as one**: past the cap, the
/// tail of the collection is fetched only as the user looks at it, and the
/// pieces the user looks at are the pieces they hold. There is no way to be
/// both leak-free and bounded — leak-free requires fetching everything and
/// "everything" has no bound the wallet knows in advance — and an unbounded
/// transfer on a phone is not a trade this wallet gets to make silently. A
/// collection whose artwork fits under the cap, which is every collection with
/// sanely sized images, has no residue at all.
///
/// Memory is *not* a cost here, and the distinction is the thing that makes
/// this affordable: warming fills the fetcher's byte cache, and bytes are not
/// bitmaps. Decoding stays bounded by the viewport — the grid builds only the
/// tiles it can show and [NightjarAssetLogoImage] clamps each decode — so a
/// warmed hundred-piece collection holds a few hundred KiB of PNG and decodes
/// a dozen pictures.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/nightjar_artwork_data.dart';
import '../widgets/nightjar_asset_row_data.dart';
import '../widgets/nightjar_collection_data.dart';
import 'nightjar_asset_acceptance_provider.dart';
import 'nightjar_asset_metadata_provider.dart';
import 'nightjar_collections_provider.dart';
import 'nightjar_metadata_fetcher_provider.dart';

/// How many bytes of artwork one collection's warm-up may spend.
///
/// Four mebibytes. Not a number from the specification — `asset-metadata-v0.md`
/// section 3.2 bounds one asset at 512 KiB and says nothing about a collection
/// — so it is a choice this wallet makes and states. It is roughly sixteen
/// times the reference collection's whole artwork, which means every
/// reasonably built collection is warmed completely and the cap only bites on
/// one whose publisher shipped a hundred quarter-megabyte images.
const int kNightjarCollectionWarmupMaxBytes = 4 * 1024 * 1024;

/// How many *distinct documents* one collection's warm-up may fetch.
///
/// `asset-collection-v0.md` section 6 T3b makes this a MUST and leaves the
/// number to the wallet, so this is the number and this is where it is stated.
///
/// It exists because of how a collection grows. Section 6 T3: a collection that
/// gains members past its table publishes a *new* document with a longer table,
/// older members keep the uri they already signed, and a wallet finds the whole
/// set on-chain rather than in any document. That is the right mechanism — no
/// third party can add a document to it — but it is bounded only by the member
/// count, so a publisher who names every member with a document of its own
/// produces ten thousand individually valid, individually signed uris. Fetching
/// them is ten thousand requests, and the collection is section 4's per-piece
/// form wearing section 3's clothes.
///
/// Sixty-four is generous against the shape the design expects: a collection
/// republished once per ten thousand members reaches 64 documents at 640,000
/// pieces. It is tight against the shape it is defending against.
const int kNightjarCollectionMaxDocuments = 64;

/// The outcome of warming one collection, for tests and for copy.
class NightjarCollectionWarmup {
  const NightjarCollectionWarmup({
    required this.requested,
    required this.bytes,
    required this.complete,
    this.documents = 0,
    this.documentsExceeded = false,
  });

  const NightjarCollectionWarmup.none()
    : requested = 0,
      bytes = 0,
      complete = false,
      documents = 0,
      documentsExceeded = false;

  /// Distinct document uris the members of this collection named.
  ///
  /// One, for a collection that has never outgrown its table. More than one is
  /// a collection that grew (section 6 T3), and is the normal state rather than
  /// a fault.
  final int documents;

  /// Whether [kNightjarCollectionMaxDocuments] was reached, so that members
  /// naming further documents were left out.
  ///
  /// Separate from [complete] because the two say different things to the user:
  /// a byte cap means "this collection's artwork is large", and this means
  /// "this collection is published in a shape that costs a request per piece",
  /// which section 6 T3b says a wallet SHOULD surface.
  final bool documentsExceeded;

  /// Members whose artwork was asked for.
  final int requested;

  /// Image bytes accepted, across those members.
  final int bytes;

  /// Whether every member was covered. False means the cap was reached and the
  /// tail falls back to per-tile fetching — the residual leak this file's
  /// header names.
  final bool complete;
}

/// Warms every member of [collectionId] once any member of it is accepted.
///
/// Watched by an otherwise invisible widget on the collection screen, so that
/// the one place in this feature that turns a stored acceptance into a burst
/// of network requests is a named thing rather than a side effect of
/// scrolling.
///
/// Sequential rather than parallel. A hundred concurrent HTTPS requests
/// through the Tor route is not a thing a wallet should do to its own
/// transport, and the order is the index order — a function of the channel,
/// like the set itself.
final nightjarCollectionArtworkWarmupProvider =
    FutureProvider.family<NightjarCollectionWarmup, String>((
      ref,
      collectionId,
    ) async {
      final collection = ref.watch(nightjarCollectionProvider(collectionId));
      if (collection == null) return const NightjarCollectionWarmup.none();

      // The gate, and it is the only one. Acceptance of *any* member is the
      // user's decision to talk to this issuer's host about this collection;
      // what the wallet then asks for is deliberately not a function of which
      // member they accepted.
      final acceptance = ref.watch(nightjarAssetAcceptanceProvider);
      final anyAccepted = collection.members.any(
        (member) => acceptance.isAccepted(member.assetId),
      );
      if (!anyAccepted) return const NightjarCollectionWarmup.none();

      final fetcher = ref.watch(nightjarMetadataFetcherProvider);
      var requested = 0;
      var bytes = 0;
      var complete = true;
      var documentsExceeded = false;

      // Section 6 T3b. Deduped on the signed uri string, which is exactly the
      // fetch unit: two members naming the same string share one request, and
      // two naming different strings cost two however similar they look.
      final documents = <String>{};

      for (final member in collection.members) {
        if (bytes >= kNightjarCollectionWarmupMaxBytes) {
          complete = false;
          break;
        }
        final uri = member.metadataUri;
        if (uri == null || uri.trim().isEmpty) continue;

        // The bound is on *new* documents, not on members: once a document is
        // in hand, every further member of it is free, which is the whole point
        // of the shared form. So this skips the member rather than breaking the
        // loop — a later member may well name a document already fetched, and
        // stopping would deny it artwork for a neighbour's sake.
        if (!documents.contains(uri) &&
            documents.length >= kNightjarCollectionMaxDocuments) {
          documentsExceeded = true;
          complete = false;
          continue;
        }
        documents.add(uri);

        requested++;
        final outcome = await fetcher.fetchArtwork(
          assetId: member.assetId,
          uri: uri,
          // The **on-chain** index, from the view and from nowhere else
          // (`asset-collection-v0.md` section 1). A member whose index the
          // wallet has not read gets no artwork rather than a guessed one.
          index: member.index,
        );
        bytes += outcome.imageBytes?.length ?? 0;
      }

      return NightjarCollectionWarmup(
        requested: requested,
        bytes: bytes,
        complete: complete,
        documents: documents.length,
        documentsExceeded: documentsExceeded,
      );
    });

/// The `max_supply` a collection's own document claims, or null.
///
/// `asset-collection-v0.md` section 3.1 makes this the number a wallet
/// **MUST** compare against the on-chain cap rather than believe, and the
/// comparison needs the two of them in one place: the chain's is on
/// [NightjarCollectionData.maxSupply] and this is the document's.
/// `nightjarCollectionCapDisagreementText` is what says so when they differ.
///
/// It costs no request. The document is fetched only as a side effect of a
/// member's artwork — section 3.1 of `asset-metadata-v0.md` forbids fetching
/// one because a note is held — so this reads whatever the acceptance the user
/// already gave has brought in, and answers null until then. Null is also the
/// answer for a document that declares no `max_supply`, or declares `0` —
/// section 3.1 defines both as uncapped and the parser folds them together —
/// because neither is a number to compare.
///
/// The *lowest accepted* member is the one read, matching
/// [nightjarCollectionArtworkProvider] — every member of a collection reaches
/// the same document, so the answer must not depend on which one arrived
/// first.
final nightjarCollectionDocumentMaxSupplyProvider =
    Provider.family<int?, String>((ref, collectionId) {
      final collection = ref.watch(nightjarCollectionProvider(collectionId));
      if (collection == null) return null;

      final acceptance = ref.watch(nightjarAssetAcceptanceProvider);
      for (final member in collection.members) {
        if (!acceptance.isAccepted(member.assetId)) continue;
        final fetch = ref.watch(
          nightjarAssetArtworkFetchProvider(member.assetId),
        );
        return fetch.asData?.value?.memberView?.collection.maxSupply;
      }
      return null;
    });

/// Whether [collection] is one this warm-up applies to at all.
///
/// A collection whose members carry no `uri` has nothing to warm, and saying
/// so lets the acceptance card leave out a sentence about a fetch that will
/// never happen.
bool nightjarCollectionHasFetchableArtwork(NightjarCollectionData collection) {
  for (final NightjarAssetDetailData member in collection.members) {
    final uri = member.metadataUri;
    if (uri != null && uri.trim().isNotEmpty) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// The collection's own face (`spec/asset-collection-v0.md` section 3.5)
// ---------------------------------------------------------------------------

/// The face of one collection, under section 3.5 and its fallback.
///
/// The order is the specification's:
///
/// 1. **Nothing until a member is accepted.** Section 3.5 puts the collection's
///    picture under the same gate as an asset's — `asset-metadata-v0.md`
///    section 3.1 for the fetch, section 5 for the drawing — because a picture
///    being the collection's rather than a piece's changes neither what the
///    request discloses nor who chose the picture.
/// 2. **A declared `logo`, when the document has one.** It rides in on the
///    document, which a member's fetch has already read and cached, so it
///    costs one image request for the whole collection and its URL carries no
///    index.
/// 3. **Otherwise the lowest-indexed *accepted* member's artwork, marked
///    derived.** Section 3.5.1. "Accepted" and not merely "lowest-indexed" is
///    the part that is easy to get wrong and this file will not: section 5 of
///    `asset-metadata-v0.md` forbids displaying a logo for an `asset_id` the
///    user has not accepted, a collection's face is a place a picture is
///    displayed, and the argument that the user already accepted the *issuer*
///    — true, since `collection_id` is derived from their key and hashed into
///    every member's `asset_id` — is exactly the argument section 5 refuses.
///    Fetching an unaccepted member is permitted and this file does it;
///    drawing one is not.
///
/// **Why watching this warms the whole collection.** Step 3 needs a member's
/// bytes, and asking for one member's image is the index disclosure section
/// 2.1 exists to close: the accepted set is the held set with extra steps. So
/// whenever any member is accepted this watches
/// [nightjarCollectionArtworkWarmupProvider], which makes the request set the
/// whole collection — a fact about the channel rather than about the wallet.
/// It is the same reason [NightjarUniqueItemSection] warms from a piece's own
/// screen, applied to the one other surface that can now cause a fetch, and it
/// is section 2.1's SHOULD rather than an extra this wallet invented.
final nightjarCollectionArtworkProvider =
    Provider.family<NightjarCollectionArtworkData, String>((
      ref,
      collectionId,
    ) {
      final collection = ref.watch(nightjarCollectionProvider(collectionId));
      if (collection == null) {
        return const NightjarCollectionArtworkData.notAccepted();
      }

      final acceptance = ref.watch(nightjarAssetAcceptanceProvider);
      // `collection.members` is already in on-chain index order
      // (`compareNightjarCollectionMembers`), so "first" here is "lowest
      // index" and nothing re-sorts.
      final accepted = [
        for (final member in collection.members)
          if (acceptance.isAccepted(member.assetId)) member,
      ];
      if (accepted.isEmpty) {
        return const NightjarCollectionArtworkData.notAccepted();
      }

      // Section 2.1, and the reason is in this provider's own comment: the
      // face is about to need a member's bytes, and asking for one member's
      // image would disclose which one.
      ref.watch(nightjarCollectionArtworkWarmupProvider(collectionId));

      // Step 2. Any accepted member reaches the same document; the lowest is
      // chosen so the answer does not depend on which member happened to
      // arrive first.
      final declared = ref.watch(
        nightjarAssetArtworkFetchProvider(accepted.first.assetId),
      );
      final memberView = declared.asData?.value?.memberView;
      final logoBytes = memberView?.collectionLogoBytes;
      if (memberView != null && logoBytes != null) {
        return NightjarCollectionArtworkData(
          artwork: NightjarArtworkData(
            status: memberView.collectionLogoPinned
                ? NightjarArtworkStatus.verified
                : NightjarArtworkStatus.unpinned,
            bytes: logoBytes,
            sourceOrigin: memberView.sourceOrigin,
            documentPinned: memberView.documentPinned,
          ),
          source: NightjarCollectionArtworkSource.declared,
        );
      }

      // Whether there *was* a `logo` and the wallet would not keep it. Read
      // off the parsed document rather than inferred from the missing bytes,
      // because the two cases owe the user different sentences: a collection
      // that published nothing is an omission, and one whose picture failed
      // its digest is a host serving something the issuer never signed for.
      final declaredLogoRefused =
          memberView != null && memberView.collection.logo != null;

      // Step 3. Walk the accepted members in index order and take the first
      // that has a picture this wallet is allowed to draw. It stops at the
      // first hit, so the ordinary case watches one member; the walk exists so
      // that one refused piece does not leave a collection of ninety-nine
      // good ones faceless.
      var anyPending = declared.isLoading;
      for (final member in accepted) {
        final artwork = ref.watch(nightjarAssetArtworkProvider(member.assetId));
        if (artwork.hasImage) {
          return NightjarCollectionArtworkData(
            artwork: artwork,
            source: NightjarCollectionArtworkSource.derived,
            // The **on-chain** index, or null when the wallet has not read one.
            // Never the position in this list: that is a wallet-local ordering
            // and section 1 spends the whole `asset_id` derivation making sure
            // an edition number is not one of those.
            derivedFromIndex: member.index,
            declaredLogoRefused: declaredLogoRefused,
          );
        }
        if (artwork.status == NightjarArtworkStatus.pending) anyPending = true;
      }

      return anyPending
          ? const NightjarCollectionArtworkData.pending()
          : NightjarCollectionArtworkData(
              artwork: const NightjarArtworkData(
                status: NightjarArtworkStatus.refused,
              ),
              declaredLogoRefused: declaredLogoRefused,
            );
    });
