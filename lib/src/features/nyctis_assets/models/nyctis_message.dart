import 'dart:typed_data';

import 'nyctis_json.dart';

/// How the indexer's own replay treated a message. The wallet re-derives its
/// own verdict, so this is a hint for diagnostics, never a reason to skip
/// verification.
enum NyctisMessageOutcome {
  applied,
  ignored,
  published,
  named,
  unhandled,
  unknown;

  static NyctisMessageOutcome parse(String? raw) => switch (raw) {
    'applied' => NyctisMessageOutcome.applied,
    'ignored' => NyctisMessageOutcome.ignored,
    'published' => NyctisMessageOutcome.published,
    'named' => NyctisMessageOutcome.named,
    'unhandled' => NyctisMessageOutcome.unhandled,
    _ => NyctisMessageOutcome.unknown,
  };
}

/// One reassembled Nyctis message, as `/api/messages` serves it.
class NyctisMessage {
  const NyctisMessage({
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
  final NyctisMessageOutcome outcome;

  /// Why the indexer reached [outcome], when it was not `applied`.
  final String? reason;

  /// The indexer's decoded view of the body. Kept raw: the wallet decodes the
  /// body itself and this is only ever shown, never believed.
  final Map<String, Object?>? detail;

  /// The message bytes, present only when the request asked for `body=1`.
  /// This is what the replay consumes.
  final Uint8List? body;

  bool get hasBody => body != null;

  factory NyctisMessage.fromJson(Map<String, Object?> json) {
    final detail = json['detail'];
    return NyctisMessage(
      ord: nyctisInt(json, 'ord'),
      msgId: nyctisString(json, 'msg_id'),
      kind: nyctisInt(json, 'kind'),
      kindName: nyctisStringOrNull(json, 'kind_name') ?? '',
      height: nyctisInt(json, 'height'),
      txIndex: nyctisIntOr(json, 'tx_index', 0),
      actionIndex: nyctisIntOr(json, 'action_index', 0),
      txid: nyctisString(json, 'txid'),
      fragments: nyctisIntOr(json, 'fragments', 0),
      bodyLen: nyctisIntOr(json, 'body_len', 0),
      outcome: NyctisMessageOutcome.parse(
        nyctisStringOrNull(json, 'outcome'),
      ),
      reason: nyctisStringOrNull(json, 'reason'),
      detail: detail == null ? null : nyctisObject(detail, 'message detail'),
      body: nyctisHexBytesOrNull(json, 'body'),
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
/// Sorting on [NyctisMessage.ord] rather than reversing the list does the
/// same job for a clean walk and also survives pages that arrive out of order.
///
/// Repeats are dropped on [NyctisMessage.msgId]. A page boundary that serves
/// the same row twice is the kind of thing a strictly-exclusive `before`
/// cursor is supposed to make impossible, but "supposed to" is the indexer's
/// promise rather than this wallet's check — and a fold that applies one
/// message twice does not fail, it just produces a different balance. The
/// caller still sees the loss: the count is compared against the listing's
/// own `total`.
List<NyctisMessage> nyctisMessagesInChainOrder(
  Iterable<NyctisMessage> newestFirst,
) {
  final ordered = List<NyctisMessage>.of(newestFirst)
    ..sort((a, b) => a.ord.compareTo(b.ord));
  final seen = <String>{};
  return List<NyctisMessage>.unmodifiable([
    for (final message in ordered)
      if (seen.add(message.msgId)) message,
  ]);
}
