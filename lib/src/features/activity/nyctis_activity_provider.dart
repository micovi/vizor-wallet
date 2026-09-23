/// The read path that puts Nyctis messages into the activity feed, and the
/// block-time lookup that lets them be placed on a timeline at all.
///
/// The hard constraint here is that **the ZEC activity feed must not depend on
/// any of this**. A Nyctis indexer that is unconfigured, unreachable, slow,
/// rate limiting, or serving a channel the wallet refuses to believe has to
/// cost the user nothing but the extra rows — no spinner, no error line, no
/// empty state where a transaction list used to be. Everything below is shaped
/// to make that the only possible outcome:
///
/// * [nyctisActivityItemsProvider] is a synchronous [Provider]. It reads the
///   two asynchronous inputs through `.value`, which is null while a load is
///   in flight and null when it failed, and answers `const []` for both. A
///   screen watching it can never await it and can never see its error.
/// * [nyctisActivityBlockTimesProvider] catches every failure per height.
///   A block the indexer will not date leaves that row undated; undated
///   entries sort last and group under "Earlier", which is the behaviour
///   `ActivityEntry.timestamp` being nullable already specifies. The order of
///   the rows never depends on it: they are sorted by block height and carry
///   it in their subtitle, because this devnet's block times are two seconds
///   apart and fifteen years old.
/// * Nothing here ever throws into a widget build.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../main.dart' show log;
import '../../providers/nyctis_config_provider.dart';
import '../nyctis_assets/providers/nyctis_assets_view_provider.dart';
import '../nyctis_assets/services/nyctis_indexer_client.dart';
import '../nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'nyctis_activity_row_mapper.dart';
import 'screens/nyctis_activity_detail_screen.dart';

/// Ceiling on block-time requests one pass will make.
///
/// The distinct-height count is a handful in practice — one per message that
/// touched this wallet, at both ends of a note's life — so this never binds.
/// It exists so a pathological view (thousands of dust notes, each in its own
/// block) cannot turn opening the activity screen into thousands of HTTP
/// requests. Heights past the cut stay undated, which costs a section heading
/// and nothing else: the ordering is by height either way.
const int kNyctisActivityMaxBlockTimeFetches = 64;

/// Block times the wallet has already learned, keyed by height.
///
/// Worth caching because a mined block's time does not change: the same
/// heights are re-derived on every Nyctis refresh, and re-asking for them
/// would put an HTTP round trip behind every rebuild of the activity screen.
/// Not persisted — it is a display detail, and a cold start pays for it once.
class NyctisBlockTimeCache {
  NyctisBlockTimeCache();

  final Map<int, DateTime> _times = {};

  /// The times known for [heights], omitting the ones that are not.
  Map<int, DateTime> knownFor(Iterable<int> heights) {
    return {for (final height in heights) height: ?_times[height]};
  }

  bool contains(int height) => _times.containsKey(height);

  void remember(int height, DateTime time) {
    _times[height] = time;
  }

  void clear() => _times.clear();
}

/// Process-wide because heights are chain facts, not account facts: switching
/// accounts changes which notes the wallet holds, never when block 7 174 was
/// mined.
final nyctisBlockTimeCacheProvider = Provider<NyctisBlockTimeCache>(
  (ref) => NyctisBlockTimeCache(),
);

/// Resolves block times for [heights]. Injectable so a test can answer
/// without an indexer.
typedef NyctisBlockTimeLoader =
    Future<Map<int, DateTime>> Function(List<int> heights);

/// The shipped loader: asks the configured indexer for each height it does not
/// already have, one `GET /api/block/{height}` at a time.
final nyctisBlockTimeLoaderProvider = Provider<NyctisBlockTimeLoader>(
  (ref) =>
      (heights) => loadNyctisBlockTimes(ref, heights),
);

/// Block times for every height a Nyctis row could be dated by — both the
/// height a note was created at and, when it was spent, the height it was
/// spent at. A send is dated by the second one.
///
/// Returns whatever it managed to learn. A height that could not be dated is
/// simply absent from the map — there is no error state here on purpose,
/// because there is no user action that would follow one.
final nyctisActivityBlockTimesProvider = FutureProvider<Map<int, DateTime>>((
  ref,
) async {
  final view = ref.watch(nyctisAssetsViewProvider).value;
  if (view == null) return const {};
  final heights = nyctisActivityMessageHeights(view);
  if (heights.isEmpty) return const {};
  final loader = ref.watch(nyctisBlockTimeLoaderProvider);
  try {
    return await loader(heights);
  } catch (error, stackTrace) {
    // Unreachable through the shipped loader, which already swallows per
    // height. An injected one is not obliged to, and a thrown block time must
    // not become an activity-screen error.
    log('Activity: Nyctis block times failed: $error\n$stackTrace');
    return const {};
  }
});

/// The Nyctis messages the activity feed should show, already ordered by
/// block height, newest first.
///
/// One row per message — what the wallet sent, what it received, what it moved
/// within itself — never one row per surviving note. See
/// `nyctis_activity_message.dart` for the classification and for what it
/// refuses to claim.
///
/// Synchronous by construction — see the library doc. An empty list is the
/// answer for every degraded case: not configured, still loading, unreachable,
/// unverified (the view clears its own assets then), or simply no notes.
final nyctisActivityItemsProvider = Provider<List<NyctisActivityItem>>((
  ref,
) {
  // A build without the feature never builds the view: the home and activity
  // feeds watch this provider unconditionally.
  if (!ref.watch(nyctisFeatureEnabledProvider)) {
    return const <NyctisActivityItem>[];
  }
  final view = ref.watch(nyctisAssetsViewProvider).value;
  if (view == null || view.assets.isEmpty) {
    return const <NyctisActivityItem>[];
  }
  final blockTimes =
      ref.watch(nyctisActivityBlockTimesProvider).value ??
      const <int, DateTime>{};
  return buildNyctisActivityItems(view: view, blockTimes: blockTimes);
});

/// Fetches the block times [heights] is missing, serving the rest from
/// [nyctisBlockTimeCacheProvider].
///
/// Every failure is per height and silent: a 404 for a block the indexer
/// pruned, a timeout, a rate limit. None of them are worth a message, because
/// the only thing lost is a row's position in a list that already tolerates
/// not knowing (`ActivityEntry.timestamp` is nullable and sorts such entries
/// last).
Future<Map<int, DateTime>> loadNyctisBlockTimes(
  Ref ref,
  List<int> heights,
) async {
  final cache = ref.read(nyctisBlockTimeCacheProvider);
  final missing = [
    for (final height in heights)
      if (!cache.contains(height)) height,
  ];
  if (missing.isEmpty) return cache.knownFor(heights);

  // Reading the configuration can throw on a wallet whose bootstrap never
  // produced one — a locked store, a first run, a widget test that renders the
  // feed on its own. None of those are network faults and none of them are
  // this provider's to report.
  final NyctisIndexerClient client;
  try {
    final config = ref.read(nyctisConfigProvider);
    if (!config.isUsable) return cache.knownFor(heights);
    client = NyctisIndexerClient(baseUri: config.indexerBaseUri);
  } catch (_) {
    return cache.knownFor(heights);
  }

  try {
    for (final height in missing.take(kNyctisActivityMaxBlockTimeFetches)) {
      try {
        final block = await client.fetchBlock(height);
        final minedAt = block.minedAt;
        if (minedAt != null) cache.remember(height, minedAt);
      } catch (_) {
        // Leave the height undated. Retrying belongs to the next refresh.
      }
    }
  } finally {
    client.close();
  }

  return cache.knownFor(heights);
}

/// The receipt the row for [item] opens, out of the same view the row was
/// built from.
///
/// The classification travels as the item itself rather than being redone from
/// the id in the path: a `msg_id` does not say whether this wallet signed the
/// message, and rebuilding that on the far side of a route is a second place
/// for it to be decided differently. What this function adds is the part a row
/// had no space for — this wallet's notes on both sides of the message.
///
/// A null [view] (still loading, unreachable, unverified) yields a receipt
/// with no notes rather than no receipt: the verb and the amount are on the
/// item and stay true, and the screen simply has no note list to show.
NyctisActivityDetailArgs nyctisActivityDetailArgsFor(
  NyctisActivityItem item, {
  NyctisViewData? view,
}) {
  return NyctisActivityDetailArgs(
    item: item,
    notes: view == null
        ? const []
        : buildNyctisActivityDetailNotes(
            view: view,
            msgId: item.msgId,
            // The row is about one asset of the message; so is its receipt.
            assetId: item.assetId,
          ),
  );
}
