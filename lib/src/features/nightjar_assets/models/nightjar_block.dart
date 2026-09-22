/// One block header row as `/api/block/{height}` and `/api/blocks` serve it.
///
/// The wallet wants exactly one field from this: [time]. A Nightjar note
/// carries the height it was created at and nothing else — the protocol has no
/// notion of wall-clock time — so anything that wants to place a note on a
/// timeline has to ask the indexer what time that block was mined at.
///
/// That is a fact about the Zcash chain, not a claim about Nightjar state: a
/// wrong block time misplaces a row in a list, it cannot change a balance or
/// make an unverified note look owned. It is therefore the one figure in this
/// feature taken on the indexer's word, and [minedAt] is nullable so a block
/// the indexer will not date leaves the caller with "unknown" rather than an
/// invented time.
library;

import 'nightjar_json.dart';

class NightjarBlock {
  const NightjarBlock({
    required this.height,
    required this.hash,
    required this.time,
    required this.canonical,
  });

  final int height;

  final String hash;

  /// Unix seconds the block header declares, or `0` when the indexer served
  /// no time for it.
  final int time;

  /// Whether the indexer considers this block part of the chain it replayed.
  /// A block below the finality depth — which is every block a note in the
  /// view was created in — is canonical.
  final bool canonical;

  /// [time] as a local [DateTime], or null when there is no time to give.
  DateTime? get minedAt =>
      time > 0 ? DateTime.fromMillisecondsSinceEpoch(time * 1000) : null;

  factory NightjarBlock.fromJson(Map<String, Object?> json) {
    return NightjarBlock(
      height: nightjarInt(json, 'height'),
      hash: nightjarStringOrNull(json, 'hash') ?? '',
      time: nightjarIntOr(json, 'time', 0),
      canonical: nightjarBoolOr(json, 'canonical', false),
    );
  }
}
