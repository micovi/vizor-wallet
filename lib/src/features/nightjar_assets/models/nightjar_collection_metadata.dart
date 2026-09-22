/// The collection metadata document (`spec/asset-collection-v0.md`) as a typed
/// value, plus the parser and the one substitution rule that makes the shared
/// form safe.
///
/// A hundred-piece collection could have been a hundred documents. It is one,
/// because `asset-collection-v0.md` section 2 makes that the *private* shape:
/// a hundred documents is up to a hundred requests whose pattern discloses
/// which pieces a wallet cares about, and one document discloses interest in
/// the collection and nothing about its members. Everything below exists to
/// make one document describe a hundred pieces without letting it decide which
/// piece is which.
///
/// **The index is on-chain and nothing here may override it.** Section 1:
///
/// ```
/// asset_id = Poseidon_3(DS_ASSET, collection_id, label, terms)
/// terms carries index and max_supply
/// ```
///
/// so a document cannot lie about which piece is which — change the index and
/// the `asset_id` no longer derives. That is the whole load-bearing property
/// of the shared form, and it is thrown away the moment a wallet substitutes
/// an index the *document* supplied. So [NightjarCollectionMetadata.memberAt]
/// takes the index as an argument, there is no `index` member parsed at the
/// top level of the document, and the `index` inside an `items` entry
/// (section 3.4) is used only to *select* an override — never as the value
/// substituted into the template.
///
/// Every rule of `asset-metadata-v0.md` still applies to anything fetched
/// through here: `https:` only, SVG refused, the 16 KiB document and 256 KiB
/// image limits, one 10 s budget, redirects compared against the origin the
/// fetch started at. None of that is re-stated here because none of it is
/// relaxed — see `nightjar_metadata_reader.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../services/nightjar_metadata_digest.dart';
import 'nightjar_asset_metadata.dart';

/// The schema family this document is written in. Section 3.1.
const String kNightjarCollectionSchemaFamily = 'nightjar-collection-metadata';

/// The only major this revision implements. `asset-metadata-v0.md` section 4.4
/// applies unchanged: the major is the compatibility boundary and the only
/// one, and a document whose major we do not implement is rejected rather than
/// read best-effort.
const int kNightjarCollectionSchemaMajor = 1;

/// Section 3.1: `name` is at most 48 characters.
const int kNightjarCollectionMaxNameChars = 48;

/// Section 3.1: `description` is at most 1 000 characters of plain text — the
/// same bound `asset-metadata-v0.md` section 4.1 puts on an asset's.
const int kNightjarCollectionMaxDescriptionChars = 1000;

/// Section 3.4: at most 16 attributes per item, each string ≤ 48 characters.
const int kNightjarItemMaxAttributes = 16;
const int kNightjarItemAttributeMaxChars = 48;

/// The literal token, and the only one. Section 3.2: "nothing else is
/// substituted", and a wallet **MUST NOT** substitute anything a document asks
/// for that the specification has not defined.
const String kNightjarIndexToken = '{index}';

/// Why a resolved member has no artwork to fetch.
///
/// Section 3.2: a template whose substituted result is not a valid absolute
/// URI is rejected, and the wallet **MUST** treat that as *the piece* having no
/// artwork rather than the collection being invalid. So these are per-piece
/// facts, never a reason to discard the document.
enum NightjarItemImageRejection {
  /// The document carried no `item.image` and no override for this index.
  absent,

  /// The substituted string still carries a `{…}` token. Section 3.2 defines
  /// exactly one token and forbids substituting any other, so the rest are
  /// left literal — and a literal brace is not a character RFC 3986 allows in
  /// a URI, so the result is not one this wallet will request. Naming the case
  /// rather than letting it fall out of a lenient `Uri.parse` is the point:
  /// Dart's parser would happily accept `https://h/{phase}.png` and the wallet
  /// would put an undefined token on the wire.
  unresolvedToken,

  /// Not `https:` after substitution, or no host. Section 3.2 defers to
  /// `asset-metadata-v0.md` section 2 for the scheme, and section 2 is a MUST.
  notHttps,
}

/// The `item` template (section 3.2).
class NightjarCollectionItemTemplate {
  const NightjarCollectionItemTemplate({this.name, this.image});

  /// `Phases of One Night #{index}`, verbatim. Substituted at resolve time
  /// rather than at parse time, because the value that goes in is a fact about
  /// a *member* and this object describes the collection.
  final String? name;

  /// `https://example.invalid/pon/{index}.png`, verbatim, and deliberately a
  /// `String` rather than a `Uri`: it is not a URI until an index has been
  /// substituted into it, and typing it as one would invite a caller to
  /// request the template.
  final String? image;

  bool get isEmpty => name == null && image == null;
}

/// One `{ "trait": …, "value": … }` of an `items` entry (section 3.4).
class NightjarItemAttribute {
  const NightjarItemAttribute({required this.trait, required this.value});

  final String trait;
  final String value;
}

/// One entry of the optional `items` array (section 3.4) — per-piece detail
/// for the handful of pieces that differ from the template.
///
/// Section 3.4 is blunt about the cost and the comment is kept here because
/// the shape invites the opposite: adding one attribute to each of 100 members
/// took the reference document from 5 818 to 20 065 bytes, past the 16 KiB
/// limit. `items` is for a few exceptions, not for traits across a collection.
class NightjarCollectionItemOverride {
  const NightjarCollectionItemOverride({
    required this.index,
    this.name,
    this.description,
    this.image,
    this.digestB2,
    this.attributes = const [],
  });

  /// Which member this overrides.
  ///
  /// **A selector, never a substitution.** Section 3.2's index comes from the
  /// chain; this one says which piece the entry is *about*, and a wallet that
  /// let it flow into the template would hand the document the power section 1
  /// spends the whole `asset_id` derivation denying it.
  final int index;

  final String? name;
  final String? description;

  /// An absolute `https:` URI. No token is substituted into an override's
  /// `image`: it names one piece already, so there is no index to put in it,
  /// and substituting one would mean two different rules for one member.
  final Uri? image;

  /// `BLAKE2b-256` of that image, base64url unpadded — the same form as
  /// `logo.b2` (`asset-metadata-v0.md` section 4.2). Overrides `digests[i]`.
  final String? digestB2;

  final List<NightjarItemAttribute> attributes;
}

/// One member of a collection, resolved against its **on-chain** index.
///
/// Produced by [NightjarCollectionMetadata.memberAt] and by nothing else, so
/// there is no way to build one of these without having said which index it
/// is for.
class NightjarCollectionMember {
  const NightjarCollectionMember({
    required this.index,
    required this.name,
    required this.description,
    required this.image,
    required this.digestB2,
    required this.imageRejection,
    required this.attributes,
  });

  /// The on-chain index this was resolved for.
  final int index;

  /// `item.name` with the index substituted, or an `items` override, or null.
  /// Decoration: the signed `name` on the `ASSET` message still wins wherever
  /// the two are shown together (`asset-metadata-v0.md` section 1).
  final String? name;

  final String? description;

  /// The image to fetch, or null — see [imageRejection] for which.
  final Uri? image;

  /// `digests[index]`, or an override's `b2`, or null.
  ///
  /// Null means **unpinned, not invalid** (section 3.3): a missing or short
  /// `digests` array leaves those pieces revocable by whoever holds the host,
  /// and section 3.3 says a wallet SHOULD say so where it says where the
  /// artwork came from. That is why this is on the member rather than being
  /// folded into a bool the UI cannot tell apart from "verified".
  final String? digestB2;

  /// Why there is no [image], when there is none.
  final NightjarItemImageRejection? imageRejection;

  final List<NightjarItemAttribute> attributes;

  /// Whether `digests` pins this piece's artwork. Section 3.3: this is the
  /// entire value of the array, so it is a value the UI renders, not a detail
  /// the fetcher keeps to itself.
  bool get isPinned => digestB2 != null;

  bool get hasImage => image != null;
}

/// A parsed collection document.
/// `digest_table` — section 3.3.1's pointer at a collection's digests.
///
/// The document carries this instead of `digests` when the collection is too
/// large to hold its digests inline. At 51 bytes a member the inline array
/// reaches the 16 KiB document limit at 302; the table is 32 raw bytes a
/// member, and it lives outside the document, so the document stops growing
/// with the collection entirely.
///
/// That is the point of it, and it is a privacy property rather than a size
/// one: a document that is constant in `N` is a document every member can
/// sign the **same** `uri` for, at any collection size. The obvious
/// alternative — splitting `digests` across several documents — gives each
/// range its own signed `uri`, and then *which* one a wallet fetches is a
/// fact about which pieces it holds.
/// A `BLAKE2b-256` digest is 32 bytes, and the table is a flat run of them.
const int kNightjarDigestBytes = 32;

/// The largest `count` this wallet will believe, from `asset-metadata-v0.md`
/// section 3.2: the table is capped at 512 KiB, which is 16 384 digests, and
/// that is deliberately the same number as the per-asset total so there is one
/// size to reason about rather than two.
const int kNightjarDigestTableMaxCount = 16384;

/// The largest `bytes` this wallet will accept for an `items_document`, from
/// `asset-metadata-v0.md` section 3.2: 2 MiB.
///
/// The limit is a *ceiling on a declaration*, not a size the wallet computes —
/// section 3.4.1 explains why an `items` array cannot have one — so a document
/// declaring more than this is refused outright rather than fetched and
/// measured.
const int kNightjarItemsDocumentMaxBytes = 2 * 1024 * 1024;

class NightjarCollectionDigestTable {
  const NightjarCollectionDigestTable({
    required this.uri,
    required this.b2,
    required this.count,
  });

  /// Where the table is, under section 2's scheme and origin rules.
  final Uri uri;

  /// `BLAKE2b-256` of the table's bytes, base64url unpadded.
  ///
  /// Not nullable, because section 3.3.1 makes it required and says why: an
  /// unpinned table is a swap vector for every image in the collection at
  /// once. A document whose `digest_table` has no `b2` is not a document with
  /// an unpinned table — it is a document this wallet declines to read a
  /// table from at all.
  final String b2;

  /// How many digests the table holds. The file MUST be exactly `32 * count`
  /// bytes; see [NightjarCollectionMetadata.resolveDigestTable].
  final int count;

  /// The exact byte length the table must have.
  int get expectedBytes => count * kNightjarDigestBytes;
}

/// `items_document` — section 3.4.1's pointer at a collection's per-piece
/// detail.
///
/// Inline `items` costs 190 bytes a member, so a collection carrying one
/// attribute on every piece reaches the 16 KiB limit at 81. Section 3.3.1
/// solved the same problem for digests and left this one standing, which meant
/// a collection of ten thousand could pin every image and describe none of
/// them.
class NightjarCollectionItemsDocument {
  const NightjarCollectionItemsDocument({
    required this.uri,
    required this.b2,
    required this.bytes,
  });

  final Uri uri;

  /// `BLAKE2b-256` of the file's bytes, base64url unpadded. Required: a
  /// substituted `name` or trait is exactly what an unpinned side file is good
  /// for.
  final String b2;

  /// The file's exact byte length, declared by the publisher.
  ///
  /// This is the member that has no counterpart on [NightjarCollectionDigestTable],
  /// and the asymmetry is the point. A digest table is `32 * count`, so a
  /// wallet computes its size from a number it already holds. An `items` array
  /// has no such arithmetic, so without this the only way to learn the cost is
  /// to incur it — and a buffering transport can check a size only after the
  /// fact. Declaring it restores the property the 16 KiB limit exists for: the
  /// wallet decides whether to spend **before** it spends.
  final int bytes;
}

class NightjarCollectionMetadata {
  const NightjarCollectionMetadata({
    required this.item,
    this.revision = 0,
    this.name,
    this.description,
    this.logo,
    this.maxSupply,
    this.digests = const [],
    this.digestTable,
    this.itemsDocument,
    this.website,
    this.links = const [],
    this.items = const [],
    Uint8List? resolvedTable,
  }) : _resolvedTable = resolvedTable;

  /// Section 3.3.1's pointer, or null when the document pins inline.
  ///
  /// Holding the pointer is not holding the digests: until the table has been
  /// fetched and checked, [digestAt] returns null for every index and every
  /// member reads as unpinned. That is the honest state — the wallet genuinely
  /// does not know the digest yet — and it is why [resolveDigestTable] returns
  /// a new document rather than mutating this one.
  final NightjarCollectionDigestTable? digestTable;

  /// The table's verified bytes, once [resolveDigestTable] has accepted them.
  final Uint8List? _resolvedTable;

  /// Whether [digestAt] can answer from a table.
  bool get hasResolvedDigestTable => _resolvedTable != null;

  /// Section 3.4.1's pointer, or null when the document carries `items`
  /// inline (or carries none at all).
  ///
  /// As with [digestTable], holding the pointer is not holding the entries:
  /// until [resolveItemsDocument] has accepted a body, [overrideFor] answers
  /// null for every index and the collection renders from its template alone.
  /// That is a rendering without traits, which section 3.4.1 is explicit is
  /// not a failed collection — traits are decoration.
  final NightjarCollectionItemsDocument? itemsDocument;

  /// `revision` (section 3.1), defaulting to 0. A hint, never a gate —
  /// `asset-metadata-v0.md` section 4.4.
  final int revision;

  /// The collection's human name, truncated to
  /// [kNightjarCollectionMaxNameChars].
  ///
  /// Section 3.1 is explicit that it "is **not** `collection_id` and carries
  /// no authority", and section 5 turns that into a rule the UI obeys: the
  /// `collection_id` is shown wherever this is, and two collections are never
  /// merged because their names match. Open question T2 is the reason — an
  /// issuer may publish a document claiming any name, including one in use.
  final String? name;

  final String? description;

  /// The collection's own picture (section 3.5), or null.
  ///
  /// Typed as the *asset* document's [NightjarAssetLogoRef] on purpose. Section
  /// 3.5 does not define a second picture member — it says its `logo` is
  /// `asset-metadata-v0.md` section 4.2 "applied to a collection instead of to
  /// an asset", and names the rules rather than restating them, "because a
  /// second and subtly different picture member would be a second place to get
  /// the SVG refusal wrong". A second Dart class here would be exactly that
  /// second place, so there is one class, one parser, and one path through
  /// [sniffNightjarImageFormat].
  ///
  /// Null is the ordinary case, not an edge one: nothing obliges a publisher
  /// to have one and every collection published before revision 3 has none.
  /// Section 3.5.1 is what a wallet does about it, and it lives in the UI
  /// layer rather than here — a fallback needs the *acceptance* record, which
  /// a document parser must never see.
  ///
  /// **Not pinned by [digests].** `digests[i]` is the image for member `i`
  /// (section 3.3) and the collection's picture has no index; it is pinned by
  /// its own `b2`, and an absent one means **unpinned, not invalid**.
  final NightjarAssetLogoRef? logo;

  /// How many members the collection may ever have, as the *document* states
  /// it, or null when it declares no cap.
  ///
  /// Section 3.1: "`0` or absent means uncapped", so the two are one state and
  /// both arrive here as null (`_declaredMaxSupply`).
  ///
  /// **Named for the field it mirrors** (section 3.1, revision 5): an asset's
  /// `max_supply` caps the units of one asset, a collection's caps the members
  /// of one collection — the same question one level up. It was called `size`
  /// until there was anything to check it against.
  ///
  /// Still advisory **here**, and section 3.1 still makes the consequence a
  /// MUST: a wallet **MUST NOT** treat a member whose index is ≥ this as
  /// invalid. Nothing in this file reads it, and [memberAt] resolves any index
  /// the caller hands it — a member past this number renders exactly like one
  /// below it.
  ///
  /// What changed is that it is no longer the only place the number exists.
  /// `transition-v0.md` revision 11 binds a collection's cap into
  /// `collection_id` (section 5) and enforces it at section 6 step 6f, so a
  /// wallet **MUST** compare this against the on-chain cap rather than believe
  /// it, and **SHOULD** say so where it shows a count when the two disagree.
  /// That comparison needs a number this document cannot supply, so it lives
  /// where the on-chain one does — `nightjar_collection_data.dart` holds the
  /// chain's cap and `nightjar_collection_mapper.dart` writes the sentence.
  final int? maxSupply;

  /// The template every member is resolved through.
  final NightjarCollectionItemTemplate item;

  /// `digests[i]` is the `BLAKE2b-256` of the image for index `i`, base64url
  /// unpadded (section 3.3).
  ///
  /// A `null` entry is one that was present but unreadable — not 43 base64url
  /// characters, or not a string at all. It is held as a hole rather than
  /// compacted out, because compacting would shift every later digest by one
  /// and pin each piece with its neighbour's hash: every image would then be
  /// discarded under section 3.3's MUST, and the bug would read as a hostile
  /// host rather than as a parser error.
  final List<String?> digests;

  /// `https:` only, exactly as `asset-metadata-v0.md` section 4.1.
  final Uri? website;

  /// Exactly as `asset-metadata-v0.md` section 4.3, including the rule that an
  /// unrecognized `rel` is rendered rather than dropped.
  final List<NightjarAssetLink> links;

  /// Per-piece overrides (section 3.4), in document order.
  final List<NightjarCollectionItemOverride> items;

  /// The links a wallet of this revision draws.
  List<NightjarAssetLink> get renderableLinks => [
    for (final link in links)
      if (link.isRecognized) link,
  ];

  /// How many pieces `digests` pins. Diagnostic: a document whose `digests` is
  /// shorter than its `max_supply` leaves the tail unpinned, which section 3.3
  /// calls out as a state to say out loud rather than an error.
  int get pinnedCount {
    var pinned = 0;
    for (final digest in digests) {
      if (digest != null) pinned++;
    }
    return pinned;
  }

  /// Resolves the member at the **on-chain** [index].
  ///
  /// [index] is the `index` field of the member's issuance, which is hashed
  /// into its `asset_id` through `terms` (section 1). It is the caller's job
  /// to have read it from the chain and this function's job to never accept
  /// one from anywhere else — which is why there is no overload that finds the
  /// index for you.
  ///
  /// A negative index resolves to nothing: `index` is a `u32` on the wire, so
  /// a negative one did not come from a transition.
  NightjarCollectionMember? memberAt(int index) {
    if (index < 0) return null;
    final override = overrideFor(index);

    // Section 3.2: substitute the literal token and nothing else. The name is
    // display text, so a leftover token is left in it and rendered as written;
    // the image is a URI, so a leftover token disqualifies it below.
    final templateName = item.name == null
        ? null
        : nightjarSubstituteIndex(item.name!, index);
    final resolvedName = override?.name ?? templateName;

    final Uri? image;
    final NightjarItemImageRejection? rejection;
    if (override?.image != null) {
      image = override!.image;
      rejection = null;
    } else {
      final result = nightjarResolveItemImage(item.image, index);
      image = result.uri;
      rejection = result.rejection;
    }

    return NightjarCollectionMember(
      index: index,
      name: resolvedName,
      description: override?.description,
      image: image,
      digestB2: override?.digestB2 ?? digestAt(index),
      imageRejection: rejection,
      attributes: override?.attributes ?? const [],
    );
  }

  /// This document with [bytes] accepted as its digest table, or null when
  /// [bytes] are not the table this document points at.
  ///
  /// Section 3.3.1 puts two checks here and makes both MUSTs, and the order
  /// matters: the length is checked first because it is free, and `b2` is
  /// checked **before a single digest is read**. A wallet that indexed first
  /// and verified later would already have pinned an image against attacker
  /// bytes by the time it found out.
  ///
  /// A failure of either is the *whole collection* being unpinned rather than
  /// some members being unpinned — there is no partial credit for a table, and
  /// returning null rather than a half-resolved document is how that is made
  /// unrepresentable.
  NightjarCollectionMetadata? resolveDigestTable(Uint8List bytes) {
    final table = digestTable;
    if (table == null) return null;
    if (bytes.length != table.expectedBytes) return null;
    if (!nightjarB2DigestMatches(table.b2, bytes)) return null;
    return NightjarCollectionMetadata(
      item: item,
      revision: revision,
      name: name,
      description: description,
      logo: logo,
      maxSupply: maxSupply,
      digests: digests,
      digestTable: table,
      // Carried, not dropped. Both side files land on one document and either
      // may resolve first, so each copy has to preserve the other's pointer —
      // a `resolveDigestTable` written before `items_document` existed would
      // silently make the second resolution impossible.
      itemsDocument: itemsDocument,
      website: website,
      links: links,
      items: items,
      resolvedTable: bytes,
    );
  }

  /// This document with [bytes] accepted as its `items` (section 3.4.1), or
  /// null when [bytes] are not the file this document points at.
  ///
  /// Three checks, in the order that makes each one free: the declared length
  /// first, then `b2` **before any entry is read**, then the JSON. A wallet
  /// that parsed first would already have taken a `name` from attacker bytes
  /// by the time it found out.
  ///
  /// A failure of any of them is the collection having no `items` at all,
  /// never some members having them — same rule as the digest table, and for
  /// the same reason: there is no partial credit for a pinned side file.
  NightjarCollectionMetadata? resolveItemsDocument(Uint8List bytes) {
    final pointer = itemsDocument;
    if (pointer == null) return null;
    if (bytes.length != pointer.bytes) return null;
    if (!nightjarB2DigestMatches(pointer.b2, bytes)) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
    if (decoded is! List) return null;

    return NightjarCollectionMetadata(
      item: item,
      revision: revision,
      name: name,
      description: description,
      logo: logo,
      maxSupply: maxSupply,
      digests: digests,
      digestTable: digestTable,
      itemsDocument: pointer,
      website: website,
      links: links,
      items: _items(decoded),
      resolvedTable: _resolvedTable,
    );
  }

  /// The digest for [index], or null when this document does not pin it.
  ///
  /// Two shapes, one answer. Inline (section 3.3) it is `digests[index]`; from
  /// a resolved table (section 3.3.1) it is the 32 bytes at offset `32 *
  /// index`, encoded the way every other digest in this format is written, so
  /// that nothing downstream can tell which shape the document used.
  ///
  /// Section 3.3: "a missing or short `digests` array means those pieces are
  /// **unpinned**, not invalid". So this returns null rather than throwing and
  /// rather than being read as a refusal — and an index past the end of a
  /// table is the same state as an index past the end of an array, for the
  /// same reason.
  String? digestAt(int index) {
    if (index < 0) return null;

    final table = _resolvedTable;
    if (table != null) {
      final start = index * kNightjarDigestBytes;
      // Guard on the resolved bytes rather than on `count`: the two agree
      // (resolveDigestTable refuses a table of any other length), and reading
      // the buffer's own length keeps this total even if that ever stops
      // being true.
      if (start + kNightjarDigestBytes > table.length) return null;
      return base64Url
          .encode(
            Uint8List.sublistView(
              table,
              start,
              start + kNightjarDigestBytes,
            ),
          )
          .replaceAll('=', '');
    }

    if (index >= digests.length) return null;
    return digests[index];
  }

  /// The `items` entry for [index], or null.
  ///
  /// Section 3.4: a wallet **MUST** ignore an entry whose index it does not
  /// hold — which falls out of only ever asking for the index in hand. The
  /// first entry wins when a document repeats an index; last-wins would be
  /// just as arbitrary, and first-wins matches how `asset_summaries` resolves
  /// a repeated issuance one layer down.
  NightjarCollectionItemOverride? overrideFor(int index) {
    for (final entry in items) {
      if (entry.index == index) return entry;
    }
    return null;
  }

  /// Parses the document's exact bytes.
  ///
  /// A BOM is refused rather than skipped, for the reason
  /// [NightjarAssetMetadata.parseBytes] gives: the `#b2=` pin of
  /// `asset-metadata-v0.md` section 2.1 is over the exact bytes, so "the same
  /// document with a BOM" is a different document.
  factory NightjarCollectionMetadata.parseBytes(List<int> bytes) =>
      NightjarCollectionMetadata.fromJson(nightjarDecodeDocument(bytes));

  factory NightjarCollectionMetadata.fromJson(Map<String, Object?> json) {
    final major = nightjarSchemaMajor(
      json['schema'],
      kNightjarCollectionSchemaFamily,
    );
    if (major != kNightjarCollectionSchemaMajor) {
      // `asset-metadata-v0.md` section 4.4: a major we do not implement means
      // an existing member now means something else, so reading the parts we
      // recognize would be reading them wrongly. A malformed `schema` lands
      // here too, as an unrecognized major rather than as a parse failure.
      throw NightjarMetadataFormatException(
        'unknown collection schema "${json['schema']}"',
      );
    }

    final item = _item(json['item']);
    if (item == null) {
      // Section 3.1 makes `item` required, and unlike `name` its absence is
      // not cosmetic: without a template there is no artwork for any member
      // and nothing for the rest of this file to resolve.
      throw const NightjarMetadataFormatException('item is missing');
    }

    return NightjarCollectionMetadata(
      revision: _nonNegativeInt(json['revision']) ?? 0,
      // Section 3.1 marks `name` required. It is not enforced as a rejection:
      // a document that forgot its display name is wrong about decoration,
      // and discarding it would cost a hundred pieces their artwork over a
      // string that decides nothing (`asset-metadata-v0.md` section 1). This
      // is a choice the spec leaves to the reader and it is recorded here so
      // that a later revision can make it a MUST on purpose rather than by
      // drift.
      name: _text(json['name'], kNightjarCollectionMaxNameChars),
      description: _text(
        json['description'],
        kNightjarCollectionMaxDescriptionChars,
      ),
      // Section 3.5, through the section 4.2 parser rather than beside it.
      // A member this revision did not define — `mime`, `width`, `height` —
      // is dropped there for the reasons `NightjarAssetLogoRef` records, and
      // an unknown one is ignored, per `asset-metadata-v0.md` section 4.4.
      logo: nightjarAssetLogoRef(json['logo']),
      maxSupply: _declaredMaxSupply(json['max_supply']),
      item: item,
      // Section 3.3.1 makes the two mutually exclusive, and the tie-break is
      // normative rather than a preference: a wallet that finds both MUST use
      // the table and ignore the inline array, so that two sources can never
      // disagree about one index. `_digests` is still parsed, so a document
      // shipping both is diagnosable rather than silently half-read.
      digests: _digests(json['digests']),
      digestTable: _digestTable(json['digest_table']),
      // Section 3.4.1, mutually exclusive with `items` on the same terms as
      // the table is with `digests`: a wallet finding both uses the external
      // one, so two sources can never disagree about one index.
      itemsDocument: _itemsDocument(json['items_document']),
      website: nightjarHttpsUri(json['website']),
      links: nightjarMetadataLinks(json['links']),
      items: _items(json['items']),
    );
  }

  /// Section 3.3.1. Every member is required, so a pointer missing any one of
  /// them is no pointer at all rather than a partial one — in particular a
  /// `digest_table` with no `b2` is dropped, because an unpinned table is the
  /// one thing that member exists to prevent.
  static NightjarCollectionDigestTable? _digestTable(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final uri = nightjarHttpsUri(value['uri']);
    if (uri == null) return null;
    final b2 = value['b2'];
    if (b2 is! String || !_looksLikeB2(b2)) return null;
    final count = _nonNegativeInt(value['count']);
    if (count == null || count == 0) return null;
    // A `count` past the section 3.2 ceiling is refused here rather than at
    // fetch time. The limits table caps the table at 32 x 16384 = 512 KiB, and
    // a document is free to claim more; believing it would mean sizing a read
    // from a number the format itself calls advisory everywhere else.
    if (count > kNightjarDigestTableMaxCount) return null;
    return NightjarCollectionDigestTable(uri: uri, b2: b2, count: count);
  }

  /// Section 3.4.1. Every member is required. `bytes` in particular: without
  /// it the pointer is one a wallet cannot decide about before fetching, which
  /// is the whole reason the member exists.
  static NightjarCollectionItemsDocument? _itemsDocument(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final uri = nightjarHttpsUri(value['uri']);
    if (uri == null) return null;
    final b2 = value['b2'];
    if (b2 is! String || !_looksLikeB2(b2)) return null;
    final bytes = _nonNegativeInt(value['bytes']);
    if (bytes == null || bytes == 0) return null;
    if (bytes > kNightjarItemsDocumentMaxBytes) return null;
    return NightjarCollectionItemsDocument(uri: uri, b2: b2, bytes: bytes);
  }

  /// 43 base64url characters, the shape every digest in this format is written
  /// in. Checked before the pointer is accepted so that a malformed `b2`
  /// reads as "no table" rather than as a table that will fail verification
  /// later for a reason the user cannot act on.
  static bool _looksLikeB2(String value) {
    if (value.length != 43) return false;
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      final ok =
          (c >= 0x41 && c <= 0x5A) ||
          (c >= 0x61 && c <= 0x7A) ||
          (c >= 0x30 && c <= 0x39) ||
          c == 0x2D ||
          c == 0x5F;
      if (!ok) return false;
    }
    return true;
  }

  static NightjarCollectionItemTemplate? _item(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final name = value['name'];
    final image = value['image'];
    return NightjarCollectionItemTemplate(
      name: name is String && name.trim().isNotEmpty
          ? sanitizeNightjarMetadataText(name)
          : null,
      // Not sanitized and not trimmed of anything but surrounding whitespace:
      // it is a URI template, and the substituted result is validated as a
      // URI rather than cleaned up into one.
      image: image is String && image.trim().isNotEmpty ? image.trim() : null,
    );
  }

  static List<String?> _digests(Object? value) {
    if (value is! List) return const [];
    return List.unmodifiable([
      for (final entry in value)
        if (entry is String && isNightjarB2Digest(entry)) entry else null,
    ]);
  }

  static List<NightjarCollectionItemOverride> _items(Object? value) {
    if (value is! List) return const [];
    final items = <NightjarCollectionItemOverride>[];
    for (final entry in value) {
      if (entry is! Map<String, Object?>) continue;
      final index = _nonNegativeInt(entry['index']);
      if (index == null) continue;
      final digest = entry['b2'];
      items.add(
        NightjarCollectionItemOverride(
          index: index,
          name: _text(entry['name'], kNightjarCollectionMaxNameChars),
          description: _text(
            entry['description'],
            kNightjarCollectionMaxDescriptionChars,
          ),
          image: nightjarHttpsUri(entry['image']),
          digestB2: digest is String && isNightjarB2Digest(digest)
              ? digest
              : null,
          attributes: _attributes(entry['attributes']),
        ),
      );
    }
    return List.unmodifiable(items);
  }

  static List<NightjarItemAttribute> _attributes(Object? value) {
    if (value is! List) return const [];
    final attributes = <NightjarItemAttribute>[];
    for (final entry in value) {
      if (attributes.length >= kNightjarItemMaxAttributes) break;
      if (entry is! Map<String, Object?>) continue;
      final trait = _text(entry['trait'], kNightjarItemAttributeMaxChars);
      final attributeValue = _text(
        entry['value'],
        kNightjarItemAttributeMaxChars,
      );
      if (trait == null || attributeValue == null) continue;
      attributes.add(
        NightjarItemAttribute(trait: trait, value: attributeValue),
      );
    }
    return List.unmodifiable(attributes);
  }

  /// Plain text, stripped of the invisible direction-override characters that
  /// let one string render as another, then truncated to [maxChars] runes.
  static String? _text(Object? value, int maxChars) {
    if (value is! String) return null;
    final cleaned = sanitizeNightjarMetadataText(value);
    if (cleaned.isEmpty) return null;
    final runes = cleaned.runes.toList();
    if (runes.length <= maxChars) return cleaned;
    return String.fromCharCodes(runes.take(maxChars));
  }

  /// Section 3.1's `max_supply`, with `0` folded into absent.
  ///
  /// "`0` or absent means uncapped", so the two are one state and this model
  /// gives it one representation. Keeping `0` as a number would leave every
  /// consumer to remember that a cap of zero is not a cap of zero — the same
  /// mistake as rendering an undisclosed supply as `0`, which the asset side
  /// already refuses to make.
  static int? _declaredMaxSupply(Object? value) {
    final declared = _nonNegativeInt(value);
    return declared == null || declared == 0 ? null : declared;
  }

  /// A JSON number that is a non-negative integer, or null.
  ///
  /// `is int` alone would let `1e3` through as a double and `3.5` through as
  /// nothing; this accepts a whole double so that a publisher whose encoder
  /// emits `100.0` is not punished for it, and refuses a fractional one.
  static int? _nonNegativeInt(Object? value) {
    if (value is int) return value < 0 ? null : value;
    if (value is double) {
      if (value.isNaN || value.isInfinite || value < 0) return null;
      if (value != value.roundToDouble()) return null;
      return value.toInt();
    }
    return null;
  }
}

/// The outcome of resolving `item.image` for one index.
class NightjarItemImageResult {
  const NightjarItemImageResult.resolved(Uri this.uri) : rejection = null;

  const NightjarItemImageResult.rejected(
    NightjarItemImageRejection this.rejection,
  ) : uri = null;

  final Uri? uri;
  final NightjarItemImageRejection? rejection;
}

/// Substitutes the on-chain [index] into an `item.image` template and checks
/// that what comes out is a URI this wallet will request.
///
/// Section 3.2, in order:
///
/// * every occurrence of the literal `{index}` becomes the index "rendered as
///   decimal with no padding" — `7`, never `007` and never `0x7`;
/// * nothing else is substituted, so any other `{…}` the document invented
///   survives verbatim and disqualifies the result;
/// * the result **MUST** resolve to `https:`, and everything in
///   `asset-metadata-v0.md` section 2 applies to it;
/// * a result that is not a valid absolute URI is *the piece* having no
///   artwork, never the collection being invalid.
NightjarItemImageResult nightjarResolveItemImage(String? template, int index) {
  if (template == null || template.isEmpty) {
    return const NightjarItemImageResult.rejected(
      NightjarItemImageRejection.absent,
    );
  }
  final substituted = nightjarSubstituteIndex(template, index);
  if (substituted.contains('{') || substituted.contains('}')) {
    return const NightjarItemImageResult.rejected(
      NightjarItemImageRejection.unresolvedToken,
    );
  }
  final uri = nightjarHttpsUri(substituted);
  if (uri == null) {
    return const NightjarItemImageResult.rejected(
      NightjarItemImageRejection.notHttps,
    );
  }
  return NightjarItemImageResult.resolved(uri);
}

/// Replaces every literal `{index}` in [template] with [index] as decimal.
///
/// The one substitution section 3.2 defines. It is a plain string replace and
/// not a format-string engine on purpose: a document does not get to name the
/// substitutions, so there is nothing here to parse and nothing to escape.
String nightjarSubstituteIndex(String template, int index) =>
    template.replaceAll(kNightjarIndexToken, '$index');
