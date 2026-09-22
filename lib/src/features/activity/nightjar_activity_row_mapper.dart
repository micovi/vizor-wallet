/// Nightjar messages as activity rows, so what this wallet *sent* is visible
/// where the user already looks for what arrived.
///
/// Everything here is a pure mapping from the items
/// `nightjar_activity_message.dart` classifies plus a table of block times and
/// a table of verified logos; nothing fetches, and nothing decides what the
/// wallet believes. The classification rules, and the four things this feature
/// is not allowed to claim, are documented there — this file is only how they
/// read.
///
/// Three choices in the copy are worth stating where they are encoded, because
/// each is a place a normal transaction feed would mislead:
///
/// * **A row's title is the verb, and the asset is on the supporting line.**
///   The defect this replaced rendered every surviving note `+N`, so a send
///   showed up as its change arriving. What a user is looking for is "did this
///   leave", and that belongs where the ZEC rows put it.
/// * **A self-transfer does not render as a payment of nothing.** Paying your
///   own address or consolidating notes gives a difference of zero, and `0`
///   on a row reads as a payment that failed. It gets its own title and the
///   *gross* amount that moved, unsigned.
/// * **A `+` never appears on the change of a payment.** Change is an output
///   of a message this wallet authored and is folded into that message's row;
///   it is never a row of its own. A `+` appears on a receipt, and on a net
///   whose row says "Net change" beside it.
///
/// Amounts stay [BigInt] base units plus an `int decimals` all the way to the
/// string, through `formatNightjarAmount`. No floating point.
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../core/privacy/privacy_mask.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_icon.dart';
import '../nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'activity_amount_text.dart';
import 'activity_feed_sections.dart';
import 'activity_row_mapper.dart';
import 'models/activity_row_data.dart';
import 'nightjar_activity_message.dart';

export 'nightjar_activity_message.dart';

/// Mask width for a hidden Nightjar amount, matching the ZEC activity rows.
const int kNightjarActivityAmountPrivacyMaskLength = 3;

/// The title of a row for a message this wallet signed and that moved value
/// out of it. It does not say to whom, and nothing in the data could.
const String kNightjarActivitySentTitle = 'Sent';

/// The title of a row for a message that appended notes to this wallet and
/// consumed none of its own. It names no payer: a `recovered` covenant payout
/// files here too, and it is not somebody paying.
const String kNightjarActivityReceivedTitle = 'Received';

/// Authored, and every output came back — consolidating notes, or paying your
/// own address. The difference is zero and that is not a payment of nothing.
const String kNightjarActivitySelfTransferTitle = 'Moved within this wallet';

/// A message this wallet only part-funded (a `buy`, a `fill`): the net is
/// meaningful, "sent" and "received" are not. The title is what makes a `+`
/// on this row a net rather than a receipt.
const String kNightjarActivityNetChangeTitle = 'Net change';

/// The ten-block window, on screen. The view closes at `tip − 10`, so a
/// payment just made is not in it — neither the spend nor its change — and
/// without this row the feed looks like it lost the money.
const String kNightjarActivitySettlingTitle = 'Nightjar is settling';

/// Rendered where a settled row shows its timestamp. Deliberately not "In
/// progress": the feed treats that string as routine and hides it, and the
/// time this row would show instead is the moment the screen was built.
const String kNightjarActivitySettlingStatus = 'Not final yet';

/// The row's title for [item].
String nightjarActivityTitle(NightjarActivityItem item) {
  return switch (item.kind) {
    NightjarActivityKind.sent => kNightjarActivitySentTitle,
    NightjarActivityKind.received => kNightjarActivityReceivedTitle,
    NightjarActivityKind.selfTransfer => kNightjarActivitySelfTransferTitle,
    NightjarActivityKind.netChange => kNightjarActivityNetChangeTitle,
    NightjarActivityKind.settling => kNightjarActivitySettlingTitle,
  };
}

/// The row's supporting line: which asset, and which block.
///
/// The height is here because the devnet's block times are useless for
/// ordering — regtest blocks start in February 2011 and advance about two
/// seconds each — and the rows are sorted by height. A row whose timestamp
/// cannot justify its position has to carry the number that can.
String nightjarActivitySubtitle(NightjarActivityItem item) {
  if (item.kind == NightjarActivityKind.settling) {
    return '${_settlingLead(item)} · ${_settlingCount(item)} above '
        '${item.blockLabel}';
  }
  return '${item.assetLabel} · ${item.blockLabel}';
}

String _settlingLead(NightjarActivityItem item) {
  final depth = item.settlingFinalityDepth;
  if (depth <= 0) return 'A payment you just made is not shown yet';
  return 'A payment from the last $depth blocks is not shown yet';
}

String _settlingCount(NightjarActivityItem item) =>
    item.settlingMessageCount == 1
    ? '1 message'
    : '${item.settlingMessageCount} messages';

/// `+1 DMT`, `-12 NC`, `988` — what [item] did to this wallet's holding.
///
/// The sign is the whole point of this function and every branch of it is a
/// claim being made or withheld:
///
/// * **sent** is negative: value left, and the change that came back is
///   already subtracted. It is never the change on its own.
/// * **received** is positive.
/// * **a self-transfer has no sign at all.** Its difference is zero; rendering
///   `0` would say the payment was empty and rendering `+` or `−` would say
///   the money went somewhere. It moved between this wallet's own notes.
/// * **a net is signed**, and the row's title says it is a net so the sign is
///   not read as a receipt or a send.
/// * **a settling row has no amount**, because the messages it counts are the
///   channel's and mostly other people's.
String nightjarActivityAmountText(
  NightjarActivityItem item, {
  bool privacyModeEnabled = false,
}) {
  if (item.kind == NightjarActivityKind.settling) return '--';
  final symbol = item.symbol?.trim() ?? '';
  if (privacyModeEnabled) {
    return hideAmountIfPrivacyMode(
      '',
      privacyModeEnabled: true,
      maskLength: kNightjarActivityAmountPrivacyMaskLength,
      denomination: symbol,
    );
  }
  final delta = item.delta ?? BigInt.zero;
  final (String sign, BigInt magnitude) = switch (item.kind) {
    NightjarActivityKind.sent => ('-', delta.abs()),
    NightjarActivityKind.received => ('+', delta.abs()),
    NightjarActivityKind.selfTransfer => ('', item.moved ?? BigInt.zero),
    NightjarActivityKind.netChange => (
      delta > BigInt.zero
          ? '+'
          : delta < BigInt.zero
          ? '-'
          : '',
      delta.abs(),
    ),
    NightjarActivityKind.settling => ('', BigInt.zero),
  };
  final amount = formatNightjarAmount(magnitude, item.decimals);
  return symbol.isEmpty ? '$sign$amount' : '$sign$amount $symbol';
}

/// One Nightjar message as a feed entry, using the same [ActivityRowData] and
/// row widget as every ZEC row.
///
/// [logos] is the verified-logo table for assets the user has **explicitly
/// accepted** (`nightjarAssetLogosProvider`, built from the acceptance set and
/// from nothing else). An asset with no entry keeps its icon. The lookup lives
/// here rather than at the four call sites so there is one place that decides
/// what a row looks like, and so the asset id travels with the bytes —
/// [ActivityRowLeadingImage] cannot be constructed without it
/// (`spec/asset-metadata-v0.md` section 5).
ActivityEntry nightjarActivityEntry({
  required BuildContext context,
  required NightjarActivityItem item,
  Map<String, Uint8List> logos = const {},
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  VoidCallback? onTap,
}) {
  final colors = context.colors;
  final isSettling = item.kind == NightjarActivityKind.settling;
  final row = ActivityRowData(
    stableId: item.stableId,
    title: nightjarActivityTitle(item),
    leadingIconName: _leadingIconName(item),
    leadingBackgroundColor: colors.background.neutralSubtleOpacity,
    leadingIconColor: colors.icon.regular,
    subtitle: nightjarActivitySubtitle(item),
    amountText: activityAmountTextForFormFactor(
      nightjarActivityAmountText(item, privacyModeEnabled: privacyModeEnabled),
    ),
    amountColor: _amountColor(item, colors),
    // The feed renders a non-routine status in place of the timestamp, and
    // "In progress" is one of the routine ones it hides. A settled Nightjar
    // message has no transaction whose status this could be reporting and
    // keeps its timestamp; the settling row wants the opposite — its time is
    // the moment the screen was built, which says nothing, and what the user
    // needs to read is that this is not final.
    statusText: isSettling ? kNightjarActivitySettlingStatus : '',
    statusIconName: isSettling ? AppIcons.loader : null,
    statusColor: colors.text.secondary,
    timestampText: formatActivityTimestamp(
      item.timestamp,
      dateOnly: dateOnlyTimestamp,
    ),
    // A settling row is a statement about the channel, not a thing to open.
    onTap: isSettling ? null : onTap,
  );
  return ActivityEntry(
    timestamp: item.timestamp,
    row: _withLogo(row, item: item, logos: logos),
  );
}

/// Rows for every item in [items], in the order [items] is already in — which
/// is block-height order; see `compareNightjarActivityItems`.
List<ActivityEntry> buildNightjarActivityEntries({
  required BuildContext context,
  required List<NightjarActivityItem> items,
  Map<String, Uint8List> logos = const {},
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  void Function(NightjarActivityItem item)? onItemTap,
}) {
  return [
    for (final item in items)
      nightjarActivityEntry(
        context: context,
        item: item,
        logos: logos,
        privacyModeEnabled: privacyModeEnabled,
        dateOnlyTimestamp: dateOnlyTimestamp,
        onTap: onItemTap == null ? null : () => onItemTap(item),
      ),
  ];
}

ActivityRowData _withLogo(
  ActivityRowData row, {
  required NightjarActivityItem item,
  required Map<String, Uint8List> logos,
}) {
  final bytes = logos[item.assetId];
  if (bytes == null) return row;
  return row.withLeadingImage(
    ActivityRowLeadingImage(
      bytes: bytes,
      // Section 5 wants `asset_id` or an unambiguous abbreviation of it. This
      // is the same head…tail truncation the Nightjar asset rows use, so the
      // string a user compares in the feed is character-for-character the one
      // the asset screen shows them.
      identityLabel: truncateNightjarAssetId(item.assetId),
    ),
  );
}

/// The ZEC feed's own vocabulary, so a Nightjar send and a ZEC send read the
/// same way at a glance. An accepted asset's logo replaces it.
String _leadingIconName(NightjarActivityItem item) {
  return switch (item.kind) {
    NightjarActivityKind.sent => AppIcons.plane,
    NightjarActivityKind.received => AppIcons.arrowDownCircle,
    NightjarActivityKind.selfTransfer => AppIcons.swapArrows,
    NightjarActivityKind.netChange => AppIcons.swapArrows,
    NightjarActivityKind.settling => AppIcons.loader,
  };
}

Color _amountColor(NightjarActivityItem item, AppColors colors) {
  final delta = item.delta ?? BigInt.zero;
  return switch (item.kind) {
    NightjarActivityKind.received => colors.text.positiveStrong,
    NightjarActivityKind.netChange when delta > BigInt.zero =>
      colors.text.positiveStrong,
    NightjarActivityKind.settling => colors.text.secondary,
    _ => outgoingAmountColor(colors),
  };
}
