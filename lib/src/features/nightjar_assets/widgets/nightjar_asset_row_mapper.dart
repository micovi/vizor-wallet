/// Pure mapping from a [NightjarViewData] to what the Nightjar widgets
/// render, plus the canonical copy for every Nightjar state.
///
/// Nothing here touches a `BuildContext`, a provider, or the clock, so both
/// form factors and the Widgetbook use cases go through exactly the same
/// text. Mirrors `activity_row_mapper.dart` / `activity_feed_sections.dart`.
library;

import 'dart:typed_data';

import '../../../core/formatting/number_format.dart';
import 'nightjar_asset_row_data.dart';
import 'nightjar_assets_feed.dart';

/// Shown when Nightjar is configured, the channel replayed, and this wallet
/// simply holds none of its assets.
const String kNightjarEmptyText =
    'No Nightjar assets yet. Assets paid to your Nightjar address show up '
    'here once they are confirmed.';

/// Shown before any Nightjar indexer is configured. Not an error — the
/// feature just has nothing to read yet.
const String kNightjarNotConfiguredText =
    'Nightjar is not set up yet. Point the wallet at a Nightjar indexer to '
    'read the channel and see what it holds.';

/// Shown when the configured indexer cannot be reached. The wallet verifies
/// every proof itself, so an unreachable indexer costs visibility, not
/// custody.
const String kNightjarUnreachableText =
    "Can't reach the Nightjar indexer. Nothing is lost — the wallet just "
    "can't read the channel right now.";

/// Shown when the indexer answered but nothing it said could be verified and
/// the loader had nothing more specific to say. Deliberately not the
/// unreachable copy: no amount of network will fix it.
const String kNightjarUnverifiedText =
    'The wallet could not verify this Nightjar channel, so it is not showing '
    'a balance for it. Check the indexer and channel in Nightjar settings.';

/// The indexer is serving a channel other than the configured one. Retrying
/// reaches the same wrong channel, so this points at settings instead.
const String kNightjarChannelMismatchText =
    'This indexer serves a different Nightjar channel than the one this '
    'wallet is set up for. Check the indexer and channel in Nightjar '
    'settings.';

/// `/api/vk` and `/api/status` disagree about the verifying key's hash, so
/// no proof checked against that key means anything.
const String kNightjarVerifyingKeyMismatchText =
    'The verifying key this indexer served does not match the hash it '
    'publishes for it, so no proof on this channel can be trusted.';

/// Every message the channel carries was refused by the state machine. The
/// honest reading is "one of two things", and the copy says both.
const String kNightjarNothingVerifiedText =
    'Nothing on this Nightjar channel passed verification. Either the channel '
    'carries no valid messages or this wallet is checking them against the '
    'wrong verifying key.';

/// The wallet computed a different state root than the indexer publishes for
/// the same height — the one symptom a withheld message leaves behind.
const String kNightjarStateRootMismatchText =
    'This indexer publishes a different channel state than the wallet '
    'computed from the messages it served, so it is not showing the whole '
    'channel.';

/// The indexer has not read the channel as far as the wallet's own view
/// reaches, so the replay ran on an incomplete set of messages.
const String kNightjarIndexerBehindText =
    'The Nightjar indexer has not read the channel as far as this wallet has '
    'synced, so recent assets and notes may be missing until it catches up.';

/// Shown while the view was closed against a tip the indexer supplied rather
/// than one this wallet synced for itself.
const String kNightjarBorrowedChainTipText =
    'This wallet has not synced a chain tip of its own yet, so the indexer is '
    'deciding which blocks count as final here.';

/// Shown when the indexer answered but has not replayed up to the chain tip.
const String kNightjarStaleText =
    'The Nightjar indexer is behind the chain. Recent assets and notes may '
    'be missing until it catches up.';

/// The one line the detail screen owes the user about what is public on an
/// asset whose issued supply is public.
const String kNightjarSupplyPrivacyNote =
    'Issued supply is public. Balances are not — only this wallet can see '
    'what it holds.';

/// The same line for an asset whose issued supply is *not* public. Rendering
/// [kNightjarSupplyPrivacyNote] here would assert the opposite of the figure
/// directly above it.
const String kNightjarPrivateSupplyNote =
    'Issued supply is private, and so are balances — only this wallet can see '
    'what it holds.';

/// The footnote a unique item's supply card carries instead. There is no
/// issued-versus-cap arithmetic to explain when both are one; what is worth
/// saying is *where* the one comes from.
const String kNightjarUniqueSupplyNote =
    'The cap of one is part of this asset\'s id, so every verifier on the '
    'channel checks it. Whether this wallet holds it is private.';

/// The footnote the supply card carries for [asset]. The card always states
/// what is public about this asset, and for a private one that is nothing.
String nightjarSupplyFootnote(NightjarAssetDetailData asset) {
  if (asset.isUniqueItem) return kNightjarUniqueSupplyNote;
  return asset.isPublic
      ? kNightjarSupplyPrivacyNote
      : kNightjarPrivateSupplyNote;
}

/// The one line the receive screen owes the user about where the address
/// came from.
const String kNightjarAddressDerivationNote =
    'This Nightjar address is derived from the seed this wallet already '
    'holds, so it needs no extra backup.';

/// Shown on the receive screen before the wallet has derived its identity.
const String kNightjarNoIdentityText =
    'Your Nightjar address is not available yet.';

/// Copy that replaces the assets list entirely, or null when the list
/// itself should render.
/// The concrete second line behind [nightjarListErrorText], when the loader
/// produced one. Kept beside it so a screen that shows the sentence can show
/// the values without reaching into the view itself.
String? nightjarListErrorDetail(NightjarViewData view) =>
    nightjarListErrorText(view) == null ? null : view.statusDetail;

String? nightjarListErrorText(NightjarViewData view) {
  // `statusMessage` is the loader's own sentence for this failure — which
  // channel, which key, which of the three unrelated things that used to all
  // read "can't reach the indexer". It is preferred over the canned copy
  // exactly because the canned copy is the one that misdirects.
  return switch (view.status) {
    NightjarViewStatus.notConfigured =>
      view.statusMessage ?? kNightjarNotConfiguredText,
    NightjarViewStatus.unreachable =>
      view.statusMessage ?? kNightjarUnreachableText,
    NightjarViewStatus.unverified =>
      view.statusMessage ?? kNightjarUnverifiedText,
    NightjarViewStatus.stale =>
      view.assets.isEmpty ? (view.statusMessage ?? kNightjarStaleText) : null,
    NightjarViewStatus.ready => null,
  };
}

/// How the copy from [nightjarListErrorText] should be tinted. A wallet that
/// has not been set up has not failed at anything.
NightjarMessageTone nightjarListErrorTone(NightjarViewData view) {
  return switch (view.status) {
    NightjarViewStatus.notConfigured => NightjarMessageTone.neutral,
    NightjarViewStatus.unreachable => NightjarMessageTone.error,
    NightjarViewStatus.unverified => NightjarMessageTone.error,
    NightjarViewStatus.stale => NightjarMessageTone.warning,
    NightjarViewStatus.ready => NightjarMessageTone.neutral,
  };
}

/// The banner above a list that still renders: the stale warning, or the
/// finality gap that explains why a just-received asset is not there yet.
/// Null when the view has nothing to excuse.
String? nightjarNoticeText(NightjarViewData view) {
  final lines = nightjarNoticeLines(view);
  return lines.isEmpty ? null : lines.join(' ');
}

/// Every caveat the view owes the user, in order of how much it changes what
/// the numbers mean. All of them are "degraded, not broken", which is why
/// they share one banner rather than competing for it.
List<String> nightjarNoticeLines(NightjarViewData view) {
  if (view.status == NightjarViewStatus.notConfigured ||
      view.status == NightjarViewStatus.unreachable ||
      view.status == NightjarViewStatus.unverified) {
    return const [];
  }
  return [
    if (view.status == NightjarViewStatus.stale && view.assets.isNotEmpty)
      view.statusMessage ?? kNightjarStaleText,
    if (view.borrowedChainTip) kNightjarBorrowedChainTipText,
    ?nightjarPendingMessagesText(
      pendingMessageCount: view.pendingMessageCount,
      finalityDepth: view.finalityDepth,
    ),
  ];
}

/// Tone for [nightjarNoticeText]. Both cases are "degraded, not broken".
const NightjarMessageTone kNightjarNoticeTone = NightjarMessageTone.warning;

/// `2 channel messages are waiting for 10 confirmations…` — the sentence
/// that turns a missing balance into an explained one. Null when the channel
/// carries nothing above the cut-off.
///
/// It says *messages*, and it says *channel*, because that is all the count
/// is. Anyone may write to a public channel, most of what is up there is
/// usually not this wallet's, and the replay has deliberately not decrypted
/// it — so a sentence claiming "3 notes are waiting" for this wallet would be
/// wrong far more often than right.
String? nightjarPendingMessagesText({
  required int pendingMessageCount,
  required int finalityDepth,
}) {
  if (pendingMessageCount <= 0) return null;
  final messages = pendingMessageCount == 1
      ? '1 channel message is'
      : '${formatGroupedInteger(pendingMessageCount)} channel messages are';
  return '$messages waiting to reach $finalityDepth confirmations. Anything '
      'in them that belongs to this wallet is not counted below yet.';
}

/// Every asset the wallet holds, as list rows, in a stable order: named
/// assets first (alphabetically), then unnamed ones by asset id, so a
/// re-replay of the channel cannot shuffle the list.
///
/// Pass [NightjarAssetsListing.ungrouped], not the whole view: a member of a
/// grouped collection is drawn inside its collection and must not also appear
/// here. Passing every asset still works and is what a caller with no
/// collections in view does.
List<NightjarAssetRowData> buildNightjarAssetRows({
  required List<NightjarAssetDetailData> assets,
  void Function(String assetId)? onAssetTap,
  Map<String, Uint8List> logos = const {},
}) {
  final rows = [
    for (final asset in assets)
      asset.toRowData(
        onTap: onAssetTap == null ? null : () => onAssetTap(asset.assetId),
        logoBytes: logos[asset.assetId],
      ),
  ];
  rows.sort(compareNightjarAssetRows);
  return rows;
}

/// Named before unnamed, then by the text actually on screen, then by asset
/// id so the order is total.
int compareNightjarAssetRows(NightjarAssetRowData a, NightjarAssetRowData b) {
  if (a.hasName != b.hasName) return a.hasName ? -1 : 1;
  final byTitle = nightjarAssetRowTitle(
    a,
  ).toLowerCase().compareTo(nightjarAssetRowTitle(b).toLowerCase());
  if (byTitle != 0) return byTitle;
  return a.assetId.compareTo(b.assetId);
}

/// Groups rows into the two cards the list shows. The split is by what is
/// *public about the asset* — its issued supply — never by anything about
/// the wallet's own holding, which is private in both groups.
List<NightjarAssetsSectionData> buildNightjarAssetSections(
  List<NightjarAssetRowData> rows,
) {
  final public = [
    for (final row in rows)
      if (row.isPublic) row,
  ];
  final private = [
    for (final row in rows)
      if (!row.isPublic) row,
  ];
  return [
    if (public.isNotEmpty)
      NightjarAssetsSectionData(title: 'Public assets', rows: public),
    if (private.isNotEmpty)
      NightjarAssetsSectionData(title: 'Private assets', rows: private),
  ];
}

/// The identity + supply facts the detail screen lists, in order.
///
/// Supply rows only appear for a public asset. A private asset gets no
/// supply row at all rather than a zero or an em dash, because an unknown
/// supply and a supply of zero are different things.
List<NightjarAssetFactData> buildNightjarAssetIdentityFacts(
  NightjarAssetDetailData asset,
) {
  final collection = asset.collection?.trim();
  final symbol = asset.symbol?.trim();
  final index = asset.index;
  return [
    NightjarAssetFactData(
      label: 'Asset id',
      value: truncateNightjarAssetId(asset.assetId),
      copyText: asset.assetId,
    ),
    NightjarAssetFactData(
      label: 'Name',
      value: asset.hasName ? asset.name!.trim() : 'Not declared',
    ),
    if (symbol != null && symbol.isNotEmpty)
      NightjarAssetFactData(label: 'Symbol', value: symbol),
    if (collection != null && collection.isNotEmpty)
      NightjarAssetFactData(
        label: 'Collection',
        value: truncateNightjarAssetId(collection),
        copyText: collection,
      ),
    // Only for a collection member: an index outside one is a number with
    // nothing to be an index into. The wallet carries the value across the FFI
    // now, and `collection` and `index` are disclosed together or not at all —
    // the replay reads both out of the same applied public issuance — so the
    // 'Not read yet' arm is unreachable for anything the replay produced. It
    // stays because this function also renders hand-built records, and a zero
    // here would claim "piece 0" about an asset whose index nobody read.
    if (collection != null && collection.isNotEmpty)
      NightjarAssetFactData(
        label: 'Index in collection',
        value: index == null ? 'Not read yet' : formatGroupedInteger(index),
      ),
    NightjarAssetFactData(
      label: 'Supply',
      value: asset.isPublic ? 'Public' : 'Private',
    ),
    // Both halves of the unique-item test are already above as their own
    // rows — the cap is in the supply card, the decimals are here — so this
    // one line is what stops a reader having to do the test themselves.
    if (asset.isUniqueItem)
      const NightjarAssetFactData(label: 'Unique item', value: 'Yes'),
    NightjarAssetFactData(
      label: 'Decimals',
      value: formatGroupedInteger(asset.decimals),
    ),
  ];
}

/// The supply facts, or an empty list for a private asset.
List<NightjarAssetFactData> buildNightjarAssetSupplyFacts(
  NightjarAssetDetailData asset,
) {
  if (!asset.isPublic) return const [];
  // A unique item's supply card is two rows both reading `1`, which is a
  // worse way of saying one true thing. Say the thing.
  if (asset.isUniqueItem) {
    return const [
      NightjarAssetFactData(label: 'Supply', value: 'One, and only one'),
    ];
  }
  final issued = asset.issuedSupply;
  final max = asset.maxSupply;
  return [
    NightjarAssetFactData(
      label: 'Issued supply',
      value: issued == null
          ? 'Not read yet'
          : formatNightjarAmount(issued, asset.decimals),
    ),
    NightjarAssetFactData(
      label: 'Max supply',
      value: max == null
          ? 'Not declared'
          : formatNightjarAmount(max, asset.decimals),
    ),
  ];
}

/// The wallet's own holding of this asset, as facts. Labelled so it cannot
/// be mistaken for a figure about the asset as a whole.
List<NightjarAssetFactData> buildNightjarWalletHoldingFacts(
  NightjarAssetDetailData asset,
) {
  // 'Your balance: 1' invites the question '1 what?' and invites arithmetic
  // on a thing that has no quantity. Owning a unique item is a yes or a no.
  if (asset.isUniqueItem) {
    return [
      NightjarAssetFactData(
        label: 'Yours',
        value: asset.ownsUniqueItem
            ? kNightjarUniqueOwnedText
            : kNightjarUniqueNotOwnedText,
      ),
    ];
  }
  return [
    NightjarAssetFactData(
      label: 'Your balance',
      value: formatNightjarAmount(asset.balance, asset.decimals),
    ),
    NightjarAssetFactData(
      label: 'Your notes',
      // Unspent only. `NjView.notes` became every note the wallet has ever
      // owned so that the activity feed could show what was *sent*; counting
      // the whole history here would make this row disagree with the balance
      // directly above it, which is the one number it exists to explain.
      value: formatGroupedInteger(
        asset.notes.where((note) => !note.spent).length,
      ),
    ),
  ];
}

/// The facts for one note row.
List<NightjarAssetFactData> buildNightjarNoteFacts(NightjarNoteRowData note) {
  final policy = note.policyText?.trim();
  return [
    NightjarAssetFactData(
      label: 'Amount',
      value: formatNightjarAmount(note.amount, note.decimals),
    ),
    NightjarAssetFactData(label: 'Position', value: note.position.toString()),
    NightjarAssetFactData(
      label: 'Created at height',
      value: note.createdHeight.toString(),
    ),
    NightjarAssetFactData(
      label: 'Policy',
      value: policy == null || policy.isEmpty ? 'None' : policy,
    ),
  ];
}

/// Heading for one note card — notes have no names, so they are numbered by
/// their position in the list the wallet is showing.
String nightjarNoteCardTitle(int index) => 'Note ${index + 1}';

/// The detail screen's title: the asset's name when it has one, otherwise
/// its truncated id.
String nightjarAssetDetailTitle(NightjarAssetDetailData asset) {
  return asset.hasName
      ? asset.name!.trim()
      : truncateNightjarAssetId(asset.assetId);
}

/// Copy for an asset id the current view does not hold.
String nightjarUnknownAssetText(String assetId) {
  return 'This wallet holds no asset with id '
      '${truncateNightjarAssetId(assetId)}.';
}
