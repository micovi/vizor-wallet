/// Whether this wallet can send Nightjar assets, and if not, why not.
///
/// Reading a channel needs the 1.8 KiB verifying key, which the indexer
/// serves. *Making* a proof needs the ~83 MiB proving key, which nothing
/// serves and nothing should — so the PoC takes a folder path in settings and
/// this provider is what turns that path into an answer.
///
/// It watches the assets view for one value: `NjView.vk_hash`, the hash of the
/// key the replay actually checked this channel's proofs against. A key set
/// from another ceremony shares the same circuit fingerprint and produces
/// proofs every verifier on the channel rejects, and that hash is the only
/// thing that tells the two apart before a user has paid a Zcash fee to carry
/// one. When no view is available the comparison is skipped and the result
/// says so rather than implying a check it did not make — `nightjarBuildPay`
/// makes the same comparison itself before it loads the key.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/nightjar_config_provider.dart';
import '../services/nightjar_send_flow.dart';
import 'nightjar_assets_view_provider.dart';

/// The proving-key verdict for the configured folder.
///
/// Cheap: Rust reads the small verifying key and the one-line manifest and
/// only `stat`s the 83 MiB proving key, so this can run whenever a screen
/// that offers to send is opened.
final nightjarProvingKeyProvider = FutureProvider<NightjarProvingKeyStatus>((
  ref,
) async {
  final String keysDir;
  try {
    keysDir = ref.watch(
      nightjarConfigProvider.select((config) => config.provingKeyDir),
    );
  } catch (_) {
    // A configuration this wallet cannot read is "no key set", never a key
    // fault. Bootstrap can legitimately fail to produce one.
    return const NightjarProvingKeyStatus(
      state: NightjarProvingKeyState.notSet,
      message: kNightjarProvingKeyNotSetText,
    );
  }

  String? channelVkHash;
  try {
    channelVkHash = (await ref.watch(nightjarAssetsViewProvider.future)).vkHash;
  } catch (_) {
    // No view, so no hash to compare against. That is a weaker check, not a
    // failed one, and [NightjarProvingKeyStatus.isUnverifiedAgainstChannel]
    // is how the screen says which of the two it is looking at.
    channelVkHash = null;
  }

  return checkNightjarProvingKey(
    keysDir: keysDir,
    channelVkHash: channelVkHash,
  );
});

/// The reason sending is unavailable, or null when it is available.
///
/// Also null while the check is still running, which is deliberate: the check
/// is a `stat` and a 1.8 KiB read, so announcing a missing key the wallet has
/// not finished looking for would flash a warning on almost every open. The
/// cost of being wrong for that moment is one navigation — the composer makes
/// the same check and refuses there, and `nightjarBuildPay` makes it a third
/// time before it loads the key.
String? nightjarSendUnavailableReason(
  AsyncValue<NightjarProvingKeyStatus> status,
) {
  final value = status.value;
  if (value == null) return null;
  if (value.canSend) return null;
  return value.message ?? kNightjarProvingKeyNotSetText;
}
