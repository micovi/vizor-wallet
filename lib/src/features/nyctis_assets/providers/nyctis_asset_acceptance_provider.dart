/// Which assets the user has accepted issuer metadata for.
///
/// This is the gate the whole feature hangs on. `spec/asset-metadata-v0.md`
/// section 5: a wallet **MUST NOT** display a logo for an asset the user has
/// not explicitly accepted, and acceptance is **per `asset_id`**, never per
/// name, symbol or issuer. Section 3.1 adds the other half — acceptance is
/// also the only thing that may trigger a network request, because holding a
/// note is the fact the system exists to hide.
///
/// So there is deliberately no "accept all", no "accept this issuer", and no
/// auto-accept for an asset the wallet already holds. Every one of those would
/// be a shorter path to the same picture in front of the same user.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/storage/app_secure_store.dart';
import '../models/nyctis_asset_acceptance.dart';
import 'nyctis_metadata_fetcher_provider.dart';

/// Where the accepted set is persisted. Injectable so a widget test can tap
/// Accept without a platform keychain behind it.
abstract interface class NyctisAcceptanceStore {
  Future<void> write(String encoded);

  Future<void> clear();
}

/// The shipped store: the same plain (locked-readable) secure-storage key the
/// rest of the Nyctis settings use, so the assets screen can render its
/// acceptance state before the wallet is unlocked.
///
/// **Readable while locked, deliberately, and on the wallet's own terms.** The
/// accepted set is close to the held set, so it is not nothing. But this app
/// encrypts only secrets under the session key (mnemonics, the voting hotkey,
/// gift-card seeds, through `writeSecretString`) and keeps its non-secret
/// state in plain keychain entries: the account list, each account's swap
/// activity history, the selected pay asset. The wallet database beside them,
/// which records every transaction the wallet has made, is not encrypted at
/// rest at all. Anyone who can read this key while the app is locked can
/// already read a far more exact record of what the wallet holds, so moving
/// this one entry behind the session key would add a lock-state edge case
/// (the acceptance gate reading as empty until unlock) without closing
/// anything. It stays with the rest, and `deleteAll` still clears it on reset.
class SecureNyctisAcceptanceStore implements NyctisAcceptanceStore {
  const SecureNyctisAcceptanceStore();

  @override
  Future<void> write(String encoded) =>
      AppSecureStore.instance.writePlain(kNyctisAcceptedAssetsKey, encoded);

  @override
  Future<void> clear() =>
      AppSecureStore.instance.delete(kNyctisAcceptedAssetsKey);
}

final nyctisAcceptanceStoreProvider = Provider<NyctisAcceptanceStore>(
  (ref) => const SecureNyctisAcceptanceStore(),
);

class NyctisAssetAcceptanceNotifier extends Notifier<NyctisAssetAcceptance> {
  @override
  NyctisAssetAcceptance build() {
    try {
      return ref.watch(appBootstrapProvider).nyctisAcceptedAssets;
    } catch (_) {
      // A wallet whose bootstrap did not run has accepted nothing. Empty is
      // the direction that shows less, which is the only safe direction for a
      // value that decides whether an issuer's picture is drawn.
      return const NyctisAssetAcceptance.empty();
    }
  }

  bool isAccepted(String assetId) => state.isAccepted(assetId);

  /// What the user must be told *before* they accept (section 5).
  ///
  /// Nothing in Nyctis makes a name unique: `Assets` is keyed by `asset_id`
  /// and naming is first-wins per asset, so any issuer may create an asset
  /// called `NYCTIS` with symbol `Ny` and point its `uri` at a copy of
  /// another asset's document, logo included. That is section 1.1's expected
  /// case, not an attack to be blocked — the wallet's job is to say so at the
  /// moment the decision is made.
  List<NyctisNameCollision> collisionsFor({
    required String assetId,
    String? name,
    String? symbol,
  }) => state.collisionsWith(assetId: assetId, name: name, symbol: symbol);

  /// Records acceptance of one `asset_id`.
  ///
  /// [name] and [symbol] are the **signed** values from the `ASSET` message,
  /// not anything a document said. They are stored so a later acceptance can
  /// still be warned about colliding with this one.
  Future<void> accept({
    required String assetId,
    String? name,
    String? symbol,
  }) async {
    final next = state.accepting(
      NyctisAcceptedAsset(assetId: assetId, name: name, symbol: symbol),
    );
    // Written before the state moves. A failed write with the state already
    // advanced would show a logo this launch that the next launch has no
    // record of accepting — the one disagreement between the stored and the
    // live value that renders more than the user agreed to.
    await ref.read(nyctisAcceptanceStoreProvider).write(next.encode());
    state = next;
  }

  /// Records acceptance of several `asset_id`s at once.
  ///
  /// The whole of this method's reason to exist is the collection case, and
  /// the two things it does *not* do are the point.
  ///
  /// It does not invent a coarser unit of acceptance: there is still one
  /// [NyctisAcceptedAsset] per `asset_id` in the stored set, revocable on
  /// its own, and an asset not in [entries] is not accepted by anything here.
  /// Section 5 of `spec/asset-metadata-v0.md` makes acceptance per `asset_id`
  /// and never per issuer, and a "collection" record would be an issuer record
  /// wearing a different name.
  ///
  /// It also does not write a hundred times. The store is the platform
  /// keychain; a loop calling [accept] for a hundred-piece collection is a
  /// hundred round trips with a hundred chances to leave the set half written.
  /// One encode, one write, then one state move.
  Future<void> acceptMany(Iterable<NyctisAcceptedAsset> entries) async {
    var next = state;
    var changed = false;
    for (final entry in entries) {
      if (state.entryFor(entry.assetId) == entry) continue;
      next = next.accepting(entry);
      changed = true;
    }
    if (!changed) return;
    // Written before the state moves, for the same reason [accept] does it in
    // that order: the failure that shows more than the user agreed to is the
    // one worth making impossible.
    await ref.read(nyctisAcceptanceStoreProvider).write(next.encode());
    state = next;
  }

  /// Withdraws acceptance of several `asset_id`s at once, with the same single
  /// write and the same cache drop per asset as [revoke].
  Future<void> revokeMany(Iterable<String> assetIds) async {
    final ids = assetIds.where(state.isAccepted).toList();
    if (ids.isEmpty) return;
    var next = state;
    for (final assetId in ids) {
      next = next.without(assetId);
    }
    final store = ref.read(nyctisAcceptanceStoreProvider);
    if (next.accepted.isEmpty) {
      await store.clear();
    } else {
      await store.write(next.encode());
    }
    final fetcher = ref.read(nyctisMetadataFetcherProvider);
    for (final assetId in ids) {
      fetcher.forget(assetId);
    }
    state = next;
  }

  /// Withdraws acceptance. The logo stops being drawn and the cached document
  /// is dropped by whoever holds it.
  Future<void> revoke(String assetId) async {
    final next = state.without(assetId);
    final store = ref.read(nyctisAcceptanceStoreProvider);
    if (next.accepted.isEmpty) {
      await store.clear();
    } else {
      await store.write(next.encode());
    }
    // The wallet stops drawing the logo, so it stops holding the bytes too.
    // Leaving them cached would mean re-accepting redraws a picture without a
    // fetch, which quietly makes acceptance reversible in one direction only.
    ref.read(nyctisMetadataFetcherProvider).forget(assetId);
    state = next;
  }
}

final nyctisAssetAcceptanceProvider =
    NotifierProvider<NyctisAssetAcceptanceNotifier, NyctisAssetAcceptance>(
      NyctisAssetAcceptanceNotifier.new,
    );
