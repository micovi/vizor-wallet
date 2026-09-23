import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_bootstrap.dart';
import '../core/config/nyctis_config.dart';
import '../core/storage/app_secure_store.dart';

/// Nyctis settings, seeded from the startup snapshot and persisted with
/// `writePlain` so they stay readable while the wallet is locked.
class NyctisConfigNotifier extends Notifier<NyctisConfig> {
  static final _store = AppSecureStore.instance;

  @override
  NyctisConfig build() => ref.watch(appBootstrapProvider).nyctisConfig;

  bool get isCustomIndexer =>
      state.indexerUrl != defaultNyctisIndexerUrl(state.networkName);

  bool get isCustomChannel =>
      state.channel != defaultNyctisChannel(state.networkName);

  /// Turns the feature on or off. Enabling an unconfigured network is refused
  /// rather than stored, so `enabled` never disagrees with `isConfigured`.
  Future<void> setEnabled(bool enabled) async {
    if (enabled && !state.isConfigured) {
      throw FormatException(
        state.unconfiguredReason ?? 'Nyctis is not configured yet.',
      );
    }
    await _store.writePlain(kNyctisEnabledKey, enabled ? 'true' : 'false');
    state = state.copyWith(enabled: enabled);
  }

  /// Stores a custom indexer origin. Throws a [FormatException] with a
  /// user-facing `.message` when the input is not a usable URL.
  Future<void> setIndexerUrl(String input) async {
    final normalized = normalizeNyctisIndexerUrl(input);
    await _store.writePlain(kNyctisIndexerUrlKey, normalized);
    state = state.copyWith(indexerUrl: normalized);
  }

  Future<void> resetIndexerUrlToDefault() async {
    await _store.delete(kNyctisIndexerUrlKey);
    state = state.copyWith(
      indexerUrl: defaultNyctisIndexerUrl(state.networkName),
    );
  }

  /// Points the wallet at a different channel. Both halves move together: a
  /// UIVK from one channel with an address from another reads one and writes
  /// to the other.
  Future<void> setChannel({
    required String uivk,
    required String address,
    required int birthday,
  }) async {
    final trimmedUivk = uivk.trim();
    final trimmedAddress = address.trim();
    if (trimmedUivk.isEmpty) {
      throw const FormatException('Enter a channel viewing key.');
    }
    if (trimmedAddress.isEmpty) {
      throw const FormatException('Enter a channel address.');
    }
    if (birthday < 0) {
      throw const FormatException('Enter a channel birthday height.');
    }

    await _store.writePlain(kNyctisChannelUivkKey, trimmedUivk);
    await _store.writePlain(kNyctisChannelAddressKey, trimmedAddress);
    await _store.writePlain(kNyctisBirthdayKey, '$birthday');
    state = state.withChannel(
      NyctisChannel(
        uivk: trimmedUivk,
        address: trimmedAddress,
        birthday: birthday,
      ),
    );
  }

  /// Pins the verifying key this channel's proofs are checked against, by its
  /// `BLAKE2b-256` hash. Throws a [FormatException] with a user-facing
  /// `.message` when the input is not 64 hex characters.
  Future<void> setVkPin(String input) async {
    final normalized = normalizeNyctisVkPin(input);
    await _store.writePlain(kNyctisVkPinKey, normalized);
    state = state.copyWith(vkPin: normalized);
  }

  /// Points the wallet at a folder holding the Nyctis proving key.
  ///
  /// Only the path is stored — the folder is validated by
  /// `nyctisCheckProvingKey`, which is the only thing that can say whether
  /// it holds a usable key and whether that key is the one this channel's
  /// verifiers accept. Storing the path regardless is deliberate: a user who
  /// typed the right path for a drive that is not mounted yet should get it
  /// back on the next launch, not have it silently dropped.
  ///
  /// An empty input clears the setting. Throws a [FormatException] with a
  /// user-facing `.message` for a path that is not absolute.
  Future<void> setProvingKeyDir(String input) async {
    final normalized = normalizeNyctisProvingKeyDir(input);
    if (normalized.isEmpty) {
      await clearProvingKeyDir();
      return;
    }
    await _store.writePlain(kNyctisProvingKeyDirKey, normalized);
    state = state.copyWith(provingKeyDir: normalized);
  }

  /// Forgets the proving-key folder. Sending goes back to being unavailable,
  /// which is the default state and not a fault.
  Future<void> clearProvingKeyDir() async {
    await _store.delete(kNyctisProvingKeyDirKey);
    state = state.copyWith(provingKeyDir: '');
  }

  /// Drops every stored override, including the enabled flag: a wallet that
  /// resets the channel must not keep fetching the old one.
  Future<void> resetToDefault() async {
    await _store.delete(kNyctisIndexerUrlKey);
    await _store.delete(kNyctisChannelUivkKey);
    await _store.delete(kNyctisChannelAddressKey);
    await _store.delete(kNyctisBirthdayKey);
    await _store.delete(kNyctisEnabledKey);
    await _store.delete(kNyctisProvingKeyDirKey);
    await _store.delete(kNyctisVkPinKey);
    state = defaultNyctisConfig(state.networkName);
  }
}

final nyctisConfigProvider =
    NotifierProvider<NyctisConfigNotifier, NyctisConfig>(
      NyctisConfigNotifier.new,
    );

/// Whether this build ships the Nyctis feature at all
/// ([kNyctisFeatureAvailable], from `VIZOR_NYCTIS_ENABLED`).
///
/// A provider only so widget tests can override it; the value never changes
/// at runtime. Every Nyctis entry point in shared UI (sidebar, settings
/// rows) and every provider that feeds the shared activity lists checks this
/// first.
final nyctisFeatureEnabledProvider = Provider<bool>(
  (_) => kNyctisFeatureAvailable,
);
