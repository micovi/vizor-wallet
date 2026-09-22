/// The Nightjar send pipeline: proving-key gate, plan build, and the
/// broadcast leg that carries a plan's memos onto the chain.
///
/// Mirrors `features/send/services/send_flow.dart` in shape — plain functions
/// plus a `…With` variant that takes every read as a callback, so the whole
/// pipeline is testable without Riverpod, secure storage or the native
/// library. Four protocol facts are encoded here because no screen is allowed
/// to paper over them:
///
/// * **Every memo of one payment rides one transaction.** A reader
///   reassembles a message only from fragments sharing a txid, so
///   [runNightjarSendBroadcastWith] makes exactly one `proposeSendRaw` call
///   with one `RawSendOutput` per memo. Splitting them produces fragments
///   nobody can reassemble and ZEC spent for nothing.
/// * **The ZEC cost is real and it is paid to the channel.** Each memo is an
///   ordinary shielded output to the *channel's* Zcash address carrying
///   [NightjarSendReviewArgs.memoValueZatoshi]; the recipient of the asset
///   receives no ZEC at all. [NightjarSendReviewArgs.channelZatoshi] is that
///   total, and the review screen states it.
/// * **Plans expire.** The proof is anchored at the tree root of `tip − 10`,
///   and that anchor ages out of the channel's anchor window.
///   [nightjarPlanFreshness] is the arithmetic; a stale plan is ignored with
///   "unknown anchor" *after* the ZEC has been spent, so the review screen
///   refuses to send one.
/// * **The proving key is checked in settings, not at send time.** ~83 MiB,
///   served by nothing, and a key from another ceremony shares the same
///   circuit fingerprint while producing proofs every verifier rejects.
///   [checkNightjarProvingKey] compares the folder's `vk_hash` with the one
///   the replay actually verified against.
///
/// Amounts are integer base units throughout. `assetDecimals` is a display
/// hint applied by `formatNightjarAmount` and by nothing here.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../main.dart' show log;
import '../../../core/config/nightjar_config.dart';
import '../../../core/config/rpc_endpoint_config.dart';
import '../../../core/storage/wallet_paths.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/nightjar_config_provider.dart';
import '../../../providers/rpc_endpoint_failover_provider.dart';
import '../../../providers/rpc_endpoint_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../../rust/api/nightjar.dart' as rust_nightjar;
import '../../../rust/api/sync.dart' as rust_sync;
import '../../send/services/send_flow.dart'
    show discardSendProposal, newSendFlowId;
import '../models/nightjar_indexer_status.dart';
import '../models/nightjar_message.dart';
import '../models/nightjar_verifying_key.dart';
import '../widgets/nightjar_asset_row_mapper.dart';
import 'nightjar_indexer_client.dart';
// [NightjarSeedReader] is the read path's callback and is reused verbatim:
// the caller controls *when* the seed is in memory, so it can be read after
// the network I/O, handed to the FFI call, and zeroed in a `finally` before
// the result is awaited.
import 'nightjar_view_loader.dart' show NightjarSeedReader;

// ---------------------------------------------------------------------------
// The two Rust calls, behind seams
// ---------------------------------------------------------------------------

/// The pay-side Rust calls this file makes.
///
/// [buildPay] returns the FFI future *without* awaiting it, so a caller can
/// zero the seed between issuing the call and collecting its result. A test
/// subclasses this to drive the flow without the native library.
/// Nowhere to look, for the tests and fixtures that drive this flow against a
/// channel with no ZEC claim on it. Safe as a default because it refuses
/// claims rather than assuming them.
const _noPayZecSources = rust_nightjar.NjZecSources(
  dbPath: '',
  lightwalletdUrl: '',
);

class NightjarPayBridge {
  const NightjarPayBridge();

  Future<rust_nightjar.NjProvingKey> checkProvingKey({
    required String keysDir,
  }) => rust_nightjar.nightjarCheckProvingKey(keysDir: keysDir);

  Future<rust_nightjar.NjPayPlan> buildPay({
    required String network,
    required String channelUivk,
    required int birthday,
    required int chainTip,
    required Uint8List vk,
    required List<rust_nightjar.NjMessageInput> messages,
    required Uint8List seed,
    required String keysDir,
    required String assetId,
    required BigInt amount,
    required String recipient,
    required rust_nightjar.NjZecSources zecSources,
  }) => rust_nightjar.nightjarBuildPay(
    network: network,
    channelUivk: channelUivk,
    birthday: birthday,
    chainTip: chainTip,
    vk: vk,
    messages: messages,
    seed: seed,
    keysDir: keysDir,
    assetId: assetId,
    amount: amount,
    recipient: recipient,
    zecSources: zecSources,
  );
}

/// The transport calls: this wallet's own proposal and broadcast path.
///
/// [executeProposal] returns the FFI future without awaiting it, for the same
/// seed-zeroing reason as [NightjarPayBridge.buildPay].
class NightjarSendBridge {
  const NightjarSendBridge();

  Future<rust_sync.ProposalResult> proposeSendRaw({
    required String dbPath,
    required String network,
    required String accountUuid,
    required String sendFlowId,
    required List<rust_sync.RawSendOutput> outputs,
  }) => rust_sync.proposeSendRaw(
    dbPath: dbPath,
    network: network,
    accountUuid: accountUuid,
    sendFlowId: sendFlowId,
    outputs: outputs,
  );

  Future<rust_sync.ExecuteProposalResult> executeProposal({
    required String dbPath,
    required String lightwalletdUrl,
    required BigInt proposalId,
    required String sendFlowId,
    required Uint8List mnemonicBytes,
  }) => rust_sync.executeProposal(
    dbPath: dbPath,
    lightwalletdUrl: lightwalletdUrl,
    proposalId: proposalId,
    sendFlowId: sendFlowId,
    mnemonicBytes: mnemonicBytes,
  );
}

/// Every error Rust returns on this path is already a sentence written to be
/// shown verbatim, and `Result<_, String>` reaches Dart as a bare `String`.
/// Rewriting one here would replace "the keys in /x belong to a different key
/// set than this channel verifies with" with "Send failed. Try again."
String nightjarErrorText(Object error) {
  if (error is String) return error;
  final text = error.toString();
  const prefix = 'Exception: ';
  return text.startsWith(prefix) ? text.substring(prefix.length) : text;
}

// ---------------------------------------------------------------------------
// The proving-key gate
// ---------------------------------------------------------------------------

/// Why sending is or is not available.
enum NightjarProvingKeyState {
  /// No folder has been named. The default, and not a fault: a wallet that
  /// only reads never needs the key.
  notSet,

  /// A folder was named and `nightjarCheckProvingKey` refused it — missing,
  /// incomplete, or built for another circuit.
  unreadable,

  /// The folder holds a usable key set from a *different ceremony* than the
  /// one this channel verifies with. Proofs made with it are well-formed and
  /// every verifier on the channel rejects them.
  wrongKeySet,

  /// Checked, and it matches the key the replay verified this channel with.
  ready,
}

/// What a settings screen — and the send entry point — knows about the
/// configured proving-key folder.
@immutable
class NightjarProvingKeyStatus {
  const NightjarProvingKeyStatus({
    required this.state,
    this.dir = '',
    this.circuit,
    this.vkHash,
    this.channelVkHash,
    this.provingKeyBytes,
    this.message,
  });

  final NightjarProvingKeyState state;

  /// The folder as resolved, or `''` when none is set.
  final String dir;

  /// Circuit fingerprint, e.g. `constraints=136119;instances=30`. A
  /// diagnostic: it says which circuit shape the keys were made for, not
  /// whose ceremony made them — which is why [vkHash] exists.
  final String? circuit;

  /// `BLAKE2b-256` of the verifying key beside the proving key.
  final String? vkHash;

  /// The hash the replay verified this channel's proofs against, when a view
  /// was available to compare with.
  final String? channelVkHash;

  /// Size of `interpreter-v0.pk` on disk.
  final BigInt? provingKeyBytes;

  /// Sentence-case explanation for every state but [NightjarProvingKeyState
  /// .ready]. Rust's own wording where Rust produced it.
  final String? message;

  /// Whether a payment can be built at all.
  bool get canSend => state == NightjarProvingKeyState.ready;

  /// True when the folder was read but its key set could not be compared with
  /// the channel's, because no replay had produced a hash to compare against.
  ///
  /// Sending is still offered: `nightjarBuildPay` makes the same comparison
  /// itself before it loads the key, so the worst case is a refusal one screen
  /// later rather than a proof nobody accepts. The settings screen says so
  /// instead of implying a check it did not make.
  bool get isUnverifiedAgainstChannel =>
      state == NightjarProvingKeyState.ready && channelVkHash == null;
}

/// Shown wherever sending is offered and no proving-key folder is set.
const String kNightjarProvingKeyNotSetText =
    'Sending needs the Nightjar proving key, which this wallet does not have '
    'yet. Point Nightjar settings at the folder holding the interpreter '
    'proving key.';

/// Shown when the folder holds a usable key set that is not this channel's.
String nightjarProvingKeyWrongSetText({
  required String dir,
  required String keyVkHash,
  required String channelVkHash,
}) =>
    'The proving keys in $dir belong to a different key set than this channel '
    'verifies with (keys $keyVkHash, channel $channelVkHash). A payment '
    'proved with them would be rejected by every verifier on the channel.';

/// Validates a proving-key folder and compares it with the channel's key.
///
/// [channelVkHash] is `NjView.vk_hash` — what the replay actually checked
/// every proof against. Null means no replay has produced one yet, and the
/// result says so rather than reporting a comparison it did not make.
///
/// Cheap enough to run whenever a settings screen opens: Rust reads the
/// 1.8 KiB verifying key and the one-line manifest and only `stat`s the
/// 83 MiB proving key.
Future<NightjarProvingKeyStatus> checkNightjarProvingKey({
  required String keysDir,
  String? channelVkHash,
  NightjarPayBridge bridge = const NightjarPayBridge(),
}) async {
  final dir = keysDir.trim();
  if (dir.isEmpty) {
    return const NightjarProvingKeyStatus(
      state: NightjarProvingKeyState.notSet,
      message: kNightjarProvingKeyNotSetText,
    );
  }

  final rust_nightjar.NjProvingKey info;
  try {
    info = await bridge.checkProvingKey(keysDir: dir);
  } catch (error) {
    return NightjarProvingKeyStatus(
      state: NightjarProvingKeyState.unreadable,
      dir: dir,
      // Rust names the folder, the missing file and the remedy. A generic
      // "couldn't read that folder" would throw all three away.
      message: nightjarErrorText(error),
    );
  }

  final channel = channelVkHash?.trim();
  if (channel != null &&
      channel.isNotEmpty &&
      channel.toLowerCase() != info.vkHash.toLowerCase()) {
    return NightjarProvingKeyStatus(
      state: NightjarProvingKeyState.wrongKeySet,
      dir: info.dir,
      circuit: info.circuit,
      vkHash: info.vkHash,
      channelVkHash: channel,
      provingKeyBytes: info.provingKeyBytes,
      message: nightjarProvingKeyWrongSetText(
        dir: info.dir,
        keyVkHash: info.vkHash,
        channelVkHash: channel,
      ),
    );
  }

  return NightjarProvingKeyStatus(
    state: NightjarProvingKeyState.ready,
    dir: info.dir,
    circuit: info.circuit,
    vkHash: info.vkHash,
    channelVkHash: (channel == null || channel.isEmpty) ? null : channel,
    provingKeyBytes: info.provingKeyBytes,
  );
}

// ---------------------------------------------------------------------------
// Plan freshness
// ---------------------------------------------------------------------------

/// The anchor window a channel keeps when its `/api/status` does not say.
///
/// The devnet publishes `info.anchor_window`, and that value is preferred
/// wherever it is in hand; this is the fallback so the arithmetic is never
/// simply skipped.
const int kNightjarDefaultAnchorWindow = 200;

/// Blocks of headroom below which a plan is called aging.
///
/// Not a protocol number — the protocol has one threshold, the window — but a
/// plan a user is still reading through has to start warning before it is
/// already worthless.
const int kNightjarAnchorWarningHeadroom = 40;

/// How much life a built plan has left.
enum NightjarPlanFreshness {
  /// Comfortably inside the anchor window.
  fresh,

  /// Inside the window, but close enough to it that the user should send now
  /// or rebuild.
  aging,

  /// The anchor has aged out. The channel would ignore this payment with
  /// "unknown anchor" — after the ZEC carrying it had been spent.
  expired,
}

/// How old [anchorHeight] is at [chainTip], in blocks. Never negative: a tip
/// below the anchor means the wallet has not synced past the plan yet, which
/// is not age.
int nightjarPlanAnchorAge({required int anchorHeight, required int chainTip}) {
  final age = chainTip - anchorHeight;
  return age < 0 ? 0 : age;
}

/// [NightjarPlanFreshness] for a plan anchored at [anchorHeight], judged
/// against [chainTip].
///
/// A [chainTip] of zero — a wallet that has not synced one — comes back
/// [NightjarPlanFreshness.fresh], because "this wallet cannot tell" is not
/// "this plan is good". That distinction belongs to the copy, which is why
/// [nightjarPlanFreshnessText] takes the tip too.
NightjarPlanFreshness nightjarPlanFreshness({
  required int anchorHeight,
  required int chainTip,
  int anchorWindow = kNightjarDefaultAnchorWindow,
}) {
  if (chainTip <= 0) return NightjarPlanFreshness.fresh;
  final window = anchorWindow > 0 ? anchorWindow : kNightjarDefaultAnchorWindow;
  final age = nightjarPlanAnchorAge(
    anchorHeight: anchorHeight,
    chainTip: chainTip,
  );
  if (age >= window) return NightjarPlanFreshness.expired;
  if (window - age <= kNightjarAnchorWarningHeadroom) {
    return NightjarPlanFreshness.aging;
  }
  return NightjarPlanFreshness.fresh;
}

/// What a review screen owes the user about this plan's age, or null when
/// there is nothing to say.
///
/// The expired sentence is the important one: it has to explain that sending
/// anyway spends ZEC on a message the channel will ignore, which is the one
/// failure on this path that costs money and produces no error until after it
/// has.
String? nightjarPlanFreshnessText({
  required int anchorHeight,
  required int chainTip,
  int anchorWindow = kNightjarDefaultAnchorWindow,
}) {
  final window = anchorWindow > 0 ? anchorWindow : kNightjarDefaultAnchorWindow;
  switch (nightjarPlanFreshness(
    anchorHeight: anchorHeight,
    chainTip: chainTip,
    anchorWindow: window,
  )) {
    case NightjarPlanFreshness.expired:
      return 'This payment is anchored at block $anchorHeight, which the '
          'channel no longer keeps. Sending it now would spend the ZEC that '
          'carries it on a message every verifier ignores. Rebuild it '
          'against the current channel first.';
    case NightjarPlanFreshness.aging:
      final left =
          window -
          nightjarPlanAnchorAge(anchorHeight: anchorHeight, chainTip: chainTip);
      return 'This payment is anchored at block $anchorHeight and is good for '
          'about $left more blocks. Send it now or rebuild it.';
    case NightjarPlanFreshness.fresh:
      return null;
  }
}

// ---------------------------------------------------------------------------
// The plan a review screen holds
// ---------------------------------------------------------------------------

/// A proven, framed Nightjar payment plus everything the transport needs.
///
/// Nothing in it has been broadcast and nothing has been proposed: holding one
/// costs a plan that is ageing, not a lock on any input.
@immutable
class NightjarSendReviewArgs {
  const NightjarSendReviewArgs({
    required this.sendFlowId,
    required this.accountUuid,
    required this.msgId,
    required this.assetId,
    required this.assetSymbol,
    required this.assetName,
    required this.assetDecimals,
    required this.amount,
    required this.change,
    required this.spent,
    required this.inputs,
    required this.recipient,
    required this.channelAddress,
    required this.memos,
    required this.memoValueZatoshi,
    required this.bodyBytes,
    required this.anchorHeight,
    required this.chainTip,
    required this.vkHash,
    required this.provedMs,
    required this.builtAt,
    this.anchorWindow = kNightjarDefaultAnchorWindow,
  });

  /// One flow id for the whole attempt, in the sense
  /// `propose_send_raw`/`execute_proposal` use it.
  final String sendFlowId;

  /// The Vizor account whose ZEC pays for the memos. Also the account whose
  /// seed derived the Nightjar identity that proved the payment — Nightjar's
  /// derivation takes no ZIP 32 index, so every account on one mnemonic shares
  /// one Nightjar identity, but the ZEC comes from exactly this one.
  final String accountUuid;

  /// The id the channel will know this message by, computed from the body.
  final String msgId;

  final String assetId;

  /// The `ASSET` message's symbol, empty when nobody has named this asset.
  final String assetSymbol;

  /// Whatever the read side had for a name, empty when unnamed.
  final String assetName;

  /// Display hint only; no arithmetic here applies it.
  final int assetDecimals;

  /// Integer base units to the recipient.
  final BigInt amount;

  /// Integer base units back to this wallet.
  final BigInt change;

  /// `amount + change`: what the consumed notes were worth.
  final BigInt spent;

  /// Notes this payment nullifies. At most two — the circuit's input arity.
  final int inputs;

  /// The Nightjar address being paid. It has no Zcash receiver; nothing is
  /// addressed to it on chain.
  final String recipient;

  /// The channel's Zcash unified address — where every memo output actually
  /// goes, and where the ZEC below actually lands.
  final String channelAddress;

  /// The memo fragments, each exactly 512 bytes, in order. All of them ride
  /// one transaction or the message is undecodable.
  final List<Uint8List> memos;

  /// Zatoshi attached to **each** memo output.
  final BigInt memoValueZatoshi;

  /// Encoded transition body, before framing.
  final int bodyBytes;

  /// The canonical height (`tip − 10`) this plan is anchored at.
  final int anchorHeight;

  /// The chain tip the plan was built against.
  final int chainTip;

  /// Blocks of anchors the channel keeps, as its indexer publishes it.
  final int anchorWindow;

  /// Hash of the verifying key this proof will be checked against.
  final String vkHash;

  /// Wall-clock milliseconds Rust spent proving.
  final int provedMs;

  /// When the plan came back. Shown, not enforced: what ages a plan is blocks,
  /// not seconds, and a devnet can sit at one height for an hour.
  final DateTime builtAt;

  int get memoCount => memos.length;

  /// The ZEC this payment costs in memo value, before the Zcash fee. Paid to
  /// the channel; the Nightjar recipient receives none of it.
  BigInt get channelZatoshi => memoValueZatoshi * BigInt.from(memoCount);

  /// The outputs the transport is handed: one per memo, every one to the
  /// channel's address, all in a single proposal.
  List<rust_sync.RawSendOutput> get outputs => [
    for (final memo in memos)
      rust_sync.RawSendOutput(
        toAddress: channelAddress,
        amountZatoshi: memoValueZatoshi,
        memoBytes: memo,
      ),
  ];

  NightjarPlanFreshness freshnessAt(int currentChainTip) =>
      nightjarPlanFreshness(
        anchorHeight: anchorHeight,
        chainTip: currentChainTip > 0 ? currentChainTip : chainTip,
        anchorWindow: anchorWindow,
      );

  String? freshnessTextAt(int currentChainTip) => nightjarPlanFreshnessText(
    anchorHeight: anchorHeight,
    chainTip: currentChainTip > 0 ? currentChainTip : chainTip,
    anchorWindow: anchorWindow,
  );
}

// ---------------------------------------------------------------------------
// Building a plan
// ---------------------------------------------------------------------------

/// The two stages of a build a caller can actually observe.
///
/// There are three stages inside Rust — replay, prove, frame — and this list
/// deliberately does not pretend to see them. `nightjarBuildPay` is one FFI
/// call that returns once; the boundary Dart genuinely knows is the end of
/// the network fetch, so that is the only boundary reported.
enum NightjarBuildPhase {
  /// Fetching the channel from the indexer.
  readingChannel,

  /// Inside `nightjarBuildPay`: every proof re-verified, the state replayed,
  /// the payment proved and framed. Seconds, and about 600 MB of peak memory.
  proving,
}

/// A built plan, or the sentence explaining why there is none.
@immutable
class NightjarPayPlanResult {
  const NightjarPayPlanResult.ready(NightjarSendReviewArgs this.plan)
    : error = null,
      detail = null;

  const NightjarPayPlanResult.failed({required String this.error, this.detail})
    : plan = null;

  final NightjarSendReviewArgs? plan;

  /// Sentence-case copy, already fit to show. Rust's own wording wherever
  /// Rust produced it.
  final String? error;

  /// Machine detail for logs and tests; never rendered raw.
  final String? detail;

  bool get isReady => plan != null;
}

/// Builds a plan for `amount` base units of `assetId` to `recipient`, reading
/// the configuration, the wallet's own chain tip and the active account's seed
/// from [ref].
///
/// The seed is read after every byte of network I/O is done, handed to the FFI
/// call, and zeroed before the result is awaited — the discipline
/// `nightjar_view_loader.dart` follows, and for the same reason: proving is
/// seconds of work and there is no need for a plaintext seed to be live for
/// any of it.
Future<NightjarPayPlanResult> buildNightjarPayPlan(
  WidgetRef ref, {
  required String assetId,
  required BigInt amount,
  required String recipient,
  String assetName = '',
  void Function(NightjarBuildPhase phase)? onPhase,
}) async {
  final NightjarConfig config;
  try {
    config = ref.read(nightjarConfigProvider);
  } catch (_) {
    return const NightjarPayPlanResult.failed(
      error: kNightjarNotConfiguredText,
      detail: 'No Nightjar configuration is available.',
    );
  }
  if (!config.isUsable) {
    return NightjarPayPlanResult.failed(
      error: config.unconfiguredReason ?? kNightjarNotConfiguredText,
      detail: 'Nightjar is not usable on ${config.networkName}.',
    );
  }

  final Uri baseUri;
  try {
    baseUri = config.indexerBaseUri;
  } on FormatException catch (error) {
    return NightjarPayPlanResult.failed(
      error: 'Add a Nightjar indexer before sending.',
      detail: error.message,
    );
  }

  final accounts = await ref.read(accountProvider.future);
  final uuid = accounts.activeAccountUuid;
  if (uuid == null) {
    return const NightjarPayPlanResult.failed(
      error: 'Create or import a wallet account first.',
      detail: 'No active account.',
    );
  }
  // A Nightjar payment is proved from the seed, and a hardware account's seed
  // never reaches this device. Refusing here is the honest answer; there is no
  // device-side path to fall back to.
  if (ref.read(accountProvider.notifier).isHardwareAccount(uuid)) {
    return const NightjarPayPlanResult.failed(
      error: kNightjarHardwareAccountText,
      detail: 'The active account is a hardware account.',
    );
  }

  final walletChainTip = ref.read(syncProvider).value?.chainTipHeight;
  // This wallet's own two sources for the transaction behind a ZEC claim; see
  // the read path in `nightjar_view_loader.dart`. Never the indexer.
  String dbPath = '';
  try {
    dbPath = await getWalletDbPath();
  } catch (_) {
    dbPath = '';
  }
  final zecSources = rust_nightjar.NjZecSources(
    dbPath: dbPath,
    lightwalletdUrl: ref.read(rpcEndpointProvider).normalizedLightwalletdUrl,
  );
  final client = NightjarIndexerClient(baseUri: baseUri);
  try {
    return await buildNightjarPayPlanWith(
      config: config,
      client: client,
      accountUuid: uuid,
      sendFlowId: newSendFlowId(),
      assetId: assetId,
      amount: amount,
      recipient: recipient,
      assetName: assetName,
      walletChainTip: walletChainTip,
      zecSources: zecSources,
      readSeed: () =>
          ref.read(accountProvider.notifier).getMnemonicBytesForAccount(uuid),
      onPhase: onPhase,
    );
  } finally {
    client.close();
  }
}

/// [buildNightjarPayPlan] with every read passed in.
///
/// The channel is fetched fresh rather than reused from the read side's view:
/// the plan's anchor is the tree root at `tip − 10` and it starts ageing the
/// moment it exists, so building against a view the user opened ten minutes
/// ago would hand them a plan that is already old. It also means the two
/// checks the read path makes are made again here — the key against the hash
/// its own server publishes, and every message arriving with a body.
Future<NightjarPayPlanResult> buildNightjarPayPlanWith({
  required NightjarConfig config,
  required NightjarIndexerClient client,
  required String accountUuid,
  required String sendFlowId,
  required String assetId,
  required BigInt amount,
  required String recipient,
  required NightjarSeedReader readSeed,
  int? walletChainTip,
  // The send path replays the channel through exactly the same call the read
  // path does, so it needs the same evidence. Planning against a view whose
  // claims went unchecked would mean proving against an anchor the rest of the
  // channel does not have — the plan would be refused by every other verifier
  // *after* the user had paid the Zcash fee to carry it.
  rust_nightjar.NjZecSources zecSources = _noPayZecSources,
  String assetName = '',
  void Function(NightjarBuildPhase phase)? onPhase,
  NightjarPayBridge bridge = const NightjarPayBridge(),
}) async {
  if (amount <= BigInt.zero) {
    return const NightjarPayPlanResult.failed(
      error: 'Enter an amount greater than zero.',
    );
  }
  if (recipient.trim().isEmpty) {
    return const NightjarPayPlanResult.failed(
      error: 'Enter a Nightjar address to pay.',
    );
  }
  if (!config.hasProvingKeyDir) {
    return const NightjarPayPlanResult.failed(
      error: kNightjarProvingKeyNotSetText,
      detail: 'No proving-key folder is configured.',
    );
  }

  onPhase?.call(NightjarBuildPhase.readingChannel);

  final NightjarIndexerStatus status;
  final NightjarVerifyingKey key;
  final List<NightjarMessage> messages;
  try {
    status = await client.fetchStatus();
    key = await client.fetchVerifyingKey();
    messages = await client.fetchAllMessages();
  } on NightjarIndexerException catch (error) {
    return NightjarPayPlanResult.failed(
      error: error.message,
      detail: error.toString(),
    );
  } catch (error) {
    return NightjarPayPlanResult.failed(
      error: kNightjarUnreachableText,
      detail: 'Reading the indexer failed: $error',
    );
  }

  // The key the proofs will be checked against has to be the key this server
  // says it serves. `nightjarBuildPay` verifies every proof with whatever is
  // handed to it, so a key that does not hash to its own published value would
  // make the replay underneath the plan meaningless.
  if (!key.matchesVkHash(status.info.vkHash)) {
    return NightjarPayPlanResult.failed(
      error: kNightjarVerifyingKeyMismatchText,
      detail:
          'The indexer publishes vk_hash ${status.info.vkHash} and served a '
          'key hashing to ${key.vkHash}.',
    );
  }

  final inputs = <rust_nightjar.NjMessageInput>[];
  for (final message in messages) {
    final body = message.body;
    if (body == null) {
      return NightjarPayPlanResult.failed(
        error:
            'The Nightjar indexer served a message without its body, so this '
            'channel cannot be replayed.',
        detail: 'message ${message.msgId} at ord ${message.ord} has no body',
      );
    }
    inputs.add(
      rust_nightjar.NjMessageInput(
        msgId: message.msgId,
        kind: message.kind,
        height: message.height,
        txIndex: message.txIndex,
        actionIndex: message.actionIndex,
        // Hashed into `msg_id` with the kind and the body, so it is passed
        // through verbatim and never reconstructed from `body.length`.
        fragments: message.fragments,
        // A fetch key for the ZEC claims, nothing more — see the read path.
        txid: message.txid,
        body: body,
      ),
    );
  }

  // The wallet's own tip, never the indexer's, when there is one: the anchor
  // this plan is built on is a function of it, and borrowing the indexer's
  // would let the same party that serves the messages pick the anchor.
  final walletTip = walletChainTip ?? 0;
  final chainTip = walletTip > 0 ? walletTip : status.live.tip;

  final seed = await readSeed();
  if (seed == null || seed.isEmpty) {
    return const NightjarPayPlanResult.failed(
      error: 'Unlock this wallet before sending Nightjar assets.',
      detail: 'No seed is available for the active account.',
    );
  }

  onPhase?.call(NightjarBuildPhase.proving);

  // Issued before the seed is zeroed and awaited after it: the plaintext seed
  // is live for the synchronous argument encoding and not for the seconds of
  // replay and proving that follow.
  final Future<rust_nightjar.NjPayPlan> call;
  try {
    call = bridge.buildPay(
      network: config.networkName,
      channelUivk: config.channelUivk,
      birthday: config.birthday,
      chainTip: chainTip,
      vk: key.vk,
      messages: inputs,
      seed: seed,
      keysDir: config.provingKeyDir,
      assetId: assetId,
      amount: amount,
      recipient: recipient.trim(),
      zecSources: zecSources,
    );
  } finally {
    seed.fillRange(0, seed.length, 0);
  }

  final rust_nightjar.NjPayPlan plan;
  try {
    plan = await call;
  } catch (error) {
    // Rust's sentences name the shortfall, the two-note input limit and the
    // finality depth — all three of which are what make an "insufficient
    // funds" against a larger visible balance explicable rather than absurd.
    return NightjarPayPlanResult.failed(
      error: nightjarErrorText(error),
      detail: 'nightjarBuildPay failed: $error',
    );
  }

  if (plan.memos.isEmpty) {
    return const NightjarPayPlanResult.failed(
      error: 'This payment produced no memos to send.',
      detail: 'NjPayPlan.memos was empty.',
    );
  }

  return NightjarPayPlanResult.ready(
    NightjarSendReviewArgs(
      sendFlowId: sendFlowId,
      accountUuid: accountUuid,
      msgId: plan.msgId,
      assetId: plan.assetId,
      assetSymbol: plan.assetSymbol,
      assetName: assetName,
      assetDecimals: plan.assetDecimals,
      amount: plan.amount,
      change: plan.change,
      spent: plan.spent,
      inputs: plan.inputs,
      recipient: recipient.trim(),
      channelAddress: config.channelAddress,
      memos: plan.memos,
      memoValueZatoshi: plan.memoValueZatoshi,
      bodyBytes: plan.bodyBytes,
      anchorHeight: plan.anchorHeight,
      chainTip: plan.chainTip,
      anchorWindow: status.info.anchorWindow > 0
          ? status.info.anchorWindow
          : kNightjarDefaultAnchorWindow,
      vkHash: plan.vkHash,
      provedMs: plan.provedMs,
      builtAt: DateTime.now(),
    ),
  );
}

// ---------------------------------------------------------------------------
// Broadcasting a plan
// ---------------------------------------------------------------------------

/// Shown when the active account's spending key lives on a hardware device.
const String kNightjarHardwareAccountText =
    'A Nightjar payment is proved from this wallet’s seed, and a hardware '
    'account keeps its seed on the device. Switch to a software account to '
    'send Nightjar assets.';

/// Where the broadcast leg has got to. Both steps are the wallet's own
/// ordinary send path; neither touches Nightjar.
enum NightjarSendPhase {
  /// Selecting ZEC inputs for the memo outputs.
  proposing,

  /// Signing and handing the transaction to lightwalletd.
  broadcasting,
}

enum NightjarSendOutcomePhase { succeeded, pendingBroadcast, failed, aborted }

@immutable
class NightjarSendOutcome {
  const NightjarSendOutcome({
    required this.phase,
    required this.proposalConsumed,
    this.txid,
    this.statusMessage,
    this.error,
  });

  final NightjarSendOutcomePhase phase;

  /// Whether the Rust execute call took ownership of the proposal. False
  /// outside [NightjarSendOutcomePhase.aborted] means the caller must not
  /// assume the inputs were released here.
  final bool proposalConsumed;

  final String? txid;

  /// Sentence-case copy for an outcome that is neither a clean success nor a
  /// clean failure.
  final String? statusMessage;

  final String? error;
}

/// Runs the transport leg for a built plan: one proposal carrying every memo,
/// then execute and broadcast.
Future<NightjarSendOutcome> runNightjarSendBroadcast({
  required WidgetRef ref,
  required NightjarSendReviewArgs args,
  void Function(NightjarSendPhase phase)? onPhase,
  Future<bool> Function()? shouldAbort,
}) {
  final accountNotifier = ref.read(accountProvider.notifier);
  return runNightjarSendBroadcastWith(
    args: args,
    syncNotifier: ref.read(syncProvider.notifier),
    readEndpoint: () => ref.read(rpcEndpointFailoverProvider).current,
    readSeed: () =>
        accountNotifier.getMnemonicBytesForAccount(args.accountUuid),
    isHardwareAccount: () =>
        accountNotifier.isHardwareAccount(args.accountUuid),
    onPhase: onPhase,
    shouldAbort: shouldAbort,
  );
}

/// [runNightjarSendBroadcast] with every read passed in.
///
/// The proposal-lifecycle invariants are the ZEC flow's, unchanged:
/// `execute_proposal` consumes on entry, the consumed flag flips the moment
/// the call is issued, and every non-consuming exit runs the idempotent
/// [discardSendProposal].
Future<NightjarSendOutcome> runNightjarSendBroadcastWith({
  required NightjarSendReviewArgs args,
  required SyncNotifier syncNotifier,
  required RpcEndpointConfig Function() readEndpoint,
  required NightjarSeedReader readSeed,
  bool Function()? isHardwareAccount,
  void Function(NightjarSendPhase phase)? onPhase,
  Future<bool> Function()? shouldAbort,
  Future<String> Function() loadDbPath = getWalletDbPath,
  NightjarSendBridge bridge = const NightjarSendBridge(),
}) async {
  if (args.memos.isEmpty) {
    return const NightjarSendOutcome(
      phase: NightjarSendOutcomePhase.failed,
      proposalConsumed: false,
      error: 'This payment has no memos to send.',
    );
  }
  if (isHardwareAccount?.call() ?? false) {
    return const NightjarSendOutcome(
      phase: NightjarSendOutcomePhase.failed,
      proposalConsumed: false,
      error: kNightjarHardwareAccountText,
    );
  }

  BigInt? proposalId;
  var proposalConsumed = false;
  var proposalReleased = false;

  Future<bool> releaseProposal(String context) async {
    final id = proposalId;
    if (id == null || proposalConsumed || proposalReleased) return true;
    proposalReleased = true;
    return discardSendProposal(
      proposalId: id,
      sendFlowId: args.sendFlowId,
      logContext: 'NightjarSend($context)',
      syncNotifier: syncNotifier,
      accountUuid: args.accountUuid,
    );
  }

  Future<bool> abortRequested(String context) async {
    if (shouldAbort == null) return false;
    if (!await shouldAbort()) return false;
    await releaseProposal(context);
    return true;
  }

  try {
    final dbPath = await loadDbPath();
    final endpoint = readEndpoint();

    // Checked before anything is proposed as well as after: a screen that was
    // left while the DB path was being resolved should lock no inputs at all.
    if (await abortRequested('abort-before-propose')) {
      return NightjarSendOutcome(
        phase: NightjarSendOutcomePhase.aborted,
        proposalConsumed: proposalConsumed,
      );
    }

    onPhase?.call(NightjarSendPhase.proposing);
    // One call, every memo. A reader reassembles a message only from
    // fragments sharing a txid, so two proposals would produce two
    // transactions and a message nobody can put back together — with the ZEC
    // spent either way.
    final proposal = await syncNotifier.runWithAuthoritativeSpendable(
      accountUuid: args.accountUuid,
      operation: () => bridge.proposeSendRaw(
        dbPath: dbPath,
        network: endpoint.networkName,
        accountUuid: args.accountUuid,
        sendFlowId: args.sendFlowId,
        outputs: args.outputs,
      ),
    );
    proposalId = proposal.proposalId;

    if (await abortRequested('abort-after-propose')) {
      return NightjarSendOutcome(
        phase: NightjarSendOutcomePhase.aborted,
        proposalConsumed: proposalConsumed,
      );
    }

    // The channel address is an Ironwood/Orchard unified address and a memo
    // output to it never needs Sapling proving parameters. If one ever did,
    // sending without them fails inside Rust with an opaque error after the
    // proposal exists, so it is refused here with a sentence instead.
    if (proposal.needsSaplingParams) {
      await releaseProposal('sapling-required');
      return const NightjarSendOutcome(
        phase: NightjarSendOutcomePhase.failed,
        proposalConsumed: false,
        error:
            'This payment would have to be carried by a Sapling output, which '
            'Nightjar memos cannot use. Check the channel address in Nightjar '
            'settings.',
      );
    }

    onPhase?.call(NightjarSendPhase.broadcasting);

    final seed = await readSeed();
    if (seed == null || seed.isEmpty) {
      await releaseProposal('no-seed');
      return const NightjarSendOutcome(
        phase: NightjarSendOutcomePhase.failed,
        proposalConsumed: false,
        error: 'Unlock this wallet before sending Nightjar assets.',
      );
    }

    final Future<rust_sync.ExecuteProposalResult> resultFuture;
    try {
      resultFuture = bridge.executeProposal(
        dbPath: dbPath,
        lightwalletdUrl: endpoint.normalizedLightwalletdUrl,
        proposalId: proposal.proposalId,
        sendFlowId: args.sendFlowId,
        mnemonicBytes: seed,
      );
      // `execute_proposal` removes the stored proposal on entry, so from the
      // moment the call is issued nothing else may release it.
      proposalConsumed = true;
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
    final result = await resultFuture;

    final txids = _nightjarTxids(result.txids);
    final broadcastComplete = result.status == 'broadcasted';

    try {
      await syncNotifier.refreshAfterSend();
    } catch (e) {
      log('NightjarSend: refreshAfterSend failed (non-critical): $e');
    }

    // One transaction is the whole contract. Two means the memos were split
    // and the message is undecodable, and the user has to be told rather than
    // shown a receipt: the ZEC is spent and the asset did not move.
    if (txids.length > 1) {
      return NightjarSendOutcome(
        phase: NightjarSendOutcomePhase.failed,
        proposalConsumed: true,
        txid: txids.first,
        error:
            'This payment was split across ${txids.length} transactions, so '
            'the channel cannot reassemble it. The ZEC was spent and the '
            'asset did not move. Report this before trying again.',
      );
    }

    return NightjarSendOutcome(
      phase: broadcastComplete
          ? NightjarSendOutcomePhase.succeeded
          : NightjarSendOutcomePhase.pendingBroadcast,
      proposalConsumed: true,
      txid: txids.isEmpty ? null : txids.first,
      statusMessage: broadcastComplete
          ? null
          : (result.message ??
                'The transaction was created locally but has not reached the '
                    'network yet. It will retry automatically. Do not send '
                    'this payment again unless it expires.'),
    );
  } catch (error) {
    log('NightjarSend: ERROR: $error');
    if (await abortRequested('abort-on-error')) {
      return NightjarSendOutcome(
        phase: NightjarSendOutcomePhase.aborted,
        proposalConsumed: proposalConsumed,
      );
    }
    await releaseProposal('failure');
    return NightjarSendOutcome(
      phase: NightjarSendOutcomePhase.failed,
      proposalConsumed: proposalConsumed,
      error: nightjarErrorText(error),
    );
  }
}

List<String> _nightjarTxids(String txids) => [
  for (final part in txids.split(','))
    if (part.trim().isNotEmpty) part.trim(),
];
