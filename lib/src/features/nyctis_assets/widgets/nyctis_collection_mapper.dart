/// Every sentence the collection surfaces say, and the pure functions that
/// pick between them.
///
/// Kept apart from the widgets for the same reason `nyctis_asset_row_mapper
/// .dart` is: both form factors and the Widgetbook fixtures go through exactly
/// the same text, and the rules that matter are testable without a
/// `BuildContext`.
library;

import '../../../core/formatting/number_format.dart';
import '../models/nyctis_asset_acceptance.dart';
import 'nyctis_artwork_data.dart';
import 'nyctis_asset_row_data.dart';
import 'nyctis_collection_data.dart';

/// Heading for the card that holds the collections on the assets screen.
const String kNyctisCollectionsSectionTitle = 'Collections';

/// The heading a collection gets when the members' signed names share nothing
/// worth deriving a title from.
const String kNyctisUnnamedCollectionTitle = 'Unnamed collection';

/// The collection screen's footnote about [NyctisCollectionData.memberCount],
/// for a collection whose id binds no cap.
///
/// The number is "members this wallet can see", and the difference matters:
/// an *uncapped* `collection_id` sets no ceiling, so there is no total to
/// compare against and no way to say "3 of 100" honestly.
///
/// It says "uncapped" rather than "nothing says how many there should be":
/// since `transition-v0.md` revision 11 every collection id binds a cap, and a
/// zero cap is a statement that there is no limit — a fact read from the
/// chain, not an absence of one. The old sentence was false for every capped
/// collection. See [kNyctisCappedCollectionCountNote] for the other half and
/// [nyctisCollectionCountNote] for the choice between them.
const String kNyctisCollectionCountNote =
    'This collection is uncapped: its id sets no limit on how many pieces it '
    'can have. The count is every piece the wallet has read from the '
    'channel, not a share of a total.';

/// The same footnote for a collection whose `collection_id` binds a cap.
///
/// Two facts, and the second is the one that is easy to drop. The cap is real
/// — `transition-v0.md` section 6 step 6f ignores a public issuance whose
/// index is not strictly below it, so a piece above the cap was never applied
/// and does not exist to be shown — and the cap is still **not** a completion.
/// It bounds the collection above and says nothing about the pieces below it
/// existing yet, which is why the count reads "of at most" everywhere.
const String kNyctisCappedCollectionCountNote =
    'This collection is capped: the cap is part of its id, so every verifier '
    'refuses a piece numbered at or above it. It is a ceiling, not a total — '
    'pieces below it exist only once their issuer publishes them.';

/// Which of the two the screen shows for [collection].
String nyctisCollectionCountNote(NyctisCollectionData collection) =>
    collection.isCapped
    ? kNyctisCappedCollectionCountNote
    : kNyctisCollectionCountNote;

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
String? nyctisCollectionCapDisagreementText({
  required NyctisCollectionData collection,
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
const String kNyctisCollectionPrivacyNote =
    'Which pieces you hold is private — only this wallet can see it. Which '
    'pieces exist is public, because each was issued publicly.';

/// Shown while the first read of the channel is in flight, so a deep link or
/// a restored route does not open on "this wallet has read no pieces".
const String kNyctisCollectionLoadingText = 'Loading collection…';

/// Shown for a collection id the current view has no members for.
String nyctisUnknownCollectionText(String collectionId) {
  return 'This wallet has read no pieces of collection '
      '${truncateNyctisAssetId(collectionId)}.';
}

/// `Phases of one night` — the heading for one collection.
String nyctisCollectionTitle(NyctisCollectionData collection) =>
    collection.title ?? kNyctisUnnamedCollectionTitle;

/// The supporting line under that heading.
///
/// It always carries the truncated `collection_id`. The title above it is
/// derived from issuer-declared names, and the id is the only part of the two
/// lines that identifies anything — the same reason section 5 of
/// `spec/asset-metadata-v0.md` puts an `asset_id` beside every logo.
String nyctisCollectionSubtitle(NyctisCollectionData collection) =>
    truncateNyctisAssetId(collection.collectionId);

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
String nyctisCollectionCountText(NyctisCollectionData collection) {
  final pieces = nyctisCollectionPiecesText(collection);
  if (!collection.ownsAny) return '$pieces · none held';
  return '$pieces · you hold ${formatGroupedInteger(collection.ownedCount)}';
}

/// The public half of [nyctisCollectionCountText], as a screen reader should
/// hear it: `10 of at most 100 pieces`, `10 pieces`.
String nyctisCollectionPiecesSpokenText(NyctisCollectionData collection) {
  final text = nyctisCollectionPiecesText(collection);
  return collection.isCapped ? '$text pieces' : text;
}

/// A collection row read as one sentence: its title, the public count, how
/// many are this wallet's, and the id that identifies it.
String nyctisCollectionRowSemanticsLabel(NyctisCollectionData collection) {
  final owned = collection.ownsAny
      ? 'you hold ${formatGroupedInteger(collection.ownedCount)}'
      : 'none held';
  return '${nyctisCollectionTitle(collection)}, '
      '${nyctisCollectionPiecesSpokenText(collection)}, $owned, '
      'collection id ${nyctisCollectionSubtitle(collection)}';
}

/// The public half of [nyctisCollectionCountText]: how many pieces the
/// wallet has read, and the ceiling it is read against when there is one.
String nyctisCollectionPiecesText(NyctisCollectionData collection) {
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
String nyctisCollectionOwnedText(NyctisCollectionData collection) {
  return formatGroupedInteger(collection.ownedCount);
}

/// The label under it, so the number above is not read as a balance.
const String kNyctisCollectionOwnedLabel = 'held';

/// A member tile's headline: the piece's signed name, or its truncated id.
String nyctisCollectionMemberTitle(NyctisAssetDetailData member) {
  return member.hasName
      ? member.name!.trim()
      : truncateNyctisAssetId(member.assetId);
}

/// A member tile's supporting line.
///
/// Always the truncated `asset_id`. Section 5 of `spec/asset-metadata-v0.md`
/// requires it wherever a logo is drawn, and a grid of artwork is the place
/// that rule is most worth keeping: a hundred pictures under a hundred names
/// is exactly the surface an impersonator wants, and the id is the only thing
/// in a tile they cannot copy.
String nyctisCollectionMemberSubtitle(NyctisAssetDetailData member) {
  final index = member.index;
  final assetId = truncateNyctisAssetId(member.assetId);
  if (index == null) return assetId;
  return '#${formatGroupedInteger(index)} · $assetId';
}

// ---------------------------------------------------------------------------
// Acceptance
// ---------------------------------------------------------------------------

/// How much of a collection the user has accepted.
enum NyctisCollectionAcceptanceState {
  /// No member is accepted; no fetch has been made for any of them.
  none,

  /// Some members are accepted and some are not, which is the normal state
  /// after accepting a collection and then a later member appearing.
  partial,

  /// Every member in this view is accepted.
  all,
}

NyctisCollectionAcceptanceState nyctisCollectionAcceptanceState({
  required NyctisCollectionData collection,
  required NyctisAssetAcceptance acceptance,
}) {
  var accepted = 0;
  for (final member in collection.members) {
    if (acceptance.isAccepted(member.assetId)) accepted++;
  }
  if (accepted == 0) return NyctisCollectionAcceptanceState.none;
  if (accepted == collection.memberCount) {
    return NyctisCollectionAcceptanceState.all;
  }
  return NyctisCollectionAcceptanceState.partial;
}

/// The members of [collection] that are not yet accepted, in member order.
List<NyctisAssetDetailData> nyctisUnacceptedMembers({
  required NyctisCollectionData collection,
  required NyctisAssetAcceptance acceptance,
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
List<String> nyctisCollectionFetchOrigins(
  List<NyctisAssetDetailData> members,
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
const String kNyctisCollectionAcceptTitle = 'Artwork for this collection';

/// The action, when there is anything to accept.
///
/// "Show", everywhere this wallet asks to fetch issuer content: the asset
/// card, a piece's own page and this card use the one verb, so the user
/// makes one kind of decision rather than learning three names for it.
String nyctisCollectionAcceptAction(int count) {
  return count == 1
      ? 'Show artwork for 1 piece'
      : 'Show artwork for ${formatGroupedInteger(count)} pieces';
}

/// Withdrawing it again. "Stop showing", never "forget": the pieces stay in
/// the wallet whatever this does, and "forget the whole collection" read as
/// deleting them.
const String kNyctisCollectionForgetAction =
    'Stop showing artwork for this collection';

/// The label of the disclosure that holds everything past the first sentence.
const String kNyctisWhatThisMeansTitle = 'What this means';

/// Who learns something when the wallet contacts an issuer's host. The
/// address meant is the network one, not the user's Nyctis address.
const String kNyctisWhoLearnsText =
    'someone at your IP address (or your Tor exit)';

/// The one sentence the collection card says before its button.
String nyctisCollectionAcceptLead({required List<String> origins}) {
  final host = _hostPhrase(origins);
  return 'Showing artwork contacts $host, which learns that '
      '$kNyctisWhoLearnsText is looking at this collection.';
}

String _hostPhrase(List<String> origins) => switch (origins.length) {
  0 => 'the hosts its issuer chose',
  1 => origins.single,
  _ => '${formatGroupedInteger(origins.length)} hosts its issuer chose',
};

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
String nyctisCollectionAcceptExplainer({
  required int count,
  required List<String> origins,
}) {
  final pieces = count == 1
      ? 'this 1 piece'
      : 'all ${formatGroupedInteger(count)} pieces';
  return 'This shows the artwork for $pieces from ${_hostPhrase(origins)}. '
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
///
/// It states the bound the warm-up actually has. Past it the tail is fetched
/// per tile as the user scrolls, which is the residual leak the provider's
/// own header names, and a sentence promising "says nothing about which
/// pieces are yours" without that bound would promise more privacy than a
/// large collection gets.
String nyctisCollectionWarmupNote({int? maxBytes}) {
  final bound = maxBytes == null
      ? 'up to a size limit'
      : 'up to ${formatNyctisByteSize(maxBytes)} in total';
  return 'So that the host cannot tell which pieces are yours, the wallet also '
      'fetches the artwork for every other piece in this collection, $bound, '
      'and does not show the ones you have not chosen to see. Past that '
      'limit, the remaining pieces are fetched one at a time as you scroll, '
      'which can show the host which ones you look at.';
}

/// `4 MiB`, `512 KiB` — a byte budget in the binary units the wallet counts
/// it in.
String formatNyctisByteSize(int bytes) {
  const kib = 1024;
  const mib = 1024 * 1024;
  if (bytes >= mib && bytes % mib == 0) return '${bytes ~/ mib} MiB';
  if (bytes >= kib && bytes % kib == 0) {
    return '${formatGroupedInteger(bytes ~/ kib)} KiB';
  }
  return '${formatGroupedInteger(bytes)} bytes';
}

/// The half of it that must not be lost when the card is redesigned: the
/// record underneath stays per asset.
const String kNyctisCollectionPerAssetNote =
    'The wallet still records this piece by piece, so you can stop showing '
    'any single one without affecting the rest. A piece published later is '
    'not shown until you choose to show it too.';

/// Shown once the whole collection is accepted.
String nyctisCollectionAcceptedText(int count) {
  final pieces = count == 1
      ? '1 piece'
      : '${formatGroupedInteger(count)} pieces';
  return 'Artwork is on for $pieces of this collection.';
}

/// Shown while the warm-up is running, so a large collection is not a grid
/// of "Fetching" tiles with no overall progress.
const String kNyctisCollectionWarmupRunningText =
    'Fetching artwork for this collection…';

/// What the finished warm-up covered, in pieces rather than bytes.
///
/// When it stopped at its budget it says what that means for the rest, in the
/// same words as [nyctisCollectionWarmupNote].
String nyctisCollectionWarmupProgressText({
  required int fetched,
  required int total,
  required bool complete,
}) {
  final covered =
      'Fetched artwork for ${formatGroupedInteger(fetched)} of '
      '${formatGroupedInteger(total)} pieces.';
  if (complete) return covered;
  return '$covered The rest are fetched one at a time as you scroll, which '
      'can show the host which ones you look at.';
}

/// Shown when some but not all members are accepted — normally because the
/// collection grew after the user accepted it.
String nyctisCollectionPartialText({
  required int accepted,
  required int total,
}) {
  return 'Artwork is on for ${formatGroupedInteger(accepted)} of '
      '${formatGroupedInteger(total)} pieces. The rest have not been fetched.';
}

/// Shown on a collection whose members carry no `uri` this wallet would
/// resolve, so there is nothing to accept.
const String kNyctisCollectionNothingToFetchText =
    'No piece of this collection points at artwork this wallet would fetch.';

/// The section 5 collision warning, aggregated over a collection.
///
/// Warning once per colliding piece would be a hundred warnings; warning not
/// at all would drop the one rule that catches the impersonation. So it counts
/// them and names the ids, and the card shows the ids rather than the names —
/// the names are the part that collided.
String? nyctisCollectionCollisionText({
  required NyctisCollectionData collection,
  required NyctisAssetAcceptance acceptance,
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
  return '$subject name or symbol with an asset you already show artwork '
      'for, under a different asset id. That is how an impersonator looks. '
      'Nothing in Nyctis makes a name unique, so compare the asset ids '
      'below.';
}

/// One piece of a collection whose name or symbol matches an asset the user
/// already accepted, and the asset it matches.
class NyctisCollectionCollision {
  const NyctisCollectionCollision({
    required this.memberId,
    required this.memberLabel,
    required this.existingId,
    required this.existingLabel,
  });

  final String memberId;
  final String memberLabel;
  final String existingId;
  final String existingLabel;
}

/// Every colliding (piece, accepted asset) pair, in member order.
List<NyctisCollectionCollision> nyctisCollectionCollisions({
  required NyctisCollectionData collection,
  required NyctisAssetAcceptance acceptance,
}) => [
  for (final member in collection.members)
    if (!acceptance.isAccepted(member.assetId))
      for (final collision in acceptance.collisionsWith(
        assetId: member.assetId,
        name: member.name,
        symbol: member.symbol,
      ))
        NyctisCollectionCollision(
          memberId: member.assetId,
          memberLabel: nyctisCollectionMemberTitle(member),
          existingId: collision.existing.assetId,
          existingLabel: nyctisAcceptedAssetLabel(collision.existing),
        ),
];

/// How an already-accepted asset is named beside its id in a collision.
String nyctisAcceptedAssetLabel(NyctisAcceptedAsset asset) {
  final name = asset.name?.trim() ?? '';
  if (name.isNotEmpty) return name;
  final symbol = asset.symbol?.trim() ?? '';
  if (symbol.isNotEmpty) return symbol;
  return 'Unnamed asset';
}

/// The ids a [nyctisCollectionCollisionText] warning is about.
List<String> nyctisCollectionCollidingIds({
  required NyctisCollectionData collection,
  required NyctisAssetAcceptance acceptance,
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
const String kNyctisUniqueArtworkNotFetchedText =
    'Artwork is not shown. Showing it contacts the host its issuer chose.';

/// The inline button on that frame. Same verb as every other acceptance.
const String kNyctisShowArtworkAction = 'Show artwork';

/// Stops showing one piece's artwork.
const String kNyctisStopShowingArtworkAction = 'Stop showing artwork';

/// Accepted, and the answer has not come back yet.
const String kNyctisUniqueArtworkPendingText =
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
const String kNyctisUniqueArtworkRefusedText =
    'The wallet fetched artwork for this piece and would not keep it. Nothing '
    'is shown rather than something the issuer did not sign for.';

/// The tile-sized form of each of those, for a frame too small for a sentence.
const String kNyctisArtworkNotAcceptedTileText = 'Not shown';
const String kNyctisArtworkPendingTileText = 'Fetching';
const String kNyctisArtworkRefusedTileText = 'Refused';

/// The corner marker on a tile whose picture nothing pins.
///
/// Section 3.3: a missing or short `digests` array leaves those pieces
/// **unpinned, not invalid**, and a wallet **SHOULD** say so. A word in the
/// corner is the smallest thing that keeps a pinned and an unpinned tile from
/// looking identical, which is what the whole array is for.
const String kNyctisArtworkUnpinnedBadgeText = 'Unpinned';

/// What the empty frame of a tile says, per state.
String? nyctisArtworkTileText(NyctisArtworkStatus status) =>
    switch (status) {
      NyctisArtworkStatus.notAccepted => kNyctisArtworkNotAcceptedTileText,
      NyctisArtworkStatus.pending => kNyctisArtworkPendingTileText,
      NyctisArtworkStatus.refused => kNyctisArtworkRefusedTileText,
      // A drawn picture needs no empty-frame copy; what it needs is
      // [nyctisArtworkProvenanceText], and on a tile the unpinned badge.
      NyctisArtworkStatus.verified ||
      NyctisArtworkStatus.unpinned => null,
    };

/// The same, as a sentence, for a single piece's own screen.
String? nyctisArtworkDetailText(NyctisArtworkStatus status) =>
    switch (status) {
      NyctisArtworkStatus.notAccepted => kNyctisUniqueArtworkNotFetchedText,
      NyctisArtworkStatus.pending => kNyctisUniqueArtworkPendingText,
      NyctisArtworkStatus.refused => kNyctisUniqueArtworkRefusedText,
      NyctisArtworkStatus.verified ||
      NyctisArtworkStatus.unpinned => null,
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
/// about where they came from, and [nyctisArtworkDetailText] has already
/// said what happened.
String? nyctisArtworkProvenanceText(NyctisArtworkData data) {
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
String? nyctisArtworkDocumentPinText(NyctisArtworkData data) {
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
const String kNyctisCollectionDerivedBadgeText = 'Derived';

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
String? nyctisCollectionArtworkProvenanceText(
  NyctisCollectionArtworkData data,
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

/// Every collection as a list row, in [NyctisAssetsListing.collections]
/// order — already total, so nothing re-sorts here.
///
/// [artworkFor] is how the face reaches a row without this function seeing a
/// provider: the screens read [nyctisCollectionArtworkProvider] per
/// collection and hand the answer down, so the mapper stays pure and the
/// Widgetbook fixtures can describe a declared face, a derived one and an
/// empty one without a fetcher behind them. Omitting it leaves every row
/// not-accepted, which is the state a collection is in until the user accepts
/// a member of it.
List<NyctisCollectionRowData> buildNyctisCollectionRows({
  required List<NyctisCollectionData> collections,
  void Function(String collectionId)? onCollectionTap,
  NyctisCollectionArtworkData Function(String collectionId)? artworkFor,
}) {
  return [
    for (final collection in collections)
      NyctisCollectionRowData(
        collectionId: collection.collectionId,
        title: nyctisCollectionTitle(collection),
        subtitle: nyctisCollectionSubtitle(collection),
        // The public count only: the owned count is the right-hand column,
        // and saying it in both places read it twice.
        countText: nyctisCollectionPiecesText(collection),
        ownedText: nyctisCollectionOwnedText(collection),
        ownedLabel: kNyctisCollectionOwnedLabel,
        semanticsLabel: nyctisCollectionRowSemanticsLabel(collection),
        artwork:
            artworkFor?.call(collection.collectionId) ??
            const NyctisCollectionArtworkData.notAccepted(),
        onTap: onCollectionTap == null
            ? null
            : () => onCollectionTap(collection.collectionId),
      ),
  ];
}

/// The identity facts a collection screen lists.
List<NyctisAssetFactData> buildNyctisCollectionFacts(
  NyctisCollectionData collection,
) {
  return [
    NyctisAssetFactData(
      label: 'Collection id',
      value: truncateNyctisAssetId(collection.collectionId),
      copyText: collection.collectionId,
    ),
    NyctisAssetFactData(
      label: 'Pieces read',
      value: formatGroupedInteger(collection.memberCount),
    ),
    // Always listed. The replay reads the cap bound into the id, and a zero
    // cap is the collection saying it has none, so "Uncapped" is a fact
    // from the chain rather than a failure to find a number.
    NyctisAssetFactData(
      label: kNyctisCollectionCapLabel,
      value: nyctisCollectionCapValue(collection),
    ),
    NyctisAssetFactData(
      label: 'You hold',
      value: formatGroupedInteger(collection.ownedCount),
    ),
  ];
}

/// Label of the collection's cap row.
const String kNyctisCollectionCapLabel = 'Cap in the collection id';

/// Its value: `At most 100`, or `Uncapped`.
String nyctisCollectionCapValue(NyctisCollectionData collection) {
  final cap = collection.maxSupply;
  return cap == null ? 'Uncapped' : 'At most ${formatGroupedInteger(cap)}';
}

/// What a screen reader hears for one tile: the piece, whether it is this
/// wallet's, what its artwork frame is showing, and its id.
///
/// Wallet-authored words only. The artwork's own alt text is issuer-chosen
/// and is never read (see `NyctisAssetLogoImage`).
String nyctisCollectionTileSemanticsLabel({
  required NyctisAssetDetailData member,
  required NyctisArtworkStatus status,
}) {
  return '${nyctisCollectionMemberTitle(member)}, '
      '${member.ownsUniqueItem ? 'yours' : 'not yours'}, '
      '${nyctisArtworkSpokenState(status)}, '
      'asset id ${truncateNyctisAssetId(member.assetId)}';
}

/// The artwork frame's state as words, for the image's accessible name.
String nyctisArtworkSpokenState(NyctisArtworkStatus status) =>
    switch (status) {
      NyctisArtworkStatus.notAccepted => 'artwork not shown',
      NyctisArtworkStatus.pending => 'artwork loading',
      NyctisArtworkStatus.refused => 'artwork refused',
      NyctisArtworkStatus.verified => 'artwork shown',
      NyctisArtworkStatus.unpinned => 'artwork shown, unpinned',
    };
