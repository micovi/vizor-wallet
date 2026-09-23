/// Turning the notes a Nyctis replay reports into the *messages* that moved
/// them, which is the only form a history can be read out of.
///
/// `NyView.notes` is every note this wallet has ever owned on the channel,
/// spent ones marked, each naming the message that created it
/// (`createdBy`) and the message that consumed it (`spentBy`). A list of
/// notes is not a history: after a payment the only note left behind is the
/// change, and a change note rendered on its own reads as money arriving —
/// `+988 NC` for the remainder of 1 000 NC leaving. Grouping by `msg_id`
/// recovers the payment, and that is all this file does.
///
/// **The classification, and why each rule is the weakest one that holds**
/// (the contract is the doc comment on `nyctisReplay` in
/// `lib/src/rust/api/nyctis.dart`):
///
/// * **Authored by this wallet** — every note with `spentBy == M` is an input
///   it owned, and when that count equals `spentInputs` it owned *all* of M's
///   inputs, so it signed M. Nothing else in the data says "I signed this";
///   owning one input of two is a co-signed transition, not a send. What left
///   is `sum(inputs owned) − sum(outputs owned)`, and the outputs owned are
///   **change**, never a receipt.
/// * **Receipt** — no note has `spentBy == M` and some note has
///   `createdBy == M`. The amount is the sum of those notes. This files a
///   `recovered` covenant payout as a receipt too, which is what it is: the
///   wallet did not sign it. The row says "Received"; it never names a payer,
///   because no payer is knowable here.
/// * **Partly funded** — some inputs owned, but fewer than `spentInputs`. A
///   `buy` or a `fill` is exactly this: two parties' notes in one transition
///   and neither of them its sole author. The *net* is meaningful and is what
///   the row shows; "sent" is not, so the row says "Net change" and a `+` on
///   it is explicitly a net rather than a receipt.
///
/// **What is never claimed here**, each because the data cannot support it:
///
/// * **Who was paid, and how much.** The outputs of a message this wallet does
///   not hold are ciphertexts addressed to keys it has not got.
///   `createdOutputs` says one exists; its amount is *unknowable*, not zero.
///   `totalOutputs − ownedOutputs` is therefore a count and never becomes an
///   amount, and no row carries a recipient.
/// * **That a self-payment is a payment of nothing.** Consolidating two notes
///   into one, or paying your own address, owns every output, so the
///   difference is zero — and a `0` on a row would read as a failed or empty
///   payment. It is neither: the money moved and did not leave. That case gets
///   its own kind ([NyctisActivityKind.selfTransfer]), the *gross* amount
///   that moved, and no sign.
/// * **That the feed is up to date.** The view closes at `tip − 10`, so for
///   ten blocks after a send the spend does not exist: the input still reads
///   unspent and the balance is the old one. `previewMessages` is the only
///   signal, and [NyctisActivityKind.settling] is it on screen — without a
///   row there, the feed looks like it lost the money and then made it
///   reappear.
///
/// Ordering is by **block height**, not by time. On the regtest devnet blocks
/// start in February 2011 and advance about two seconds each, so seven
/// thousand blocks land inside a minute and every row would group under
/// "Earlier" with its neighbours in an order the timestamps cannot justify.
/// Height is the true chain order, it is always known, and it is on the row
/// ([NyctisActivityItem.blockLabel]) so the ordering stays legible when the
/// timestamps are not.
///
/// Amounts are [BigInt] base units plus an `int decimals` all the way to the
/// string, through `formatNyctisAmount`. No floating point.
library;

import 'package:flutter/foundation.dart';

import '../nyctis_assets/widgets/nyctis_asset_row_data.dart';

/// What one Nyctis message did to this wallet.
enum NyctisActivityKind {
  /// This wallet owned every input the message consumed, so it signed it, and
  /// value left. Its own outputs in that message are change.
  sent,

  /// This wallet owned no input the message consumed and holds notes it
  /// created. Value arrived; who sent it is not knowable.
  received,

  /// Authored, and the difference is zero: every output came back. The money
  /// moved between this wallet's own notes and did not leave.
  selfTransfer,

  /// This wallet funded part of the message. The net is meaningful; "sent" and
  /// "received" are not.
  netChange,

  /// Not a message of this wallet's at all: the channel is carrying messages
  /// above the finality cut-off, so a payment just made is invisible.
  settling,
}

/// One row's worth of Nyctis history: what one message did to this wallet's
/// holding of one asset.
///
/// One message per row — except that a message can move two different assets
/// (a `buy` or a `fill` carries the maker's asset and the taker's), and two
/// amounts in unrelated units cannot be added. Such a message yields one row
/// per asset, all sharing [msgId], [kind] and [height]; the classification is
/// a property of the message and never of one asset inside it.
@immutable
class NyctisActivityItem {
  const NyctisActivityItem({
    required this.msgId,
    required this.assetId,
    required this.kind,
    required this.delta,
    required this.moved,
    required this.decimals,
    required this.height,
    this.name,
    this.symbol,
    this.timestamp,
    this.ownedInputs = 0,
    this.totalInputs = 0,
    this.ownedOutputs = 0,
    this.totalOutputs = 0,
    this.settlingMessageCount = 0,
    this.settlingFinalityDepth = 0,
  });

  /// A row for the ten-block window: `count` messages the channel carries
  /// above the finality cut-off, which the replay has not applied.
  ///
  /// [viewHeight] is the height the view closed at, so the row can say which
  /// block the wallet can currently see up to.
  const NyctisActivityItem.settling({
    required int count,
    required BigInt viewHeight,
    required this.settlingFinalityDepth,
    this.timestamp,
  }) : msgId = '',
       assetId = '',
       kind = NyctisActivityKind.settling,
       delta = null,
       moved = null,
       decimals = 0,
       height = viewHeight,
       name = null,
       symbol = null,
       ownedInputs = 0,
       totalInputs = 0,
       ownedOutputs = 0,
       totalOutputs = 0,
       settlingMessageCount = count;

  /// Lowercase hex `msg_id` of the message this row is about. Empty only for
  /// [NyctisActivityKind.settling], which is about no message in particular.
  final String msgId;

  /// Hex asset id. Always present except on a settling row — it is the asset's
  /// only true identifier.
  final String assetId;

  final NyctisActivityKind kind;

  /// Name the issuer's `ASSET` message declared, or null. Unnamed is normal.
  final String? name;

  /// Symbol the issuer declared, or null.
  final String? symbol;

  /// The change this message made to what the wallet holds of [assetId], in
  /// base units: `sum(outputs owned) − sum(inputs owned)`. Negative when value
  /// left. Zero for a self-transfer, which is the point of that kind existing.
  ///
  /// Null on a settling row, which has no amount at all.
  final BigInt? delta;

  /// What this wallet's own notes carried *into* the message, in base units.
  ///
  /// Only meaningful where the wallet owned inputs; it is what a self-transfer
  /// renders, because its [delta] is zero and the money did move. Never a
  /// claim about what anyone received.
  final BigInt? moved;

  /// Base-unit exponent for [delta] and [moved].
  final int decimals;

  /// The height the message completed at — the height the money moved, not the
  /// height the surviving note happens to have been created at (for a send
  /// they are the same message and therefore the same block).
  final BigInt height;

  /// When that block was mined, or null when nothing could tell the wallet.
  /// Never invented: an undated row keeps its place by [height].
  final DateTime? timestamp;

  /// How many of the message's inputs this wallet owned, and how many there
  /// were. Equal means this wallet signed it.
  final int ownedInputs;
  final int totalInputs;

  /// How many of the message's outputs this wallet can open, and how many it
  /// appended. A difference means an output is addressed to somebody else —
  /// **a count, not an amount**. Nothing here turns it into a figure.
  final int ownedOutputs;
  final int totalOutputs;

  /// Messages the channel carries above the finality cut-off, on a
  /// [NyctisActivityKind.settling] row. Zero on every other row.
  final int settlingMessageCount;

  /// How many blocks deep a message must be before the replay applies it —
  /// ten on the devnet. It is the length of the window in which a payment this
  /// wallet has just made is invisible, which is the only reason the settling
  /// row exists.
  final int settlingFinalityDepth;

  bool get hasName => (name ?? '').trim().isNotEmpty;

  bool get hasSymbol => (symbol ?? '').trim().isNotEmpty;

  /// True when the message appended an output this wallet cannot read.
  ///
  /// It is why "sent" can be said at all — something went somewhere else. It
  /// says nothing about how much, and there is no field on this class that
  /// could.
  bool get hasUnreadableOutputs => totalOutputs > ownedOutputs;

  /// True when the message consumed nothing, i.e. it is an issuance.
  bool get isIssuance =>
      totalInputs == 0 && kind == NyctisActivityKind.received;

  /// The asset as a row names it: the declared name, or the truncated asset id
  /// when the issuer never published one — the same choice the Nyctis asset
  /// rows make, so the two surfaces show the same string.
  String get assetLabel =>
      hasName ? name!.trim() : truncateNyctisAssetId(assetId);

  /// `block 7,257`. On the row because the devnet's block times are useless
  /// for ordering and the height is what the rows are actually sorted by.
  String get blockLabel => 'block ${_groupDigits(height.toString())}';

  /// Stable while this message and asset are in the view. A message id is
  /// content-derived and a replay recomputes it, so this does not shuffle
  /// between refreshes the way a note position does when a note is spent.
  String get stableId => switch (kind) {
    NyctisActivityKind.settling => 'nyctis-settling',
    _ => 'nyctis-msg:$msgId:$assetId',
  };
}

/// Every Nyctis message that touched this wallet, newest block first.
///
/// [blockTimes] is keyed by block height; a height it does not carry yields a
/// null [NyctisActivityItem.timestamp] rather than a guess. The order is
/// total — height, then message id, then asset id — so a re-replay of the same
/// channel cannot shuffle two rows that share a block.
///
/// [settlingTimestamp] dates the settling row, which is the one row that is
/// about *now* rather than about a block. It defaults to the current time so
/// the row sorts to the top of a feed that is otherwise sorted by time; a test
/// pins it.
List<NyctisActivityItem> buildNyctisActivityItems({
  required NyctisViewData view,
  Map<int, DateTime> blockTimes = const {},
  DateTime? settlingTimestamp,
}) {
  final messages = _groupByMessage(view);
  final items = <NyctisActivityItem>[];
  for (final message in messages) {
    items.addAll(message.toItems(blockTimes));
  }
  items.sort(compareNyctisActivityItems);

  // The ten-block window, and only where the wallet has Nyctis history of
  // its own. A channel is public: the messages above the cut-off are usually
  // somebody else's, and announcing them to a wallet that holds nothing on
  // this channel is noise about strangers. A wallet that has just paid always
  // has history — the note it spent.
  final settling = _settlingItem(view, settlingTimestamp);
  if (settling != null && items.isNotEmpty) items.insert(0, settling);
  return items;
}

/// Settling first, then newest block first, then message id, then asset id.
int compareNyctisActivityItems(
  NyctisActivityItem a,
  NyctisActivityItem b,
) {
  final aSettling = a.kind == NyctisActivityKind.settling;
  final bSettling = b.kind == NyctisActivityKind.settling;
  if (aSettling != bSettling) return aSettling ? -1 : 1;
  final byHeight = b.height.compareTo(a.height);
  if (byHeight != 0) return byHeight;
  final byMessage = a.msgId.compareTo(b.msgId);
  if (byMessage != 0) return byMessage;
  return a.assetId.compareTo(b.assetId);
}

/// Every distinct block height a row in [view] would be dated by, ascending.
///
/// Both ends of a note's life: the height it was created at and, when it was
/// spent, the height it was spent at. A send is dated by the second one, and
/// asking only for creation heights left every send undated.
List<int> nyctisActivityMessageHeights(NyctisViewData view) {
  final heights = <int>{};
  for (final asset in view.assets) {
    for (final note in asset.notes) {
      heights.add(note.createdHeight.toInt());
      final spentHeight = note.spentHeight;
      if (spentHeight != null) heights.add(spentHeight.toInt());
    }
  }
  final sorted = heights.toList()..sort();
  return sorted;
}

NyctisActivityItem? _settlingItem(NyctisViewData view, DateTime? at) {
  if (view.pendingMessageCount <= 0) return null;
  if (view.isUnverified || !view.isConfigured) return null;
  return NyctisActivityItem.settling(
    count: view.pendingMessageCount,
    viewHeight: view.viewHeight ?? BigInt.zero,
    settlingFinalityDepth: view.finalityDepth,
    timestamp: at ?? DateTime.now(),
  );
}

/// One note of one asset, with the asset's naming carried alongside so the
/// grouping does not have to look it up again.
@immutable
class _OwnedNote {
  const _OwnedNote({
    required this.assetId,
    required this.name,
    required this.symbol,
    required this.decimals,
    required this.amount,
    required this.note,
  });

  final String assetId;
  final String? name;
  final String? symbol;
  final int decimals;
  final BigInt amount;
  final NyctisNoteRowData note;
}

/// One message, and this wallet's side of it.
class _Message {
  _Message(this.msgId);

  final String msgId;

  /// Notes this message consumed that this wallet owned.
  final List<_OwnedNote> inputs = [];

  /// Notes this message appended that this wallet can open.
  final List<_OwnedNote> outputs = [];

  /// How many inputs the message had in total, from whichever side reported
  /// it. Both sides agree; an input's `spentInputs` and an output's
  /// `createdInputs` are the same count of the same message.
  int? get totalInputs =>
      inputs.isNotEmpty ? inputs.first.note.spentInputs : _outputCreatedInputs;

  int? get totalOutputs => inputs.isNotEmpty
      ? inputs.first.note.spentOutputs
      : _outputCreatedOutputs;

  int? get _outputCreatedInputs =>
      outputs.isEmpty ? null : outputs.first.note.createdInputs;

  int? get _outputCreatedOutputs =>
      outputs.isEmpty ? null : outputs.first.note.createdOutputs;

  /// The height the message completed at: the height it spent this wallet's
  /// inputs at, or — when it spent none — the height it created its outputs
  /// at. Both are the same block; a message completes once.
  BigInt get height {
    for (final input in inputs) {
      final spentHeight = input.note.spentHeight;
      if (spentHeight != null) return spentHeight;
    }
    if (outputs.isNotEmpty) return outputs.first.note.createdHeight;
    return BigInt.zero;
  }

  /// Whether this wallet signed the message: it owned every input.
  ///
  /// A null `spentInputs` is not authorship. It means the producer of these
  /// notes did not say how many inputs the message had, and a missing count
  /// must not be read as "the count I happen to have".
  bool get isAuthored {
    if (inputs.isEmpty) return false;
    final total = totalInputs;
    return total != null && inputs.length == total;
  }

  List<NyctisActivityItem> toItems(Map<int, DateTime> blockTimes) {
    final assetIds = <String>{
      for (final input in inputs) input.assetId,
      for (final output in outputs) output.assetId,
    };
    final timestamp = blockTimes[height.toInt()];
    final items = <NyctisActivityItem>[];
    for (final assetId in assetIds) {
      final assetInputs = [
        for (final input in inputs)
          if (input.assetId == assetId) input,
      ];
      final assetOutputs = [
        for (final output in outputs)
          if (output.assetId == assetId) output,
      ];
      final inSum = _sum(assetInputs);
      final outSum = _sum(assetOutputs);
      final naming = assetOutputs.isNotEmpty
          ? assetOutputs.first
          : assetInputs.first;
      items.add(
        NyctisActivityItem(
          msgId: msgId,
          assetId: assetId,
          kind: _kindFor(inSum: inSum, outSum: outSum),
          delta: outSum - inSum,
          moved: inSum,
          decimals: naming.decimals,
          height: height,
          name: naming.name,
          symbol: naming.symbol,
          timestamp: timestamp,
          ownedInputs: inputs.length,
          totalInputs: totalInputs ?? inputs.length,
          ownedOutputs: outputs.length,
          totalOutputs: totalOutputs ?? outputs.length,
        ),
      );
    }
    return items;
  }

  NyctisActivityKind _kindFor({
    required BigInt inSum,
    required BigInt outSum,
  }) {
    if (inputs.isEmpty) return NyctisActivityKind.received;
    if (!isAuthored) {
      // Some inputs owned, not all: a transition this wallet co-funded. The
      // net is the only honest figure, whichever way it points.
      return NyctisActivityKind.netChange;
    }
    if (outSum > inSum) {
      // Authored, and this asset *arrived* — the other side of a swap this
      // wallet signed. Not a receipt, because the wallet paid for it in
      // another asset, and not a send. It is a net.
      return NyctisActivityKind.netChange;
    }
    if (inSum == outSum) return NyctisActivityKind.selfTransfer;
    return NyctisActivityKind.sent;
  }

  static BigInt _sum(List<_OwnedNote> notes) {
    var total = BigInt.zero;
    for (final note in notes) {
      total += note.amount;
    }
    return total;
  }
}

List<_Message> _groupByMessage(NyctisViewData view) {
  final messages = <String, _Message>{};
  _Message messageFor(String msgId) =>
      messages.putIfAbsent(msgId, () => _Message(msgId));

  for (final asset in view.assets) {
    for (final note in asset.notes) {
      final owned = _OwnedNote(
        assetId: asset.assetId,
        name: asset.name,
        symbol: asset.symbol,
        decimals: note.decimals,
        amount: note.amount,
        note: note,
      );
      // A note whose producer did not name its creating message is grouped
      // with nothing and claims nothing: it becomes a message of its own with
      // one output, which renders as "this note arrived" — exactly what a bare
      // note supports and no more.
      final createdBy = note.createdBy.isEmpty
          ? 'note:${asset.assetId}:${note.position}'
          : note.createdBy;
      messageFor(createdBy).outputs.add(owned);
      final spentBy = note.spentBy;
      if (spentBy != null && spentBy.isNotEmpty) {
        messageFor(spentBy).inputs.add(owned);
      }
    }
  }
  return messages.values.toList(growable: false);
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
