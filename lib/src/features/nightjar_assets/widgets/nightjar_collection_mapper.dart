/// Every sentence the collection surfaces say, and the pure functions that
/// pick between them.
///
/// Kept apart from the widgets for the same reason `nightjar_asset_row_mapper
/// .dart` is: both form factors and the Widgetbook fixtures go through exactly
/// the same text, and the rules that matter are testable without a
/// `BuildContext`.
library;

import '../../../core/formatting/number_format.dart';
import '../models/nightjar_asset_acceptance.dart';
import 'nightjar_artwork_data.dart';
import 'nightjar_asset_row_data.dart';
import 'nightjar_collection_data.dart';

/// Heading for the card that holds the collections on the assets screen.
const String kNightjarCollectionsSectionTitle = 'Collections';

/// The heading a collection gets when the members' signed names share nothing
/// worth deriving a title from.
const String kNightjarUnnamedCollectionTitle = 'Unnamed collection';

/// The collection screen's footnote about [NightjarCollectionData.memberCount],
/// for a collection nothing caps.
///
/// The number is "members this wallet can see", and the difference matters:
/// nothing in an *uncapped* `collection_id` carries a cardinality, so there is
/// no total to compare against and no way to say "3 of 100" honestly.
///
/// This sentence used to be the only one, and it was a claim about every
/// collection. `transition-v0.md` revision 11 made it a claim about half of
/// them: a `collection_id` now hashes a cap, and where the cap is non-zero
/// there *is* a total, enforced by every verifier. See
/// [kNightjarCappedCollectionCountNote] for the other half and
/// [nightjarCollectionCountNote] for the choice between them.
const String kNightjarCollectionCountNote =
    'This is every piece of the collection the wallet has read from the '
    'channel. Nothing in a collection id says how many there should be, so '
    'there is no total to check it against.';

/// The same footnote for a collection whose `collection_id` binds a cap.
///
/// Two facts, and the second is the one that is easy to drop. The cap is real
/// — `transition-v0.md` section 6 step 6f ignores a public issuance whose
/// index is not strictly below it, so a piece above the cap was never applied
/// and does not exist to be shown — and the cap is still **not** a completion.
/// It bounds the collection above and says nothing about the pieces below it
/// existing yet, which is why the count reads "of at most" everywhere.
const String kNightjarCappedCollectionCountNote =
    'This collection is capped: every verifier refuses a piece numbered at or '
    'above the cap, because the cap is part of the collection id. That is a '
    'ceiling, not a total — the pieces below it are published when their '
    'issuer publishes them, so the wallet can say at most how many there will '
    'be and not how many there are.';

/// Which of the two the screen shows for [collection].
String nightjarCollectionCountNote(NightjarCollectionData collection) =>
    collection.isCapped
    ? kNightjarCappedCollectionCountNote
    : kNightjarCollectionCountNote;

/// What the wallet says when a collection document's `max_supply` and the cap
/// bound into `collection_id` disagree, or null when they do not.
///
/// `asset-collection-v0.md` section 3.1 turns this into two obligations and
/// they are not the same one: a wallet **MUST** compare the document's number
/// against the chain rather than believe it, and **SHOULD** say so where it
/// shows a count when the two disagree. Comparing silently would satisfy the
/// MUST and leave the user reading a number the wallet already knows is wrong.
///
/// Null is also the answer when either number is missing. A document with no
/// `max_supply` claims nothing, and an uncapped collection contradicts
/// nothing — neither is a disagreement, and reporting one as such would turn
/// the ordinary shape of a collection into a warning.
String? nightjarCollectionCapDisagreementText({
  required NightjarCollectionData collection,
  required int? documentMaxSupply,
}) {
  final cap = collection.maxSupply;
  if (cap == null || documentMaxSupply == null) return null;
  if (documentMaxSupply == cap) return null;
  return 'The document this collection publishes says '
      '${formatGroupedInteger(documentMaxSupply)}, and the cap in the '
      'collection id is ${formatGroupedInteger(cap)}. The wallet counts '
      'against the collection id — the document is a file its publisher can '
      'rewrite, and the cap is part of what every verifier checks.';
}

/// The one line a collection screen owes the user about what is private here.
const String kNightjarCollectionPrivacyNote =
    'Which pieces you hold is private — only this wallet can see it. Which '
    'pieces exist is public, because each was issued publicly.';

/// Shown for a collection id the current view has no members for.
String nightjarUnknownCollectionText(String collectionId) {
  return 'This wallet has read no pieces of collection '
      '${truncateNightjarAssetId(collectionId)}.';
}

/// `Phases of one night` — the heading for one collection.
String nightjarCollectionTitle(NightjarCollectionData collection) =>
    collection.title ?? kNightjarUnnamedCollectionTitle;

/// The supporting line under that heading.
///
/// It always carries the truncated `collection_id`. The title above it is
/// derived from issuer-declared names, and the id is the only part of the two
/// lines that identifies anything — the same reason section 5 of
/// `spec/asset-metadata-v0.md` puts an `asset_id` beside every logo.
String nightjarCollectionSubtitle(NightjarCollectionData collection) =>
    truncateNightjarAssetId(collection.collectionId);

/// `100 pieces · you hold 3` — the count on a collection's row.
///
/// Two numbers because they answer two different questions and only one of
/// them is public. The first is what the channel carries; the second is a fact
/// about this wallet that nobody else can compute.
///
/// **A capped collection gets a third**, and the wording of it is the whole
/// point of `transition-v0.md` revision 11. Where `collection_id` binds a
/// cap, the first number has something to be read against, so the row reads
/// `3 of at most 10,000` — the phrasing step 6f writes out and the phrasing it
/// rules out in the same breath: "three of at most ten thousand" is honest and
/// "three of ten thousand" is not, because a cap bounds a collection above and
/// promises nothing about the pieces below it existing yet.
String nightjarCollectionCountText(NightjarCollectionData collection) {
  final pieces = nightjarCollectionPiecesText(collection);
  if (!collection.ownsAny) return '$pieces · none held';
  return '$pieces · you hold ${formatGroupedInteger(collection.ownedCount)}';
}

/// The public half of [nightjarCollectionCountText]: how many pieces the
/// wallet has read, and the ceiling it is read against when there is one.
String nightjarCollectionPiecesText(NightjarCollectionData collection) {
  final read = formatGroupedInteger(collection.memberCount);
  final cap = collection.maxSupply;
  if (cap == null) {
    return collection.memberCount == 1 ? '1 piece' : '$read pieces';
  }
  // No singular form: "1 of at most 10,000" already carries the noun in the
  // label beside it, and "1 piece of at most 10,000" reads as a quantity of
  // one piece rather than as one of them.
  return '$read of at most ${formatGroupedInteger(cap)}';
}

/// The right-hand column of a collection's row: how many of them are this
/// wallet's.
String nightjarCollectionOwnedText(NightjarCollectionData collection) {
  return formatGroupedInteger(collection.ownedCount);
}

/// The label under it, so the number above is not read as a balance.
const String kNightjarCollectionOwnedLabel = 'held';

/// A member tile's headline: the piece's signed name, or its truncated id.
String nightjarCollectionMemberTitle(NightjarAssetDetailData member) {
  return member.hasName
      ? member.name!.trim()
      : truncateNightjarAssetId(member.assetId);
}

/// A member tile's supporting line.
///
/// Always the truncated `asset_id`. Section 5 of `spec/asset-metadata-v0.md`
/// requires it wherever a logo is drawn, and a grid of artwork is the place
/// that rule is most worth keeping: a hundred pictures under a hundred names
/// is exactly the surface an impersonator wants, and the id is the only thing
/// in a tile they cannot copy.
String nightjarCollectionMemberSubtitle(NightjarAssetDetailData member) {
  final index = member.index;
  final assetId = truncateNightjarAssetId(member.assetId);
  if (index == null) return assetId;
  return '#${formatGroupedInteger(index)} · $assetId';
}

// ---------------------------------------------------------------------------
// Acceptance
// ---------------------------------------------------------------------------

/// How much of a collection the user has accepted.
enum NightjarCollectionAcceptanceState {
  /// No member is accepted; no fetch has been made for any of them.
  none,

  /// Some members are accepted and some are not, which is the normal state
  /// after accepting a collection and then a later member appearing.
  partial,

  /// Every member in this view is accepted.
  all,
}

NightjarCollectionAcceptanceState nightjarCollectionAcceptanceState({
  required NightjarCollectionData collection,
  required NightjarAssetAcceptance acceptance,
}) {
  var accepted = 0;
  for (final member in collection.members) {
    if (acceptance.isAccepted(member.assetId)) accepted++;
  }
  if (accepted == 0) return NightjarCollectionAcceptanceState.none;
  if (accepted == collection.memberCount) {
    return NightjarCollectionAcceptanceState.all;
  }
  return NightjarCollectionAcceptanceState.partial;
}

/// The members of [collection] that are not yet accepted, in member order.
List<NightjarAssetDetailData> nightjarUnacceptedMembers({
  required NightjarCollectionData collection,
  required NightjarAssetAcceptance acceptance,
}) => [
  for (final member in collection.members)
    if (!acceptance.isAccepted(member.assetId)) member,
];

/// Every distinct host a collection's unaccepted members would be fetched
/// from, in first-seen order.
///
/// Plural on purpose. Members of one collection normally share a host, but
/// nothing makes them: each `uri` is signed per asset, and a user agreeing to
/// talk to one host should not thereby be agreeing to talk to a second they
/// were never shown.
List<String> nightjarCollectionFetchOrigins(
  List<NightjarAssetDetailData> members,
) {
  final origins = <String>[];
  for (final member in members) {
    final uri = member.metadataUri?.trim();
    if (uri == null || uri.isEmpty) continue;
    final parsed = Uri.tryParse(uri);
    if (parsed == null || parsed.scheme.toLowerCase() != 'https') continue;
    if (parsed.host.isEmpty) continue;
    final origin =
        '${parsed.scheme}://${parsed.host}'
        '${parsed.hasPort ? ':${parsed.port}' : ''}';
    if (!origins.contains(origin)) origins.add(origin);
  }
  return origins;
}

/// Heading for the collection acceptance card.
const String kNightjarCollectionAcceptTitle = 'Artwork for this collection';

/// The action, when there is anything to accept.
String nightjarCollectionAcceptAction(int count) {
  return count == 1
      ? 'Accept 1 piece'
      : 'Accept ${formatGroupedInteger(count)} pieces';
}

/// Withdrawing it again.
const String kNightjarCollectionForgetAction = 'Forget the whole collection';

/// What accepting a collection actually grants.
///
/// This is a policy decision dressed as a convenience, and section 5 of
/// `spec/asset-metadata-v0.md` is why it has to say so out loud. Acceptance is
/// per `asset_id` and this button does not change that — it writes one record
/// per piece, and any piece can be forgotten on its own afterwards. What it
/// *does* change is that the user makes one judgement instead of a hundred,
/// and the thing they are judging is an issuer key: `collection_id` is derived
/// from it and hashed into every member's `asset_id`, so every piece here was
/// issued by whoever holds that key, and a piece published tomorrow under the
/// same key is one more picture this decision would have covered.
String nightjarCollectionAcceptExplainer({
  required int count,
  required List<String> origins,
}) {
  final pieces = count == 1
      ? 'this 1 piece'
      : 'all ${formatGroupedInteger(count)} pieces';
  final host = switch (origins.length) {
    0 => 'the hosts their issuer chose',
    1 => origins.single,
    _ => '${formatGroupedInteger(origins.length)} hosts their issuer chose',
  };
  return 'Accepting fetches the artwork for $pieces from $host, and tells '
      'that host that someone at this address is looking at this collection. '
      'Every piece here was issued under one key — that is what a collection '
      'id is — so this is one decision about one issuer, not one about a '
      'picture.';
}

/// Why accepting one piece fetches a hundred pictures.
///
/// `spec/asset-collection-v0.md` section 2 claims the shared document
/// discloses "interest in the collection and nothing about which members", and
/// that is only true of the *document*: the artwork is still one URL per
/// piece, so the set of images a wallet asks for is exactly the set of pieces
/// it is interested in. Fetching every member's artwork makes that set a fact
/// about the collection instead of a fact about the user — which is the option
/// `spec/asset-metadata-v0.md` section 3.1 already names as the strongest one
/// available, scoped here to a collection rather than to a whole channel.
///
/// It is said out loud because the user pays for it in bandwidth and because
/// "we fetched things you did not accept" is exactly the sentence a wallet
/// should never leave a user to discover from a request log.
const String kNightjarCollectionWarmupNote =
    'Accepting also fetches the artwork for every piece in this collection, '
    'including pieces you have not accepted — the wallet does not show those. '
    'It fetches them all so that which pieces it asked the host for says '
    'nothing about which pieces are yours.';

/// The half of it that must not be lost when the card is redesigned: the
/// record underneath stays per asset.
const String kNightjarCollectionPerAssetNote =
    'The wallet still records this piece by piece, so you can forget any '
    'single one without forgetting the rest. A piece published later is not '
    'covered until you accept it too.';

/// Shown once the whole collection is accepted.
String nightjarCollectionAcceptedText(int count) {
  final pieces = count == 1
      ? '1 piece'
      : '${formatGroupedInteger(count)} pieces';
  return 'Artwork is on for $pieces of this collection.';
}

/// Shown when some but not all members are accepted — normally because the
/// collection grew after the user accepted it.
String nightjarCollectionPartialText({
  required int accepted,
  required int total,
}) {
  return 'Artwork is on for ${formatGroupedInteger(accepted)} of '
      '${formatGroupedInteger(total)} pieces. The rest have not been fetched.';
}

/// Shown on a collection whose members carry no `uri` this wallet would
/// resolve, so there is nothing to accept.
const String kNightjarCollectionNothingToFetchText =
    'No piece of this collection points at artwork this wallet would fetch.';

/// The section 5 collision warning, aggregated over a collection.
///
/// Warning once per colliding piece would be a hundred warnings; warning not
/// at all would drop the one rule that catches the impersonation. So it counts
/// them and names the ids, and the card shows the ids rather than the names —
/// the names are the part that collided.
String? nightjarCollectionCollisionText({
  required NightjarCollectionData collection,
  required NightjarAssetAcceptance acceptance,
}) {
  final colliding = <String>[];
  for (final member in collection.members) {
    if (acceptance.isAccepted(member.assetId)) continue;
    final collisions = acceptance.collisionsWith(
      assetId: member.assetId,
      name: member.name,
      symbol: member.symbol,
    );
    if (collisions.isNotEmpty) colliding.add(member.assetId);
  }
  if (colliding.isEmpty) return null;
  final subject = colliding.length == 1
      ? 'One piece of this collection shares its'
      : '${formatGroupedInteger(colliding.length)} pieces of this collection '
            'share their';
  return '$subject name or symbol with an asset you have already accepted '
      'under a different asset id. Nothing in Nightjar makes a name unique, '
      'so the ids are the only way to tell them apart.';
}

/// The ids a [nightjarCollectionCollisionText] warning is about.
List<String> nightjarCollectionCollidingIds({
  required NightjarCollectionData collection,
  required NightjarAssetAcceptance acceptance,
}) => [
  for (final member in collection.members)
    if (!acceptance.isAccepted(member.assetId) &&
        acceptance
            .collisionsWith(
              assetId: member.assetId,
              name: member.name,
              symbol: member.symbol,
            )
            .isNotEmpty)
      member.assetId,
];

// ---------------------------------------------------------------------------
// The member view
// ---------------------------------------------------------------------------

/// Shown on a unique item the user has not accepted artwork for, where the
/// artwork would otherwise be.
///
/// It is an empty frame with a sentence in it, and it stays empty: section
/// 3.1 of `spec/asset-metadata-v0.md` forbids fetching to fill a grid, and an
/// unaccepted piece is the case that rule exists for.
const String kNightjarUniqueArtworkNotFetchedText =
    'Artwork for this piece has not been fetched. The wallet asks the host '
    'only after you accept it.';

/// Accepted, and the answer has not come back yet.
const String kNightjarUniqueArtworkPendingText =
    'Fetching the artwork for this piece.';

/// Accepted, fetched, and thrown away.
///
/// This sentence is the one that used to be missing, and its absence is how a
/// missing implementation looked like a missing picture. A digest mismatch is
/// a host serving something other than what the issuer signed for
/// (`spec/asset-collection-v0.md` section 3.3), discarded **without retrying**
/// — describing that as "not fetched" would report an attack as a slow
/// network. It is still not an *error*: section 3.2 of
/// `spec/asset-metadata-v0.md` keeps a failed fetch absent rather than
/// alarming, and the asset is still an asset.
const String kNightjarUniqueArtworkRefusedText =
    'The wallet fetched artwork for this piece and would not keep it. Nothing '
    'is shown rather than something the issuer did not sign for.';

/// The tile-sized form of each of those, for a frame too small for a sentence.
const String kNightjarArtworkNotAcceptedTileText = 'Not accepted';
const String kNightjarArtworkPendingTileText = 'Fetching';
const String kNightjarArtworkRefusedTileText = 'Not shown';

/// The corner marker on a tile whose picture nothing pins.
///
/// Section 3.3: a missing or short `digests` array leaves those pieces
/// **unpinned, not invalid**, and a wallet **SHOULD** say so. A word in the
/// corner is the smallest thing that keeps a pinned and an unpinned tile from
/// looking identical, which is what the whole array is for.
const String kNightjarArtworkUnpinnedBadgeText = 'Unpinned';

/// What the empty frame of a tile says, per state.
String? nightjarArtworkTileText(NightjarArtworkStatus status) =>
    switch (status) {
      NightjarArtworkStatus.notAccepted => kNightjarArtworkNotAcceptedTileText,
      NightjarArtworkStatus.pending => kNightjarArtworkPendingTileText,
      NightjarArtworkStatus.refused => kNightjarArtworkRefusedTileText,
      // A drawn picture needs no empty-frame copy; what it needs is
      // [nightjarArtworkProvenanceText], and on a tile the unpinned badge.
      NightjarArtworkStatus.verified ||
      NightjarArtworkStatus.unpinned => null,
    };

/// The same, as a sentence, for a single piece's own screen.
String? nightjarArtworkDetailText(NightjarArtworkStatus status) =>
    switch (status) {
      NightjarArtworkStatus.notAccepted => kNightjarUniqueArtworkNotFetchedText,
      NightjarArtworkStatus.pending => kNightjarUniqueArtworkPendingText,
      NightjarArtworkStatus.refused => kNightjarUniqueArtworkRefusedText,
      NightjarArtworkStatus.verified ||
      NightjarArtworkStatus.unpinned => null,
    };

/// Where the artwork came from, and whether anything the issuer signed fixes
/// these exact bytes.
///
/// `spec/asset-collection-v0.md` section 3.3 and `spec/asset-metadata-v0.md`
/// section 2.1 both put the pinned/unpinned statement in the same place —
/// "where it says where the artwork came from" — so the origin and the pin are
/// one sentence here rather than two values a redesign can separate.
///
/// Null when there is no picture: a state with no bytes has nothing to say
/// about where they came from, and [nightjarArtworkDetailText] has already
/// said what happened.
String? nightjarArtworkProvenanceText(NightjarArtworkData data) {
  if (!data.hasImage) return null;
  final origin = data.sourceOrigin ?? 'the host its issuer chose';
  if (data.isPinned) {
    return 'Artwork from $origin, checked against the digest the issuer '
        'published for this piece.';
  }
  return 'Artwork from $origin. Nothing pins these bytes, so whoever holds '
      'that host can change them without the issuer signing anything.';
}

/// The other half of the chain: whether the *document* those bytes were named
/// by is itself pinned.
///
/// Section 3.3 spells the chain out — the `ASSET` message signs the `uri`, a
/// `#b2=` on that `uri` pins the document, and `digests` pins every image it
/// points at, so "one signature, transitively, fixes all hundred pieces". A
/// verified image under an unpinned document is pinned to a document whoever
/// holds the host can replace, which is a weaker claim than a verified image
/// alone looks like.
String? nightjarArtworkDocumentPinText(NightjarArtworkData data) {
  if (!data.hasImage) return null;
  return data.documentPinned
      ? 'The document naming it is pinned by the asset id the issuer signed.'
      : 'The document naming it is not pinned, so it is revocable by whoever '
            'holds that host.';
}

// ---------------------------------------------------------------------------
// The collection's own face
// ---------------------------------------------------------------------------

/// The corner marker on a collection face the wallet derived from a member.
///
/// `spec/asset-collection-v0.md` section 3.5.1 pairs its MAY with a MUST: a
/// wallet that falls back to a member's artwork **MUST** mark it as derived
/// rather than declared "wherever it says where a picture came from". A word
/// in the corner is the smallest thing that keeps a declared picture and a
/// borrowed one from looking identical, and it is the same discipline the
/// unpinned badge applies for the same reason — a distinction the user cannot
/// see is not a distinction.
const String kNightjarCollectionDerivedBadgeText = 'Derived';

/// Where a collection's picture came from, as one sentence.
///
/// Three facts in a fixed order, because section 3.5 and section 3.3 both
/// require them and none of them is legible on its own: whether the issuer
/// declared this picture for the collection or the wallet borrowed it from a
/// piece, which host served it, and whether anything the issuer signed fixes
/// these exact bytes.
///
/// Null when there is no picture — a state with no bytes has nothing to say
/// about where they came from.
String? nightjarCollectionArtworkProvenanceText(
  NightjarCollectionArtworkData data,
) {
  if (!data.hasImage) return null;
  final origin = data.artwork.sourceOrigin ?? 'the host its issuer chose';
  final pin = data.artwork.isPinned
      ? 'checked against the digest the issuer published for it'
      : 'and nothing pins these bytes, so whoever holds that host can change '
            'them without the issuer signing anything';
  if (!data.isDerived) {
    return 'Collection artwork from $origin, $pin.';
  }
  final piece = data.derivedFromIndex == null
      ? 'the first piece you accepted'
      : 'piece #${formatGroupedInteger(data.derivedFromIndex!)}';
  // Two different facts, and collapsing them would report a host serving
  // something the issuer never signed for as an omission by the issuer.
  final why = data.declaredLogoRefused
      ? 'The wallet fetched the artwork this collection published and would '
            'not keep it, so it is showing'
      : 'This collection published no artwork of its own, so the wallet is '
            'showing';
  return '$why $piece — from $origin, $pin.';
}

/// Every collection as a list row, in [NightjarAssetsListing.collections]
/// order — already total, so nothing re-sorts here.
///
/// [artworkFor] is how the face reaches a row without this function seeing a
/// provider: the screens read [nightjarCollectionArtworkProvider] per
/// collection and hand the answer down, so the mapper stays pure and the
/// Widgetbook fixtures can describe a declared face, a derived one and an
/// empty one without a fetcher behind them. Omitting it leaves every row
/// not-accepted, which is the state a collection is in until the user accepts
/// a member of it.
List<NightjarCollectionRowData> buildNightjarCollectionRows({
  required List<NightjarCollectionData> collections,
  void Function(String collectionId)? onCollectionTap,
  NightjarCollectionArtworkData Function(String collectionId)? artworkFor,
}) {
  return [
    for (final collection in collections)
      NightjarCollectionRowData(
        collectionId: collection.collectionId,
        title: nightjarCollectionTitle(collection),
        subtitle: nightjarCollectionSubtitle(collection),
        countText: nightjarCollectionCountText(collection),
        ownedText: nightjarCollectionOwnedText(collection),
        ownedLabel: kNightjarCollectionOwnedLabel,
        artwork:
            artworkFor?.call(collection.collectionId) ??
            const NightjarCollectionArtworkData.notAccepted(),
        onTap: onCollectionTap == null
            ? null
            : () => onCollectionTap(collection.collectionId),
      ),
  ];
}

/// The identity facts a collection screen lists.
List<NightjarAssetFactData> buildNightjarCollectionFacts(
  NightjarCollectionData collection,
) {
  return [
    NightjarAssetFactData(
      label: 'Collection id',
      value: truncateNightjarAssetId(collection.collectionId),
      copyText: collection.collectionId,
    ),
    NightjarAssetFactData(
      label: 'Pieces read',
      value: formatGroupedInteger(collection.memberCount),
    ),
    // Listed only when there is one. An uncapped collection has no ceiling to
    // print, and a row reading "None" would invite the reading that the wallet
    // failed to find one rather than that the collection declares none —
    // which, until the replay carries the cap, is exactly the ambiguity that
    // would be wrong in the more alarming direction.
    if (collection.maxSupply case final cap?)
      NightjarAssetFactData(
        label: 'Cap in the collection id',
        value: 'At most ${formatGroupedInteger(cap)}',
      ),
    NightjarAssetFactData(
      label: 'You hold',
      value: formatGroupedInteger(collection.ownedCount),
    ),
  ];
}
