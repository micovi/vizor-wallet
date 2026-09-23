/// Collections, and the rule that decides which assets form one.
///
/// Nyctis has no NFT type and no collection object. A collection is a
/// `collection_id` — derived from the issuer's key and a label — that several
/// `ASSET` messages happen to name, and a unique item is an ordinary public
/// asset issued with `max_supply = 1` at `decimals = 0`. Both facts are on
/// chain and both are hashed into `asset_id`, so neither is something a wallet
/// takes on trust; but neither is a *container* either. There is nothing to
/// fetch called "the collection", nothing that says how many members it has,
/// and no signed name for it. Everything in this file is derived from the
/// members the replay reports, and the copy is careful to say so.
///
/// Nothing here imports Flutter widgets, Riverpod, or the generated Rust
/// bindings.
library;

import 'package:flutter/widgets.dart' show VoidCallback;

import 'nyctis_artwork_data.dart';
import 'nyctis_asset_row_data.dart';

/// How many unique-item members a `collection_id` needs before the assets
/// screen folds them into one entry.
///
/// Two, and the threshold is doing real work at that value rather than being
/// a round number. A group exists to stop N rows from saying the same thing;
/// with one member it is strictly worse than no group at all — it costs a tap
/// to reach the only thing behind it, and it replaces the piece's own signed
/// name with a label derived from that same one name. At two the trade turns
/// over: two rows become one entry that states a count the rows could not.
///
/// It is deliberately not "3 or more, because two rows are fine". Two is where
/// the collection first *exists* as something the wallet can say a true
/// sentence about, and hiding it until three would make the assets screen's
/// shape depend on how much of a collection the channel had published yet.
const int kNyctisCollectionMinMembers = 2;

/// One `collection_id` and the members of it this view knows about.
class NyctisCollectionData {
  const NyctisCollectionData({
    required this.collectionId,
    required this.members,
    this.maxSupply,
  });

  /// Hex `collection_id`. The only true identifier a collection has: there is
  /// no signed name for one, and [title] is derived.
  final String collectionId;

  /// The cap bound into [collectionId], or null when the collection is
  /// uncapped or the wallet has not read one.
  ///
  /// **Not a document member.** A collection document carries its own
  /// `max_supply` (`asset-collection-v0.md` section 3.1) and that one is
  /// advisory; this one is `transition-v0.md` section 5's, hashed into the id
  /// and enforced at section 6 step 6f, so no member above it was ever
  /// applied. It is what the document's copy has to be compared against
  /// rather than believed.
  ///
  /// **A cap is not a completion.** It says no member above it will ever
  /// exist; it says nothing about the members below it existing yet. So the
  /// copy reads "3 of at most 10,000", never "3 of 10,000" — step 6f is
  /// explicit that the second is not honest.
  ///
  /// Null for an uncapped collection: the replay reads a zero cap as
  /// uncapped. See [NyctisAssetDetailData.collectionMaxSupply].
  final int? maxSupply;

  /// Whether a verifier enforces a ceiling on this collection.
  bool get isCapped => maxSupply != null;

  /// The members, ordered by [NyctisAssetDetailData.index] where the wallet
  /// has one and by `asset_id` where it has not. Never empty.
  final List<NyctisAssetDetailData> members;

  /// Members this view carries.
  ///
  /// This is **not** "how large the collection is", and the copy must never
  /// claim it is. The replay lists every publicly issued asset on the channel
  /// plus every asset this wallet has held a note of, so for a collection
  /// issued publicly the two numbers coincide — but a member issued privately,
  /// or one issued above the finality cut-off, is simply not here, and nothing
  /// in `collection_id` carries a cardinality to check against.
  int get memberCount => members.length;

  /// Members this wallet holds right now. Private, like every Nyctis
  /// balance: nobody else can compute it.
  int get ownedCount {
    var owned = 0;
    for (final member in members) {
      if (member.balance > BigInt.zero) owned++;
    }
    return owned;
  }

  bool get ownsAny => ownedCount > 0;

  /// The `asset_id`s of the members, in [members] order.
  List<String> get memberIds => [for (final m in members) m.assetId];

  /// A display name for the collection, derived from the members' signed
  /// names, or null when they yield nothing usable.
  ///
  /// Derived, and safe to derive, for one specific reason: `collection_id`
  /// comes from the issuer's key, and it is hashed into every member's
  /// `asset_id`. Nobody can add a member to somebody else's collection. So a
  /// prefix shared by two or more member names is a statement by one issuer
  /// about assets that are provably all theirs — exactly as trustworthy as the
  /// names already shown on every row, and no more.
  ///
  /// It is still issuer-declared text, so [collectionId] is shown beside it
  /// everywhere rather than replaced by it.
  String? get title => _derivedCollectionTitle(members);
}

/// The assets screen's whole list: collections, then everything else.
class NyctisAssetsListing {
  const NyctisAssetsListing({
    required this.collections,
    required this.ungrouped,
  });

  const NyctisAssetsListing.empty()
    : collections = const [],
      ungrouped = const [];

  /// Grouped collections, ordered by [NyctisCollectionData.title] and then
  /// by `collection_id` so the order is total and survives a re-replay.
  final List<NyctisCollectionData> collections;

  /// Every asset that is not a member of a grouped collection — every
  /// fungible token, every private asset, and every unique item whose
  /// collection has too few members to be worth folding.
  final List<NyctisAssetDetailData> ungrouped;

  bool get isEmpty => collections.isEmpty && ungrouped.isEmpty;

  /// The `asset_id`s that are rendered inside a collection rather than as a
  /// row of their own.
  ///
  /// The logo providers use this to keep their eager work proportional to the
  /// flat list rather than to the channel: a hundred-piece collection puts a
  /// hundred ids in here and none of them in the list that is fetched up
  /// front.
  Set<String> get groupedMemberIds => {
    for (final collection in collections) ...collection.memberIds,
  };

  NyctisCollectionData? collectionById(String collectionId) {
    for (final collection in collections) {
      if (collection.collectionId == collectionId) return collection;
    }
    return null;
  }
}

/// Splits [assets] into collections and everything else.
///
/// Two rules, and the second is the one that keeps ordinary tokens working.
///
/// * A collection is a `collection_id` with at least
///   [kNyctisCollectionMinMembers] members in this view.
/// * **Only unique items group.** A `collection_id` is not a claim about what
///   kind of assets it holds, and fungible ones share them in practice — on
///   the reference devnet `NIGHTJAR` and `NIGHTCASH` are two ordinary tokens
///   issued into one collection at indices 0 and 1. Grouping on
///   `collection_id` alone would replace those two balances with one entry
///   reading "2 pieces", which is both wrong and the exact regression a
///   grouping change is most likely to cause. The reason to fold a hundred
///   rows together is that each of them says "1" and none of them means it;
///   that reason does not apply to a balance.
///
/// A collection with a mix of unique and fungible members groups the unique
/// ones and leaves the fungible ones as rows. That is not a fudge: the
/// fungible member is still a balance and still has to render as one.
NyctisAssetsListing groupNyctisCollections(
  List<NyctisAssetDetailData> assets,
) {
  final byCollection = <String, List<NyctisAssetDetailData>>{};
  for (final asset in assets) {
    if (!asset.isUniqueItem) continue;
    final collectionId = asset.collection?.trim();
    if (collectionId == null || collectionId.isEmpty) continue;
    (byCollection[collectionId] ??= []).add(asset);
  }

  final collections = <NyctisCollectionData>[];
  final grouped = <String>{};
  for (final entry in byCollection.entries) {
    if (entry.value.length < kNyctisCollectionMinMembers) continue;
    final members = [...entry.value]..sort(compareNyctisCollectionMembers);
    collections.add(
      NyctisCollectionData(
        collectionId: entry.key,
        members: members,
        maxSupply: _collectionMaxSupply(members),
      ),
    );
    for (final member in members) {
      grouped.add(member.assetId);
    }
  }
  collections.sort(_compareCollections);

  return NyctisAssetsListing(
    collections: collections,
    ungrouped: [
      for (final asset in assets)
        if (!grouped.contains(asset.assetId)) asset,
    ],
  );
}

/// Members in the issuer's declared order where the wallet has read one, and
/// by `asset_id` where it has not.
///
/// The fallback is a hash order and is meaningless as a sequence — it is here
/// only so that two replays of one channel produce one order. Nothing renders
/// a member's position in this list as if it were its edition number; that is
/// what [NyctisAssetDetailData.index] is for. The FFI carries it now, so the
/// fallback below is reached only by a member the replay reported without a
/// public issuance — which is also a member with no `collection_id`, and so
/// not a member of a collection this function ever groups.
int compareNyctisCollectionMembers(
  NyctisAssetDetailData a,
  NyctisAssetDetailData b,
) {
  final ai = a.index;
  final bi = b.index;
  if (ai != null && bi != null && ai != bi) return ai.compareTo(bi);
  if (ai != null && bi == null) return -1;
  if (ai == null && bi != null) return 1;
  return a.assetId.compareTo(b.assetId);
}

/// The cap the members agree on, or null when none of them carries one.
///
/// The first non-null wins and nothing reconciles a disagreement, because a
/// disagreement is not representable: `transition-v0.md` section 5 hashes the
/// cap into `collection_id`, so two members declaring different caps are
/// members of two different collections and this function was handed one of
/// them. Reading it off any member is therefore reading it off all of them.
int? _collectionMaxSupply(List<NyctisAssetDetailData> members) {
  for (final member in members) {
    final cap = member.collectionMaxSupply;
    if (cap != null && cap > 0) return cap;
  }
  return null;
}

int _compareCollections(NyctisCollectionData a, NyctisCollectionData b) {
  final at = a.title;
  final bt = b.title;
  if (at != null && bt != null) {
    final byTitle = at.toLowerCase().compareTo(bt.toLowerCase());
    if (byTitle != 0) return byTitle;
  } else if (at != null) {
    return -1;
  } else if (bt != null) {
    return 1;
  }
  return a.collectionId.compareTo(b.collectionId);
}

/// The longest prefix shared by every member's signed name, trimmed back to
/// something a heading can carry.
///
/// Returns null rather than a fragment: a one- or two-character remnant of
/// two unrelated names is noise dressed as a title, and the truncated
/// `collection_id` is a better heading than that.
String? _derivedCollectionTitle(List<NyctisAssetDetailData> members) {
  String? prefix;
  for (final member in members) {
    final name = member.name?.trim() ?? '';
    if (name.isEmpty) return null;
    prefix = prefix == null ? name : _commonPrefix(prefix, name);
    if (prefix.isEmpty) return null;
  }
  if (prefix == null) return null;
  // Trailing separators and digits are where a per-piece suffix begins:
  // `Phases of one night #7` and `… #8` share `Phases of one night #`.
  final trimmed = prefix.replaceAll(RegExp(r'[\s\-–—_#:.,/()\[\]0-9]+$'), '');
  return trimmed.length < 3 ? null : trimmed;
}

String _commonPrefix(String a, String b) {
  final limit = a.length < b.length ? a.length : b.length;
  var i = 0;
  while (i < limit && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  return a.substring(0, i);
}

/// One collection as the assets list draws it.
///
/// Flat values rather than the collection itself, so the feed stays a widget
/// that renders what it is handed and the Widgetbook fixtures can describe a
/// hundred-piece collection without a hundred assets behind it.
class NyctisCollectionRowData {
  const NyctisCollectionRowData({
    required this.collectionId,
    required this.title,
    required this.subtitle,
    required this.countText,
    required this.ownedText,
    required this.ownedLabel,
    this.artwork = const NyctisCollectionArtworkData.notAccepted(),
    this.semanticsLabel,
    this.onTap,
  });

  /// Hex `collection_id` — what the row is really about.
  final String collectionId;

  /// Derived from the members' signed names, or the unnamed fallback.
  final String title;

  /// The truncated `collection_id`, always.
  final String subtitle;

  /// `100 pieces`, or `10 of at most 100` for a capped collection — the
  /// public count only. How many are this wallet's is [ownedText], said once.
  final String countText;

  /// The right-hand figure: how many pieces are this wallet's.
  final String ownedText;
  final String ownedLabel;

  /// The collection's face (`spec/asset-collection-v0.md` section 3.5), and
  /// whether the issuer declared it or the wallet derived it from a member.
  ///
  /// Defaults to not-accepted, which is the only safe default for a value that
  /// decides whether an issuer's picture is drawn, and is also the truthful
  /// one for a fixture: section 3.5 forbids fetching or displaying a
  /// collection's picture before the user has accepted a member of it.
  final NyctisCollectionArtworkData artwork;

  /// The whole row as one spoken sentence, e.g. `Phases of One Night, 10 of
  /// at most 100 pieces, you hold 3, collection id c0ffee…e5f4aa`.
  final String? semanticsLabel;

  final VoidCallback? onTap;
}
