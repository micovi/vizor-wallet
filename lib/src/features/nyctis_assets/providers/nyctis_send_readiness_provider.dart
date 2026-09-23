/// Whether this wallet can start a Nyctis payment of one asset right now,
/// and if not, the one reason to show.
///
/// Every reason here is known before a proof is started, so none of them may
/// wait until after Review: a hardware account, a missing or wrong proving
/// key, a payment of the same asset still settling, and too little ZEC to
/// carry even the smallest message. The asset detail screen and the composer
/// both read this, so Send is disabled — with the reason beside it — in the
/// same places for the same causes.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/account_provider.dart';
import '../../../providers/nyctis_config_provider.dart';
import '../../../providers/sync_provider.dart';
import '../services/nyctis_send_flow.dart';
import '../widgets/nyctis_asset_row_data.dart';
import 'nyctis_assets_view_provider.dart';
import 'nyctis_in_flight_send_provider.dart';
import 'nyctis_proving_key_provider.dart';

/// Which kind of blocker a [NyctisSendBlock] is. Decides the action offered
/// beside it: only a proving-key problem is fixed in Nyctis settings.
enum NyctisSendBlockKind { hardwareAccount, provingKey, inFlight, zec }

@immutable
class NyctisSendBlock {
  const NyctisSendBlock({required this.kind, required this.text});

  final NyctisSendBlockKind kind;

  /// Sentence-case, already fit to show.
  final String text;

  /// Whether the fix lives in Nyctis settings.
  bool get opensSettings => kind == NyctisSendBlockKind.provingKey;
}

/// Shown while a payment of this asset is broadcast and not yet final.
String nyctisSendInFlightText({
  required String assetLabel,
  required String finalityEstimate,
}) =>
    'Your last payment of $assetLabel is not final yet. You can send '
    '$assetLabel again once it is, $finalityEstimate. A new payment now could '
    'pick the same notes, and the channel would reject it after its ZEC was '
    'spent.';

/// The reason [assetId] cannot be sent now, or null when it can.
final nyctisSendBlockProvider = Provider.family<NyctisSendBlock?, String>((
  ref,
  assetId,
) {
  String? activeUuid;
  var hardware = false;
  try {
    final accounts = ref.watch(accountProvider).value;
    activeUuid = accounts?.activeAccountUuid;
    hardware = accounts?.activeAccount?.isHardware ?? false;
  } catch (_) {
    // No account state (a bare widget test, a locked bootstrap): nothing
    // here can be said about the account, so say nothing.
  }
  if (hardware) {
    return const NyctisSendBlock(
      kind: NyctisSendBlockKind.hardwareAccount,
      text: kNyctisHardwareAccountText,
    );
  }

  final keyReason = nyctisSendUnavailableReason(
    ref.watch(nyctisProvingKeyProvider),
  );
  if (keyReason != null) {
    return NyctisSendBlock(
      kind: NyctisSendBlockKind.provingKey,
      text: keyReason,
    );
  }

  final view = ref.watch(nyctisAssetsViewProvider).value;
  final pending = nyctisPendingSendFor(
    sends: ref.watch(nyctisInFlightSendsProvider),
    assetId: assetId,
    accountUuid: activeUuid,
    view: view,
  );
  if (pending != null) {
    final asset = view?.assetById(assetId);
    String networkName;
    try {
      networkName = ref.watch(
        nyctisConfigProvider.select((config) => config.networkName),
      );
    } catch (_) {
      networkName = 'main';
    }
    return NyctisSendBlock(
      kind: NyctisSendBlockKind.inFlight,
      text: nyctisSendInFlightText(
        assetLabel: _assetLabel(asset, assetId),
        finalityEstimate: nyctisFinalityEstimateText(
          networkName,
          view?.finalityDepth ?? kNyctisDefaultFinalityDepth,
        ),
      ),
    );
  }

  final sync = ref.watch(syncProvider).value;
  if (sync != null && sync.hasBalanceData) {
    final shortfall = nyctisZecShortfallText(sync.spendableBalance);
    if (shortfall != null) {
      return NyctisSendBlock(
        kind: NyctisSendBlockKind.zec,
        text: shortfall,
      );
    }
  }
  return null;
});

String _assetLabel(NyctisAssetDetailData? asset, String assetId) {
  final symbol = asset?.symbol?.trim() ?? '';
  if (symbol.isNotEmpty) return symbol;
  final name = asset?.name?.trim() ?? '';
  if (name.isNotEmpty) return name;
  return 'this asset';
}
