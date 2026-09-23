/// Nyctis payments this wallet has handed to the network and the channel
/// has not yet settled.
///
/// Two failures share one cause here — a note spent by a message that is not
/// final yet still looks unspent:
///
/// * **The same plan sent twice.** The receipt is left, the review is somehow
///   reached again, Send is pressed again. A second Zcash transaction carries
///   identical memos (same `msg_id`) and the channel ignores it as already
///   applied — after its ZEC has been spent.
/// * **A new payment picking the same notes.** The replay applies a message
///   only once it is [NyctisViewData.finalityDepth] blocks deep, and
///   `nyctisBuildPay` selects inputs from that replay. For those blocks — and
///   for as long as a broadcast sits unsent in the wallet's own outbox — the
///   notes the first payment consumed read as unspent, so a second payment
///   proves against them, and the channel ignores it as a double spend, again
///   after its ZEC is gone.
///
/// `nyctisBuildPay` takes no exclusion set yet, so the guard is here: while
/// a payment of an asset is in flight, the wallet does not build another
/// payment of that asset, and a plan whose `msg_id` is recorded cannot be sent
/// again. A record settles when the view shows one of the wallet's notes spent
/// or created by that message, or when the view's canonical height has passed
/// the plan's anchor window — past that, a message still unapplied can only be
/// ignored ("unknown anchor"), so its notes are free again.
///
/// Records persist in the encrypted store, so an app restart while a
/// broadcast is still retrying from the outbox does not reopen the window.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_secure_store.dart';
import '../services/nyctis_send_flow.dart';
import '../widgets/nyctis_asset_row_data.dart';
import 'nyctis_assets_view_provider.dart';

/// Secure-storage key for the persisted records.
const String kNyctisInFlightSendsKey = 'nyctis_in_flight_sends_v1';

/// One payment the wallet broadcast, or started to.
@immutable
class NyctisInFlightSend {
  const NyctisInFlightSend({
    required this.msgId,
    required this.assetId,
    required this.accountUuid,
    required this.anchorHeight,
    required this.recordedAt,
    this.txid,
  });

  factory NyctisInFlightSend.fromPlan(
    NyctisSendReviewArgs plan, {
    DateTime? now,
  }) {
    return NyctisInFlightSend(
      msgId: plan.msgId,
      assetId: plan.assetId,
      accountUuid: plan.accountUuid,
      anchorHeight: plan.anchorHeight,
      recordedAt: now ?? DateTime.now(),
    );
  }

  static NyctisInFlightSend? fromJson(Object? json) {
    if (json is! Map) return null;
    final msgId = json['msgId'];
    final assetId = json['assetId'];
    final accountUuid = json['accountUuid'];
    final anchorHeight = json['anchorHeight'];
    final recordedAt = json['recordedAt'];
    if (msgId is! String ||
        assetId is! String ||
        accountUuid is! String ||
        anchorHeight is! int ||
        recordedAt is! String) {
      return null;
    }
    final txid = json['txid'];
    return NyctisInFlightSend(
      msgId: msgId,
      assetId: assetId,
      accountUuid: accountUuid,
      anchorHeight: anchorHeight,
      recordedAt: DateTime.tryParse(recordedAt) ?? DateTime.now(),
      txid: txid is String ? txid : null,
    );
  }

  final String msgId;
  final String assetId;
  final String accountUuid;

  /// The plan's anchor. The message can only be applied while the anchor is
  /// inside the channel's window, which is what lets a record expire.
  final int anchorHeight;

  final DateTime recordedAt;

  /// The carrying Zcash transaction, once the broadcast reported one.
  final String? txid;

  NyctisInFlightSend withTxid(String? value) => NyctisInFlightSend(
    msgId: msgId,
    assetId: assetId,
    accountUuid: accountUuid,
    anchorHeight: anchorHeight,
    recordedAt: recordedAt,
    txid: value ?? txid,
  );

  Map<String, Object?> toJson() => {
    'msgId': msgId,
    'assetId': assetId,
    'accountUuid': accountUuid,
    'anchorHeight': anchorHeight,
    'recordedAt': recordedAt.toIso8601String(),
    if (txid != null) 'txid': txid,
  };

  /// Whether [view] shows this message settled — applied, or past the point
  /// where it still could be.
  ///
  /// The anchor window used is the protocol's, never an indexer's claim: a
  /// shorter window reported by a server would release notes early.
  bool isSettledIn(NyctisViewData view) {
    for (final asset in view.assets) {
      for (final note in asset.notes) {
        if (note.spentBy == msgId || note.createdBy == msgId) return true;
      }
    }
    final canonical = view.viewHeight;
    if (canonical == null) return false;
    return canonical >=
        BigInt.from(anchorHeight + kNyctisDefaultAnchorWindow);
  }
}

/// Where the records are kept. Injectable so widget tests run without a
/// platform keychain.
abstract interface class NyctisInFlightSendStore {
  Future<List<NyctisInFlightSend>> read();

  Future<void> write(List<NyctisInFlightSend> sends);
}

/// The shipped store: encrypted, because a payment record says which asset
/// this wallet holds.
class SecureNyctisInFlightSendStore implements NyctisInFlightSendStore {
  const SecureNyctisInFlightSendStore();

  @override
  Future<List<NyctisInFlightSend>> read() async {
    final raw = await AppSecureStore.instance.readSecretStringWithOptions(
      kNyctisInFlightSendsKey,
      requireUnlockedSession: true,
    );
    return decodeNyctisInFlightSends(raw);
  }

  @override
  Future<void> write(List<NyctisInFlightSend> sends) async {
    if (sends.isEmpty) {
      await AppSecureStore.instance.delete(kNyctisInFlightSendsKey);
      return;
    }
    await AppSecureStore.instance.writeSecretString(
      kNyctisInFlightSendsKey,
      jsonEncode([for (final send in sends) send.toJson()]),
    );
  }
}

/// Parses the stored list, dropping anything malformed rather than failing:
/// a lost record re-opens a guard, a thrown one would close sending entirely.
List<NyctisInFlightSend> decodeNyctisInFlightSends(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [for (final entry in decoded) ?NyctisInFlightSend.fromJson(entry)];
  } catch (_) {
    return const [];
  }
}

/// A store that keeps records in memory only. Tests and Widgetbook use it.
class MemoryNyctisInFlightSendStore implements NyctisInFlightSendStore {
  MemoryNyctisInFlightSendStore([List<NyctisInFlightSend>? initial])
    : sends = [...?initial];

  List<NyctisInFlightSend> sends;

  @override
  Future<List<NyctisInFlightSend>> read() async => List.of(sends);

  @override
  Future<void> write(List<NyctisInFlightSend> value) async {
    sends = List.of(value);
  }
}

final nyctisInFlightSendStoreProvider = Provider<NyctisInFlightSendStore>(
  (ref) => const SecureNyctisInFlightSendStore(),
);

/// The records, restored from the store on first read and pruned whenever a
/// new view shows one settled.
class NyctisInFlightSendsNotifier
    extends Notifier<List<NyctisInFlightSend>> {
  bool _restored = false;

  @override
  List<NyctisInFlightSend> build() {
    ref.listen<AsyncValue<NyctisViewData>>(nyctisAssetsViewProvider, (
      _,
      next,
    ) {
      final view = next.value;
      if (view != null) pruneSettled(view);
    });
    if (!_restored) {
      _restored = true;
      Future.microtask(_restore);
    }
    return const [];
  }

  Future<void> _restore() async {
    List<NyctisInFlightSend> stored;
    try {
      stored = await ref.read(nyctisInFlightSendStoreProvider).read();
    } catch (_) {
      return;
    }
    if (!ref.mounted || stored.isEmpty) return;
    final known = {for (final send in state) send.msgId};
    state = [
      ...state,
      for (final send in stored)
        if (!known.contains(send.msgId)) send,
    ];
  }

  Future<void> _persist() async {
    try {
      await ref.read(nyctisInFlightSendStoreProvider).write(state);
    } catch (_) {
      // Locked, or no keychain. The in-memory guard still holds for this run.
    }
  }

  /// Records [plan] as broadcast (or about to be). Idempotent per `msg_id`.
  void record(NyctisSendReviewArgs plan) {
    if (isRecorded(plan.msgId)) return;
    state = [...state, NyctisInFlightSend.fromPlan(plan)];
    _persist();
  }

  /// Attaches the carrying txid once the broadcast reports one.
  void attachTxid(String msgId, String? txid) {
    if (txid == null) return;
    state = [
      for (final send in state)
        send.msgId == msgId ? send.withTxid(txid) : send,
    ];
    _persist();
  }

  /// Forgets [msgId]. Only for a broadcast that provably put nothing on the
  /// network — a proposal that was never executed.
  void release(String msgId) {
    if (!isRecorded(msgId)) return;
    state = [
      for (final send in state)
        if (send.msgId != msgId) send,
    ];
    _persist();
  }

  bool isRecorded(String msgId) => state.any((send) => send.msgId == msgId);

  /// Drops every record [view] shows settled.
  void pruneSettled(NyctisViewData view) {
    final remaining = [
      for (final send in state)
        if (!send.isSettledIn(view)) send,
    ];
    if (remaining.length == state.length) return;
    state = remaining;
    _persist();
  }
}

final nyctisInFlightSendsProvider =
    NotifierProvider<NyctisInFlightSendsNotifier, List<NyctisInFlightSend>>(
      NyctisInFlightSendsNotifier.new,
    );

/// The unsettled payment of [assetId] from [accountUuid], judged against the
/// current view, or null when there is none.
///
/// Judged here as well as pruned in the notifier, so a view that already shows
/// the message settled unblocks the screen in the same frame.
NyctisInFlightSend? nyctisPendingSendFor({
  required List<NyctisInFlightSend> sends,
  required String assetId,
  required String? accountUuid,
  NyctisViewData? view,
}) {
  for (final send in sends) {
    if (send.assetId != assetId) continue;
    if (accountUuid != null && send.accountUuid != accountUuid) continue;
    if (view != null && send.isSettledIn(view)) continue;
    return send;
  }
  return null;
}
