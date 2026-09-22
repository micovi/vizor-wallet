import 'dart:typed_data';

import 'nightjar_json.dart';

/// How the indexer's own replay treated a message. The wallet re-derives its
/// own verdict, so this is a hint for diagnostics, never a reason to skip
/// verification.
enum NightjarMessageOutcome {
  applied,
  ignored,
  published,
  named,
  unhandled,
  unknown;

  static NightjarMessageOutcome parse(String? raw) => switch (raw) {
    'applied' => NightjarMessageOutcome.applied,
    'ignored' => NightjarMessageOutcome.ignored,
    'published' => NightjarMessageOutcome.published,
    'named' => NightjarMessageOutcome.named,
    'unhandled' => NightjarMessageOutcome.unhandled,
    _ => NightjarMessageOutcome.unknown,
  };
}

/// One reassembled Nightjar message, as `/api/messages` serves it.
class NightjarMessage {
  const NightjarMessage({
    required this.ord,
    required this.msgId,
    required this.kind,
    required this.kindName,
    required this.height,
    required this.txIndex,
    required this.actionIndex,
    required this.txid,
    required this.fragments,
    required this.bodyLen,
    required this.outcome,
    required this.reason,
    required this.detail,
    required this.body,
  });

  /// Chain-order key: height, transaction index, and action index packed into
  /// one ascending integer. Also the paging cursor.
  final int ord;

  final String msgId;
  final int kind;
  final String kindName;
  final int height;
  final int txIndex;
  final int actionIndex;
  final String txid;

  /// Number of memos this message was reassembled from.
  final int fragments;

  final int bodyLen;
  final NightjarMessageOutcome outcome;

  /// Why the indexer reached [outcome], when it was not `applied`.
  final String? reason;

  /// The indexer's decoded view of the body. Kept raw: the wallet decodes the
  /// body itself and this is only ever shown, never believed.
  final Map<String, Object?>? detail;

  /// The message bytes, present only when the request asked for `body=1`.
  /// This is what the replay consumes.
  final Uint8List? body;

  bool get hasBody => body != null;

  factory NightjarMessage.fromJson(Map<String, Object?> json) {
    final detail = json['detail'];
    return NightjarMessage(
      ord: nightjarInt(json, 'ord'),
      msgId: nightjarString(json, 'msg_id'),
      kind: nightjarInt(json, 'kind'),
      kindName: nightjarStringOrNull(json, 'kind_name') ?? '',
      height: nightjarInt(json, 'height'),
      txIndex: nightjarIntOr(json, 'tx_index', 0),
      actionIndex: nightjarIntOr(json, 'action_index', 0),
      txid: nightjarString(json, 'txid'),
      fragments: nightjarIntOr(json, 'fragments', 0),
      bodyLen: nightjarIntOr(json, 'body_len', 0),
      outcome: NightjarMessageOutcome.parse(
        nightjarStringOrNull(json, 'outcome'),
      ),
      reason: nightjarStringOrNull(json, 'reason'),
      detail: detail == null ? null : nightjarObject(detail, 'message detail'),
      body: nightjarHexBytesOrNull(json, 'body'),
    );
  }
}

/// Puts messages into the order the replay has to see them, once each.
///
/// `/api/messages` serves newest-first because that is the order a list wants,
/// and a full fetch therefore pages *backwards* through history. The replay is
/// a fold over the channel and only means anything in chain order, so the
/// collected pages have to be turned around before they are applied.
///
/// Sorting on [NightjarMessage.ord] rather than reversing the list does the
/// same job for a clean walk and also survives pages that arrive out of order.
///
/// Repeats are dropped on [NightjarMessage.msgId]. A page boundary that serves
/// the same row twice is the kind of thing a strictly-exclusive `before`
/// cursor is supposed to make impossible, but "supposed to" is the indexer's
/// promise rather than this wallet's check — and a fold that applies one
/// message twice does not fail, it just produces a different balance. The
/// caller still sees the loss: the count is compared against the listing's
/// own `total`.
List<NightjarMessage> nightjarMessagesInChainOrder(
  Iterable<NightjarMessage> newestFirst,
) {
  final ordered = List<NightjarMessage>.of(newestFirst)
    ..sort((a, b) => a.ord.compareTo(b.ord));
  final seen = <String>{};
  return List<NightjarMessage>.unmodifiable([
    for (final message in ordered)
      if (seen.add(message.msgId)) message,
  ]);
}
