/// Plain view models for the Nightjar asset surfaces, plus the explicit
/// display formatters they are rendered through.
///
/// Nothing here imports Flutter widgets, Riverpod, or the generated Rust
/// bindings: the screens take these records and the provider (or a test)
/// produces them. Three protocol facts are encoded directly in the shape of
/// these classes because the UI is not allowed to paper over them:
///
/// * **Balances are private.** A Nightjar note is only visible to the wallet
///   that can decrypt it, so there is no holder list and no circulating
///   supply. [NightjarAssetDetailData] therefore carries an *issued* supply
///   for public assets and nothing at all for private ones.
/// * **An asset may have no name.** An asset id is a hash; it only gains a
///   name when its issuer publishes an `ASSET` message. [NightjarAssetRowData
///   .name] being null is the normal case, not an error.
/// * **A received asset is invisible until it is [NightjarViewData
///   .finalityDepth] blocks deep.** The replay closes the view below that
///   depth, so every note it reports is already final and there is no such
///   thing as a pending note here. What the wallet *can* say is how many
///   messages the channel is carrying above the cut —
///   [NightjarViewData.pendingMessageCount] — which is a fact about the
///   channel, not a claim about this wallet's incoming notes.
///
/// Amounts are always a [BigInt] of base units plus an `int decimals`, and are
/// turned into text by [formatNightjarAmount]. There is no floating point
/// anywhere in this feature.
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart' show VoidCallback;

/// How much of the Nightjar view the wallet was actually able to build.
enum NightjarViewStatus {
  /// No Nightjar indexer / channel is configured, so nothing has been read.
  notConfigured,

  /// The configured indexer could not be reached at all.
  unreachable,

  /// The indexer answered, but the wallet cannot believe what it said: a
  /// different channel, a verifying key that does not match its own hash, a
  /// replay that would not run, or a channel where nothing verified. None of
  /// these are network faults and none of them are fixed by retrying.
  unverified,

  /// The indexer answered but is behind the chain, so what follows may be
  /// missing recent messages.
  stale,

  /// The channel was replayed and every proof verified locally.
  ready,
}

/// The wallet's own Nightjar identity — derived from the seed it already
/// holds, so it needs no separate backup.
class NightjarIdentityData {
  const NightjarIdentityData({
    required this.address,
    required this.networkLabel,
  });

  /// bech32m Nightjar address (`njreg…` / `njtest…` / `nj…`).
  final String address;

  /// Human label for the network the address belongs to, e.g. `Regtest`.
  final String networkLabel;
}

/// One row of the Nightjar assets list: what this wallet holds of one asset.
class NightjarAssetRowData {
  const NightjarAssetRowData({
    required this.assetId,
    required this.balance,
    required this.decimals,
    required this.noteCount,
    this.name,
    this.symbol,
    this.isPublic = false,
    this.isUniqueItem = false,
    this.collectionId,
    this.index,
    this.logoBytes,
    this.onTap,
  });

  /// Hex asset id. Always present — it is the asset's only true identifier.
  final String assetId;

  /// Name declared by the issuer's `ASSET` message, or null when the issuer
  /// never published one. Unnamed is normal.
  final String? name;

  /// Symbol declared by the issuer's `ASSET` message, or null.
  final String? symbol;

  /// This wallet's own balance, in base units. Nobody else can see it.
  final BigInt balance;

  /// Base-unit exponent for [balance].
  final int decimals;

  /// Notes of this asset the wallet holds. Every one of them is final: the
  /// replay closes the view [NightjarViewData.finalityDepth] blocks below the
  /// tip, so a note that is not deep enough yet is not in the view at all.
  final int noteCount;

  /// Whether the asset's issued supply is public. Balances are private
  /// either way.
  final bool isPublic;

  /// True when this asset's identity says only one of it can ever exist:
  /// `max_supply == 1` at `decimals == 0`.
  ///
  /// Both halves of that are hashed into `asset_id`, so it is a fact every
  /// verifier on the channel recomputes rather than a claim in a document.
  /// It is the reason this row must not render a quantity — see
  /// [nightjarAssetRowBalanceText].
  final bool isUniqueItem;

  /// The collection this asset was issued into, or null when the issuance
  /// disclosed none. Hex, as the replay reports it.
  final String? collectionId;

  /// The issuer-declared position of this asset inside [collectionId], or
  /// null when the wallet has not read one.
  ///
  /// Null exactly when [collectionId] is null: both come out of the same
  /// applied *public* issuance, so "in a collection, index unknown" is not a
  /// state the replay can report. See [NightjarAssetDetailData.index] for why
  /// the value has to come from the chain.
  final int? index;

  /// Verified logo bytes for an asset the user has **explicitly accepted**,
  /// or null.
  ///
  /// Null is the normal state and the only state an unaccepted asset can be
  /// in: `spec/asset-metadata-v0.md` section 5 makes displaying a logo the
  /// user never asked for the impersonation of section 1.1 delivered at no
  /// cost to the attacker. Whoever fills this in has already checked
  /// acceptance; the row cannot.
  final Uint8List? logoBytes;

  final VoidCallback? onTap;

  /// True when the issuer published an `ASSET` message naming this asset.
  bool get hasName => (name ?? '').trim().isNotEmpty;

  bool get hasLogo => logoBytes != null;
}

/// One note of one asset that this wallet holds **or has held**, with the
/// provenance the activity feed reconstructs a payment from.
///
/// The provenance fields are optional and default to "nothing is known", which
/// is what a fixture or an older caller that does not set them says. A note
/// with an empty [createdBy] is not grouped with anything: the feed treats it
/// as a note that exists and claims nothing about how it got here.
class NightjarNoteRowData {
  const NightjarNoteRowData({
    required this.position,
    required this.amount,
    required this.decimals,
    required this.createdHeight,
    this.policyText,
    this.spent = false,
    this.createdBy = '',
    this.createdInputs = 0,
    this.createdOutputs = 0,
    this.spentBy,
    this.spentHeight,
    this.spentInputs,
    this.spentOutputs,
  });

  /// Commitment-tree position of the note.
  final BigInt position;

  /// Note value in base units.
  final BigInt amount;

  /// Base-unit exponent for [amount].
  final int decimals;

  /// Block height the note was created at.
  final BigInt createdHeight;

  /// Rendered policy attached to the note, when it carries one.
  final String? policyText;

  /// True once the channel holds this note's nullifier. A spent note is still
  /// listed — a payment leaves only its change behind, and change with no
  /// input beside it reads as money arriving.
  final bool spent;

  /// `msg_id` of the transition that appended this note, or empty when the
  /// producer did not say. Notes sharing it were created by one message.
  final String createdBy;

  /// How many notes [createdBy] consumed and appended in total — this
  /// wallet's and other people's alike. Zero inputs is an issuance.
  ///
  /// An output this wallet does not hold is not a zero; it is an amount
  /// nobody on this side can name. These counts are what say whether the
  /// notes in hand are the whole message, and never what is in the ones that
  /// are not.
  final int createdInputs;
  final int createdOutputs;

  /// `msg_id` of the message that nullified this note, null while unspent.
  final String? spentBy;

  /// The height that message completed at — when the money left.
  final BigInt? spentHeight;

  /// The same two counts for [spentBy]. [spentInputs] is the one an authorship
  /// test needs: this wallet signed the message only if it owned *every* input.
  final int? spentInputs;
  final int? spentOutputs;
}

/// One `label: value` fact rendered as a list row on the detail screen.
class NightjarAssetFactData {
  const NightjarAssetFactData({
    required this.label,
    required this.value,
    this.copyText,
  });

  final String label;
  final String value;

  /// When set, the row offers to copy this instead of [value] (e.g. the full
  /// asset id behind a truncated display value).
  final String? copyText;
}

/// Everything the detail screen shows for one asset.
class NightjarAssetDetailData {
  const NightjarAssetDetailData({
    required this.assetId,
    required this.balance,
    required this.decimals,
    this.name,
    this.symbol,
    this.collection,
    this.index,
    this.collectionMaxSupply,
    this.isPublic = false,
    this.issuedSupply,
    this.maxSupply,
    this.metadataUri,
    this.declaredMetadata = const [],
    this.notes = const [],
  });

  final String assetId;
  final String? name;
  final String? symbol;

  /// Collection this asset belongs to, when it belongs to one.
  ///
  /// The hex `collection_id` the issuing transition named. It is derived from
  /// the issuer's key and a label, so every asset sharing one was issued under
  /// one key — that is the whole of what it says, and it is why accepting a
  /// collection is a decision about an issuer rather than about a picture.
  final String? collection;

  /// The issuer-declared position of this asset inside [collection], or null
  /// when the wallet has not read one.
  ///
  /// Null when no applied *public* issuance disclosed one — a privately issued
  /// asset has no index anyone can read, and a private asset in a collection is
  /// the case `spec/asset-collection-v0.md` X11 records as unreachable.
  ///
  /// It is *verified*, not merely asserted: the circuit rebuilds
  /// `terms = Fq(1 + 2·max_supply + 2^65·index)` and `terms` is hashed into
  /// `asset_id`, so a wrong index is a wrong asset. That is what makes it safe
  /// to substitute into a collection document's `item.image` template
  /// (`asset-collection-v0.md` section 3.2) — the document cannot lie about
  /// which piece is which, because changing the index changes the id.
  ///
  /// Nothing ever invents one. A position in a list sorted by `asset_id` is a
  /// hash order, and printing it as "#3" would be a number the channel never
  /// said — the same mistake as rendering an undisclosed supply as zero.
  final int? index;

  /// The cap bound into [collection], or null when the collection is uncapped
  /// or the wallet has not read one.
  ///
  /// `transition-v0.md` revision 11 makes this a fact a verifier enforces
  /// rather than a number a publisher writes down: it is hashed into
  /// `collection_id` (section 5), and section 6 step 6f ignores a public
  /// issuance whose `index` is not strictly below it. So every member of one
  /// collection agrees on it by construction — a member declaring a different
  /// cap is a member of a *different* collection, and the disagreement cannot
  /// be expressed.
  ///
  /// It is the number a collection document's own `max_supply`
  /// (`asset-collection-v0.md` section 3.1) is checked against, and the reason
  /// that member is a mirror rather than the only copy.
  ///
  /// **Always null today.** The Rust replay does not yet put
  /// `collection_max_supply` on `NjAsset`, so nothing sets it and every
  /// collection reads as uncapped — which is the safe direction: section 6
  /// step 6f says a wallet **MAY** present a capped collection's count as
  /// verified and **MUST NOT** present an uncapped one's that way, so an
  /// unread cap costs a true sentence and never buys a false one.
  final int? collectionMaxSupply;

  /// Whether the asset's issued supply is public.
  final bool isPublic;

  /// This wallet's own balance in base units — private, always.
  final BigInt balance;
  final int decimals;

  /// Issued supply in base units. Only knowable for a public asset; null for
  /// a private one and for a public one whose issuance has not been read.
  final BigInt? issuedSupply;

  /// Maximum supply declared by the issuer, when one was declared.
  final BigInt? maxSupply;

  /// The `uri` the issuer's `ASSET` message carried, verbatim, or null when
  /// it carried none.
  ///
  /// Signed and on-chain, and a **pointer only**: whatever is at the end of it
  /// is chosen by whoever controls that host now, which is the issuer at
  /// signing time and its next owner thereafter. Nothing fetches it because
  /// this field is set — `spec/asset-metadata-v0.md` section 3.1 forbids
  /// exactly that — and it is carried here so the acceptance surface can show
  /// the user which host they would be talking to.
  final String? metadataUri;

  /// Extra fields the issuer's `ASSET` message declared, already flattened
  /// into label/value pairs by whoever produced this record.
  final List<NightjarAssetFactData> declaredMetadata;

  /// The wallet's own notes of this asset. All of them are final; see
  /// [NightjarAssetRowData.noteCount].
  final List<NightjarNoteRowData> notes;

  bool get hasName => (name ?? '').trim().isNotEmpty;

  /// True when this asset's identity says exactly one of it can exist.
  ///
  /// There is no separate NFT type in Nightjar. A unique item is an ordinary
  /// public asset issued with `max_supply = 1` at `decimals = 0`, and the cap
  /// is part of the asset's identity: it is hashed into `asset_id`, so "there
  /// is only one of these" is a fact every verifier recomputes rather than a
  /// line in a metadata document the issuer can rewrite.
  ///
  /// `decimals == 0` is required as well as the cap, and not as decoration. A
  /// cap of one unit at eight decimals is a cap of 0.00000001 of something
  /// divisible — a dust-sized fungible asset, not a thing. Only the pair means
  /// "one indivisible item".
  ///
  /// [maxSupply] is already null for a private asset and for the uncapped
  /// `Some(0)` case (`nightjar_view_loader.dart`), so this is never true of an
  /// asset whose cap the channel has not disclosed.
  bool get isUniqueItem => maxSupply == BigInt.one && decimals == 0;

  /// Whether the wallet holds this unique item right now. Meaningless unless
  /// [isUniqueItem]; a fungible balance is a quantity, not a yes or no.
  bool get ownsUniqueItem => isUniqueItem && balance > BigInt.zero;

  /// The list row this asset contributes to the assets screen.
  ///
  /// [logoBytes] is passed in rather than read from anything on this object:
  /// a logo belongs to an asset the user accepted, and acceptance lives in the
  /// wallet, not in the channel.
  NightjarAssetRowData toRowData({VoidCallback? onTap, Uint8List? logoBytes}) {
    return NightjarAssetRowData(
      assetId: assetId,
      name: name,
      symbol: symbol,
      balance: balance,
      decimals: decimals,
      noteCount: notes.length,
      isPublic: isPublic,
      isUniqueItem: isUniqueItem,
      collectionId: collection,
      index: index,
      logoBytes: logoBytes,
      onTap: onTap,
    );
  }
}

/// Where the chain tip the view was closed against came from.
///
/// The tip decides which blocks are final, so whoever supplies it decides
/// what the wallet is willing to count. The wallet's own synced tip is the
/// answer; the indexer's is a fallback the UI has to disclose, because an
/// indexer that both serves the messages and picks the cut-off can hide a
/// block by simply not admitting it exists.
enum NightjarChainTipSource {
  /// This wallet's own lightwalletd sync reported it.
  wallet,

  /// Borrowed from the indexer because the wallet had no tip of its own yet.
  indexer,
}

/// The whole Nightjar view for the active wallet: its identity, every asset
/// it holds, and how much of the channel the wallet actually managed to read.
class NightjarViewData {
  const NightjarViewData({
    required this.status,
    this.identity,
    this.assets = const [],
    this.finalityDepth = kNightjarDefaultFinalityDepth,
    this.pendingMessageCount = 0,
    this.appliedMessageCount = 0,
    this.ignoredMessageCount = 0,
    this.viewHeight,
    this.indexerHeight,
    this.chainTipHeight,
    this.chainTipSource = NightjarChainTipSource.wallet,
    this.vkHash,
    this.statusMessage,
    this.statusDetail,
  });

  /// The state the UI shows before anything is configured. This is the
  /// default the provider ships; it is deliberately not fake data.
  const NightjarViewData.notConfigured()
    : status = NightjarViewStatus.notConfigured,
      identity = null,
      assets = const [],
      finalityDepth = kNightjarDefaultFinalityDepth,
      pendingMessageCount = 0,
      appliedMessageCount = 0,
      ignoredMessageCount = 0,
      viewHeight = null,
      indexerHeight = null,
      chainTipHeight = null,
      chainTipSource = NightjarChainTipSource.wallet,
      vkHash = null,
      statusMessage = null,
      statusDetail = null;

  final NightjarViewStatus status;

  /// Null until the wallet has derived its Nightjar account.
  final NightjarIdentityData? identity;

  final List<NightjarAssetDetailData> assets;

  /// Blocks a message must be buried under before the replay applies it.
  final int finalityDepth;

  /// Messages the channel carries above the finality cut-off, so the replay
  /// has not applied them yet.
  ///
  /// A fact about the *channel*, not about this wallet: anyone may write to a
  /// public channel, so most of these are usually somebody else's, and the
  /// wallet cannot tell which — deciding that would mean decrypting messages
  /// it has deliberately not applied. The copy this feeds says so.
  final int pendingMessageCount;

  /// Messages the state machine accepted during the replay.
  final int appliedMessageCount;

  /// Messages the state machine refused. Non-zero is normal on a public
  /// channel; [appliedMessageCount] of zero beside a non-zero count here is
  /// not, and is what tells a wrong verifying key apart from an empty channel.
  final int ignoredMessageCount;

  /// The canonical height the replay closed the view at — the chain tip less
  /// [finalityDepth]. Every figure above is only meaningful here.
  final BigInt? viewHeight;

  /// Height the indexer says it has read the channel up to, when it reported
  /// one. Below [viewHeight] means it has not served everything the view
  /// needed.
  final BigInt? indexerHeight;

  /// The chain tip the view was closed against.
  final BigInt? chainTipHeight;

  /// Who supplied [chainTipHeight].
  final NightjarChainTipSource chainTipSource;

  /// `BLAKE2b-256` of the verifying key the replay actually checked every
  /// proof against, lowercase hex — or null when no replay happened.
  ///
  /// The send path is what needs it: a proving-key folder from another
  /// ceremony shares the same circuit fingerprint and produces proofs every
  /// verifier on this channel rejects, and the only value that tells the two
  /// apart is this one. Comparing the folder's `vk_hash` with it is how the
  /// settings screen refuses that key before a user pays a Zcash fee to carry
  /// a proof nobody will accept.
  final String? vkHash;

  /// Sentence-case copy for a non-ready [status], when the loader knows
  /// something more specific than the canned text for that status. Rendered.
  final String? statusMessage;

  /// Extra machine detail for a non-ready [status]; never shown raw to the
  /// user, useful in logs and tests.
  final String? statusDetail;

  bool get isReady => status == NightjarViewStatus.ready;

  bool get isConfigured => status != NightjarViewStatus.notConfigured;

  /// True when the indexer answered but the wallet could not verify what it
  /// said. Retrying does not help; the fix is in settings.
  bool get isUnverified => status == NightjarViewStatus.unverified;

  /// True when the view was closed against a tip the indexer supplied.
  bool get borrowedChainTip => chainTipSource == NightjarChainTipSource.indexer;

  /// The asset with this id, or null when the view does not hold it.
  NightjarAssetDetailData? assetById(String assetId) {
    for (final asset in assets) {
      if (asset.assetId == assetId) return asset;
    }
    return null;
  }
}

/// Nightjar's finality depth on the devnet this proof of concept targets: a
/// received asset is invisible until it is this many blocks deep.
const int kNightjarDefaultFinalityDepth = 10;

/// Characters of an asset id kept at each end when it is truncated.
const int kNightjarAssetIdAffixLength = 6;

/// Renders a base-unit [amount] at [decimals] as text, integer-only.
///
/// The integer part is comma-grouped; trailing zeros in the fraction are
/// dropped so `1000000` at 6 decimals reads `1`, not `1.000000`.
String formatNightjarAmount(BigInt amount, int decimals) {
  final negative = amount.isNegative;
  final magnitude = amount.abs();
  final sign = negative ? '-' : '';
  if (decimals <= 0) {
    return '$sign${_groupDigits(magnitude.toString())}';
  }
  final unit = BigInt.from(10).pow(decimals);
  final whole = _groupDigits((magnitude ~/ unit).toString());
  final fraction = (magnitude % unit)
      .toString()
      .padLeft(decimals, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  if (fraction.isEmpty) return '$sign$whole';
  return '$sign$whole.$fraction';
}

/// Parses typed [text] into base units at [decimals], or null when it is not
/// an amount.
///
/// Integer-only and string-based on purpose: `double.parse('0.1')` at 8
/// decimals is 10000000.000000001, and a send screen that rounds that back is
/// a send screen that occasionally moves a different number than the one on
/// screen. Grouping commas are accepted because the field echoes them back
/// from [formatNightjarAmount]; anything else — a sign, an exponent, a second
/// separator, more fraction digits than the asset has — is rejected rather
/// than repaired.
BigInt? parseNightjarAmount(String text, int decimals) {
  final raw = text.trim().replaceAll(',', '');
  if (raw.isEmpty || raw == '.') return null;
  final parts = raw.split('.');
  if (parts.length > 2) return null;
  final whole = parts.first;
  final fraction = parts.length == 2 ? parts[1] : '';
  if (whole.isNotEmpty && !_isDigits(whole)) return null;
  if (fraction.isNotEmpty && !_isDigits(fraction)) return null;
  final places = decimals < 0 ? 0 : decimals;
  if (fraction.length > places) return null;
  final digits =
      '${whole.isEmpty ? '0' : whole}${fraction.padRight(places, '0')}';
  return BigInt.tryParse(digits);
}

/// Whether [text] has more fraction digits than [decimals] allows — the one
/// rejection worth naming, because it is the only one a user can fix by
/// typing less rather than typing something else.
bool nightjarAmountHasTooManyDecimals(String text, int decimals) {
  final raw = text.trim().replaceAll(',', '');
  final separator = raw.indexOf('.');
  if (separator < 0) return false;
  final fraction = raw.substring(separator + 1);
  if (!_isDigits(fraction) && fraction.isNotEmpty) return false;
  return fraction.length > (decimals < 0 ? 0 : decimals);
}

bool _isDigits(String text) {
  if (text.isEmpty) return false;
  for (final unit in text.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return true;
}

/// `abcdef…123456` — an asset id short enough for a list row, with both ends
/// preserved so two ids cannot collide visually.
String truncateNightjarAssetId(
  String assetId, {
  int affixLength = kNightjarAssetIdAffixLength,
}) {
  if (assetId.length <= affixLength * 2 + 1) return assetId;
  final head = assetId.substring(0, affixLength);
  final tail = assetId.substring(assetId.length - affixLength);
  return '$head…$tail';
}

String _groupDigits(String digits) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final remaining = digits.length - i;
    buffer.write(digits[i]);
    if (remaining > 1 && remaining % 3 == 1) buffer.write(',');
  }
  return buffer.toString();
}
