import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_bootstrap.dart';
import '../core/config/nightjar_config.dart';
import '../core/storage/app_secure_store.dart';

/// Nightjar settings, seeded from the startup snapshot and persisted with
/// `writePlain` so they stay readable while the wallet is locked.
class NightjarConfigNotifier extends Notifier<NightjarConfig> {
  static final _store = AppSecureStore.instance;

  @override
  NightjarConfig build() => ref.watch(appBootstrapProvider).nightjarConfig;

  bool get isCustomIndexer =>
      state.indexerUrl != defaultNightjarIndexerUrl(state.networkName);

  bool get isCustomChannel =>
      state.channel != defaultNightjarChannel(state.networkName);

  /// Turns the feature on or off. Enabling an unconfigured network is refused
  /// rather than stored, so `enabled` never disagrees with `isConfigured`.
  Future<void> setEnabled(bool enabled) async {
    if (enabled && !state.isConfigured) {
      throw FormatException(
        state.unconfiguredReason ?? 'Nightjar is not configured yet.',
      );
    }
    await _store.writePlain(kNightjarEnabledKey, enabled ? 'true' : 'false');
    state = state.copyWith(enabled: enabled);
  }

  /// Stores a custom indexer origin. Throws a [FormatException] with a
  /// user-facing `.message` when the input is not a usable URL.
  Future<void> setIndexerUrl(String input) async {
    final normalized = normalizeNightjarIndexerUrl(input);
    await _store.writePlain(kNightjarIndexerUrlKey, normalized);
    state = state.copyWith(indexerUrl: normalized);
  }

  Future<void> resetIndexerUrlToDefault() async {
    await _store.delete(kNightjarIndexerUrlKey);
    state = state.copyWith(
      indexerUrl: defaultNightjarIndexerUrl(state.networkName),
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

    await _store.writePlain(kNightjarChannelUivkKey, trimmedUivk);
    await _store.writePlain(kNightjarChannelAddressKey, trimmedAddress);
    await _store.writePlain(kNightjarBirthdayKey, '$birthday');
    state = state.withChannel(
      NightjarChannel(
        uivk: trimmedUivk,
        address: trimmedAddress,
        birthday: birthday,
      ),
    );
  }

  /// Points the wallet at a folder holding the Nightjar proving key.
  ///
  /// Only the path is stored — the folder is validated by
  /// `nightjarCheckProvingKey`, which is the only thing that can say whether
  /// it holds a usable key and whether that key is the one this channel's
  /// verifiers accept. Storing the path regardless is deliberate: a user who
  /// typed the right path for a drive that is not mounted yet should get it
  /// back on the next launch, not have it silently dropped.
  ///
  /// An empty input clears the setting. Throws a [FormatException] with a
  /// user-facing `.message` for a path that is not absolute.
  Future<void> setProvingKeyDir(String input) async {
    final normalized = normalizeNightjarProvingKeyDir(input);
    if (normalized.isEmpty) {
      await clearProvingKeyDir();
      return;
    }
    await _store.writePlain(kNightjarProvingKeyDirKey, normalized);
    state = state.copyWith(provingKeyDir: normalized);
  }

  /// Forgets the proving-key folder. Sending goes back to being unavailable,
  /// which is the default state and not a fault.
  Future<void> clearProvingKeyDir() async {
    await _store.delete(kNightjarProvingKeyDirKey);
    state = state.copyWith(provingKeyDir: '');
  }

  /// Drops every stored override, including the enabled flag: a wallet that
  /// resets the channel must not keep fetching the old one.
  Future<void> resetToDefault() async {
    await _store.delete(kNightjarIndexerUrlKey);
    await _store.delete(kNightjarChannelUivkKey);
    await _store.delete(kNightjarChannelAddressKey);
    await _store.delete(kNightjarBirthdayKey);
    await _store.delete(kNightjarEnabledKey);
    await _store.delete(kNightjarProvingKeyDirKey);
    state = defaultNightjarConfig(state.networkName);
  }
}

final nightjarConfigProvider =
    NotifierProvider<NightjarConfigNotifier, NightjarConfig>(
      NightjarConfigNotifier.new,
    );
