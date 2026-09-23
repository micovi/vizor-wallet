/// The Nyctis send pipeline: proving-key gate, plan build, and the
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
///   [runNyctisSendBroadcastWith] makes exactly one `proposeSendRaw` call
///   with one `RawSendOutput` per memo. Splitting them produces fragments
///   nobody can reassemble and ZEC spent for nothing.
/// * **The ZEC cost is real and it is paid to the channel.** Each memo is an
///   ordinary shielded output to the *channel's* Zcash address carrying
///   [NyctisSendReviewArgs.memoValueZatoshi]; the recipient of the asset
///   receives no ZEC at all. [NyctisSendReviewArgs.channelZatoshi] is that
///   total, and the review screen states it.
/// * **Plans expire.** The proof is anchored at the tree root of `tip − 10`,
///   and that anchor ages out of the channel's anchor window.
///   [nyctisPlanFreshness] is the arithmetic; a stale plan is ignored with
///   "unknown anchor" *after* the ZEC has been spent, so the review screen
///   refuses to send one.
/// * **The proving key is checked in settings, not at send time.** ~83 MiB,
///   served by nothing, and a key from another ceremony shares the same
///   circuit fingerprint while producing proofs every verifier rejects.
///   [checkNyctisProvingKey] compares the folder's `vk_hash` with the one
///   the replay actually verified against.
///
/// Amounts are integer base units throughout. `assetDecimals` is a display
/// hint applied by `formatNyctisAmount` and by nothing here.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../main.dart' show log;
import '../../../core/config/nyctis_config.dart';
import '../../../core/config/rpc_endpoint_config.dart';
import '../../../core/formatting/zec_amount.dart';
import '../../../core/storage/wallet_paths.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/nyctis_config_provider.dart';
import '../../../providers/rpc_endpoint_failover_provider.dart';
import '../../../providers/rpc_endpoint_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../../rust/api/nyctis.dart' as rust_nyctis;
import '../../../rust/api/sync.dart' as rust_sync;
import '../../send/services/send_flow.dart'
    show discardSendProposal, newSendFlowId;
import '../models/nyctis_indexer_status.dart';
import '../models/nyctis_message.dart';
import '../models/nyctis_verifying_key.dart';
import '../widgets/nyctis_asset_row_mapper.dart';
import 'nyctis_address.dart';
import 'nyctis_indexer_client.dart';
// [NyctisSeedReader] is the read path's callback and is reused verbatim:
// the caller controls *when* the seed is in memory, so it can be read after
// the network I/O, handed to the FFI call, and zeroed in a `finally` before
// the result is awaited.
import 'nyctis_view_loader.dart' show NyctisSeedReader;

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
const _noPayZecSources = rust_nyctis.NyZecSources(
  dbPath: '',
  lightwalletdUrl: '',
);

class NyctisPayBridge {
  const NyctisPayBridge();

  Future<rust_nyctis.NyProvingKey> checkProvingKey({
    required String keysDir,
  }) => rust_nyctis.nyctisCheckProvingKey(keysDir: keysDir);

  Future<rust_nyctis.NyPayPlan> buildPay({
    required String network,
    required String channelUivk,
    required String channelAddress,
    required int birthday,
    required int chainTip,
    required Uint8List vk,
    required String vkPin,
    required List<rust_nyctis.NyMessageInput> messages,
    required Uint8List mnemonic,
    required String keysDir,
    required String assetId,
    required BigInt amount,
    required String recipient,
    required rust_nyctis.NyZecSources zecSources,
  }) => rust_nyctis.nyctisBuildPay(
    network: network,
    channelUivk: channelUivk,
    channelAddress: channelAddress,
    birthday: birthday,
    chainTip: chainTip,
    vk: vk,
    vkPin: vkPin,
    messages: messages,
    mnemonic: mnemonic,
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
/// seed-zeroing reason as [NyctisPayBridge.buildPay].
class NyctisSendBridge {
  const NyctisSendBridge();

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
String nyctisErrorText(Object error) {
  if (error is String) return error;
  final text = error.toString();
  const prefix = 'Exception: ';
  return text.startsWith(prefix) ? text.substring(prefix.length) : text;
}

// ---------------------------------------------------------------------------
// The proving-key gate
// ---------------------------------------------------------------------------

/// Why sending is or is not available.
enum NyctisProvingKeyState {
  /// No folder has been named. The default, and not a fault: a wallet that
  /// only reads never needs the key.
  notSet,

  /// A folder was named and `nyctisCheckProvingKey` refused it — missing,
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
class NyctisProvingKeyStatus {
  const NyctisProvingKeyStatus({
    required this.state,
    this.dir = '',
    this.circuit,
    this.vkHash,
    this.channelVkHash,
    this.provingKeyBytes,
    this.message,
  });

  final NyctisProvingKeyState state;

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

  /// Sentence-case explanation for every state but [NyctisProvingKeyState
  /// .ready]. Rust's own wording where Rust produced it.
  final String? message;

  /// Whether a payment can be built at all.
  bool get canSend => state == NyctisProvingKeyState.ready;

  /// True when the folder was read but its key set could not be compared with
  /// the channel's, because no replay had produced a hash to compare against.
  ///
  /// Sending is still offered: `nyctisBuildPay` makes the same comparison
  /// itself before it loads the key, so the worst case is a refusal one screen
  /// later rather than a proof nobody accepts. The settings screen says so
  /// instead of implying a check it did not make.
  bool get isUnverifiedAgainstChannel =>
      state == NyctisProvingKeyState.ready && channelVkHash == null;
}

/// Shown wherever sending is offered and no proving-key folder is set.
const String kNyctisProvingKeyNotSetText =
    'Sending needs the Nyctis proving key, which this wallet does not have '
    'yet. Choose the folder that holds it in Nyctis settings.';

/// Shown when the folder holds a usable key set that is not this channel's.
String nyctisProvingKeyWrongSetText({
  required String dir,
  required String keyVkHash,
  required String channelVkHash,
}) =>
    'The proving keys in $dir belong to a different key set than this channel '
    'verifies with (keys $keyVkHash, channel $channelVkHash). A payment '
    'proved with them would be rejected by every verifier on the channel.';

/// Validates a proving-key folder and compares it with the channel's key.
///
/// [channelVkHash] is `NyView.vk_hash` — what the replay actually checked
/// every proof against. Null means no replay has produced one yet, and the
/// result says so rather than reporting a comparison it did not make.
///
/// Cheap enough to run whenever a settings screen opens: Rust reads the
/// 1.8 KiB verifying key and the one-line manifest and only `stat`s the
/// 83 MiB proving key.
Future<NyctisProvingKeyStatus> checkNyctisProvingKey({
  required String keysDir,
  String? channelVkHash,
  NyctisPayBridge bridge = const NyctisPayBridge(),
}) async {
  final dir = keysDir.trim();
  if (dir.isEmpty) {
    return const NyctisProvingKeyStatus(
      state: NyctisProvingKeyState.notSet,
      message: kNyctisProvingKeyNotSetText,
    );
  }

  final rust_nyctis.NyProvingKey info;
  try {
    info = await bridge.checkProvingKey(keysDir: dir);
  } catch (error) {
    return NyctisProvingKeyStatus(
      state: NyctisProvingKeyState.unreadable,
      dir: dir,
      // Rust names the folder, the missing file and the remedy. A generic
      // "couldn't read that folder" would throw all three away.
      message: nyctisErrorText(error),
    );
  }

  final channel = channelVkHash?.trim();
  if (channel != null &&
      channel.isNotEmpty &&
      channel.toLowerCase() != info.vkHash.toLowerCase()) {
    return NyctisProvingKeyStatus(
      state: NyctisProvingKeyState.wrongKeySet,
      dir: info.dir,
      circuit: info.circuit,
      vkHash: info.vkHash,
      channelVkHash: channel,
      provingKeyBytes: info.provingKeyBytes,
      message: nyctisProvingKeyWrongSetText(
        dir: info.dir,
        keyVkHash: info.vkHash,
        channelVkHash: channel,
      ),
    );
  }

  return NyctisProvingKeyStatus(
    state: NyctisProvingKeyState.ready,
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
const int kNyctisDefaultAnchorWindow = 200;

/// The window a plan's freshness is judged by: the indexer's figure when it
/// publishes one, but never longer than the protocol's own
/// ([kNyctisDefaultAnchorWindow], `nyctis-state`'s `ANCHOR_WINDOW`).
///
/// The window is a protocol constant. An indexer reporting a larger one would
/// otherwise keep an expired plan looking fresh, and the channel would ignore
/// it with "unknown anchor" after the ZEC carrying it had been spent.
int nyctisEffectiveAnchorWindow(int reported) {
  if (reported <= 0) return kNyctisDefaultAnchorWindow;
  return reported < kNyctisDefaultAnchorWindow
      ? reported
      : kNyctisDefaultAnchorWindow;
}

/// Blocks of headroom below which a plan is called aging.
///
/// Not a protocol number — the protocol has one threshold, the window — but a
/// plan a user is still reading through has to start warning before it is
/// already worthless.
const int kNyctisAnchorWarningHeadroom = 40;

/// How much life a built plan has left.
enum NyctisPlanFreshness {
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
int nyctisPlanAnchorAge({required int anchorHeight, required int chainTip}) {
  final age = chainTip - anchorHeight;
  return age < 0 ? 0 : age;
}

/// [NyctisPlanFreshness] for a plan anchored at [anchorHeight], judged
/// against [chainTip].
///
/// A [chainTip] of zero — a wallet that has not synced one — comes back
/// [NyctisPlanFreshness.fresh], because "this wallet cannot tell" is not
/// "this plan is good". That distinction belongs to the copy, which is why
/// [nyctisPlanFreshnessText] takes the tip too.
NyctisPlanFreshness nyctisPlanFreshness({
  required int anchorHeight,
  required int chainTip,
  int anchorWindow = kNyctisDefaultAnchorWindow,
}) {
  if (chainTip <= 0) return NyctisPlanFreshness.fresh;
  final window = anchorWindow > 0 ? anchorWindow : kNyctisDefaultAnchorWindow;
  final age = nyctisPlanAnchorAge(
    anchorHeight: anchorHeight,
    chainTip: chainTip,
  );
  if (age >= window) return NyctisPlanFreshness.expired;
  if (window - age <= kNyctisAnchorWarningHeadroom) {
    return NyctisPlanFreshness.aging;
  }
  return NyctisPlanFreshness.fresh;
}

/// What a review screen owes the user about this plan's age, or null when
/// there is nothing to say.
///
/// The expired sentence is the important one: it has to explain that sending
/// anyway spends ZEC on a message the channel will ignore, which is the one
/// failure on this path that costs money and produces no error until after it
/// has.
String? nyctisPlanFreshnessText({
  required int anchorHeight,
  required int chainTip,
  int anchorWindow = kNyctisDefaultAnchorWindow,
}) {
  final window = anchorWindow > 0 ? anchorWindow : kNyctisDefaultAnchorWindow;
  switch (nyctisPlanFreshness(
    anchorHeight: anchorHeight,
    chainTip: chainTip,
    anchorWindow: window,
  )) {
    case NyctisPlanFreshness.expired:
      return 'This payment is anchored at block $anchorHeight, which the '
          'channel no longer keeps. Sending it now would spend the ZEC that '
          'carries it on a message every verifier ignores. Rebuild it '
          'against the current channel first.';
    case NyctisPlanFreshness.aging:
      final left =
          window -
          nyctisPlanAnchorAge(anchorHeight: anchorHeight, chainTip: chainTip);
      return 'This payment is anchored at block $anchorHeight and is good for '
          'about $left more blocks. Send it now or rebuild it.';
    case NyctisPlanFreshness.fresh:
      return null;
  }
}

// ---------------------------------------------------------------------------
// The plan a review screen holds
// ---------------------------------------------------------------------------

/// A proven, framed Nyctis payment plus everything the transport needs.
///
/// Nothing in it has been broadcast and nothing has been proposed: holding one
/// costs a plan that is ageing, not a lock on any input.
@immutable
class NyctisSendReviewArgs {
  const NyctisSendReviewArgs({
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
    this.anchorWindow = kNyctisDefaultAnchorWindow,
    this.quotedFeeZatoshi,
  });

  /// One flow id for the whole attempt, in the sense
  /// `propose_send_raw`/`execute_proposal` use it.
  final String sendFlowId;

  /// The Vizor account whose ZEC pays for the memos. Also the account whose
  /// seed derived the Nyctis identity that proved the payment — Nyctis's
  /// derivation takes no ZIP 32 index, so every account on one mnemonic shares
  /// one Nyctis identity, but the ZEC comes from exactly this one.
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

  /// The Nyctis address being paid. It has no Zcash receiver; nothing is
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

  /// The Zcash network fee the review screen quoted and showed, or null when
  /// no quote has been made.
  ///
  /// Carried to the broadcast so the fee actually charged cannot silently
  /// exceed the one the user confirmed: [runNyctisSendBroadcastWith] refuses
  /// a proposal whose fee is higher, before anything is signed.
  final BigInt? quotedFeeZatoshi;

  int get memoCount => memos.length;

  /// This plan, with [fee] recorded as the fee the user was shown.
  NyctisSendReviewArgs withQuotedFee(BigInt? fee) => NyctisSendReviewArgs(
    sendFlowId: sendFlowId,
    accountUuid: accountUuid,
    msgId: msgId,
    assetId: assetId,
    assetSymbol: assetSymbol,
    assetName: assetName,
    assetDecimals: assetDecimals,
    amount: amount,
    change: change,
    spent: spent,
    inputs: inputs,
    recipient: recipient,
    channelAddress: channelAddress,
    memos: memos,
    memoValueZatoshi: memoValueZatoshi,
    bodyBytes: bodyBytes,
    anchorHeight: anchorHeight,
    chainTip: chainTip,
    vkHash: vkHash,
    provedMs: provedMs,
    builtAt: builtAt,
    anchorWindow: anchorWindow,
    quotedFeeZatoshi: fee,
  );

  /// The ZEC this payment costs in memo value, before the Zcash fee. Paid to
  /// the channel; the Nyctis recipient receives none of it.
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

  NyctisPlanFreshness freshnessAt(int currentChainTip) =>
      nyctisPlanFreshness(
        anchorHeight: anchorHeight,
        chainTip: currentChainTip > 0 ? currentChainTip : chainTip,
        anchorWindow: anchorWindow,
      );

  String? freshnessTextAt(int currentChainTip) => nyctisPlanFreshnessText(
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
/// deliberately does not pretend to see them. `nyctisBuildPay` is one FFI
/// call that returns once; the boundary Dart genuinely knows is the end of
/// the network fetch, so that is the only boundary reported.
enum NyctisBuildPhase {
  /// Fetching the channel from the indexer.
  readingChannel,

  /// Inside `nyctisBuildPay`: every proof re-verified, the state replayed,
  /// the payment proved and framed. Seconds, and about 600 MB of peak memory.
  proving,
}

/// A built plan, or the sentence explaining why there is none.
@immutable
class NyctisPayPlanResult {
  const NyctisPayPlanResult.ready(NyctisSendReviewArgs this.plan)
    : error = null,
      detail = null;

  const NyctisPayPlanResult.failed({required String this.error, this.detail})
    : plan = null;

  final NyctisSendReviewArgs? plan;

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
/// `nyctis_view_loader.dart` follows, and for the same reason: proving is
/// seconds of work and there is no need for a plaintext seed to be live for
/// any of it.
/// Builds a plan. The composer and the review call this rather than
/// [buildNyctisPayPlan] directly, so a widget test can stand in for the
/// channel read and the proof.
typedef NyctisPayPlanBuilder =
    Future<NyctisPayPlanResult> Function({
      required String assetId,
      required BigInt amount,
      required String recipient,
      String assetName,
      void Function(NyctisBuildPhase phase)? onPhase,
    });

/// The shipped builder: [buildNyctisPayPlan] against this wallet.
final nyctisPayPlanBuilderProvider = Provider<NyctisPayPlanBuilder>((ref) {
  return ({
    required String assetId,
    required BigInt amount,
    required String recipient,
    String assetName = '',
    void Function(NyctisBuildPhase phase)? onPhase,
  }) => buildNyctisPayPlan(
    ref,
    assetId: assetId,
    amount: amount,
    recipient: recipient,
    assetName: assetName,
    onPhase: onPhase,
  );
});

Future<NyctisPayPlanResult> buildNyctisPayPlan(
  Ref ref, {
  required String assetId,
  required BigInt amount,
  required String recipient,
  String assetName = '',
  void Function(NyctisBuildPhase phase)? onPhase,
}) async {
  final NyctisConfig config;
  try {
    config = ref.read(nyctisConfigProvider);
  } catch (_) {
    return const NyctisPayPlanResult.failed(
      error: kNyctisNotConfiguredText,
      detail: 'No Nyctis configuration is available.',
    );
  }
  if (!config.isUsable) {
    return NyctisPayPlanResult.failed(
      error: config.unconfiguredReason ?? kNyctisNotConfiguredText,
      detail: 'Nyctis is not usable on ${config.networkName}.',
    );
  }

  final Uri baseUri;
  try {
    baseUri = config.indexerBaseUri;
  } on FormatException catch (error) {
    return NyctisPayPlanResult.failed(
      error: 'Add a Nyctis indexer before sending.',
      detail: error.message,
    );
  }

  final accounts = await ref.read(accountProvider.future);
  final uuid = accounts.activeAccountUuid;
  if (uuid == null) {
    return const NyctisPayPlanResult.failed(
      error: 'Create or import a wallet account first.',
      detail: 'No active account.',
    );
  }
  // A Nyctis payment is proved from the seed, and a hardware account's seed
  // never reaches this device. Refusing here is the honest answer; there is no
  // device-side path to fall back to.
  if (ref.read(accountProvider.notifier).isHardwareAccount(uuid)) {
    return const NyctisPayPlanResult.failed(
      error: kNyctisHardwareAccountText,
      detail: 'The active account is a hardware account.',
    );
  }

  final walletChainTip = ref.read(syncProvider).value?.chainTipHeight;
  // This wallet's own two sources for the transaction behind a ZEC claim; see
  // the read path in `nyctis_view_loader.dart`. Never the indexer.
  String dbPath = '';
  try {
    dbPath = await getWalletDbPath();
  } catch (_) {
    dbPath = '';
  }
  final zecSources = rust_nyctis.NyZecSources(
    dbPath: dbPath,
    lightwalletdUrl: ref.read(rpcEndpointProvider).normalizedLightwalletdUrl,
  );
  final client = NyctisIndexerClient(baseUri: baseUri);
  try {
    return await buildNyctisPayPlanWith(
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

/// [buildNyctisPayPlan] with every read passed in.
///
/// The channel is fetched fresh rather than reused from the read side's view:
/// the plan's anchor is the tree root at `tip − 10` and it starts ageing the
/// moment it exists, so building against a view the user opened ten minutes
/// ago would hand them a plan that is already old. It also means the two
/// checks the read path makes are made again here — the key against the hash
/// its own server publishes, and every message arriving with a body.
Future<NyctisPayPlanResult> buildNyctisPayPlanWith({
  required NyctisConfig config,
  required NyctisIndexerClient client,
  required String accountUuid,
  required String sendFlowId,
  required String assetId,
  required BigInt amount,
  required String recipient,
  required NyctisSeedReader readSeed,
  int? walletChainTip,
  // The send path replays the channel through exactly the same call the read
  // path does, so it needs the same evidence. Planning against a view whose
  // claims went unchecked would mean proving against an anchor the rest of the
  // channel does not have — the plan would be refused by every other verifier
  // *after* the user had paid the Zcash fee to carry it.
  rust_nyctis.NyZecSources zecSources = _noPayZecSources,
  String assetName = '',
  void Function(NyctisBuildPhase phase)? onPhase,
  NyctisPayBridge bridge = const NyctisPayBridge(),
}) async {
  if (amount <= BigInt.zero) {
    return const NyctisPayPlanResult.failed(
      error: 'Enter an amount greater than zero.',
    );
  }
  if (recipient.trim().isEmpty) {
    return const NyctisPayPlanResult.failed(
      error: 'Enter a Nyctis address to pay.',
    );
  }
  // Checked before a byte of network I/O: a typo should cost a keystroke,
  // not a channel read and a proof.
  final recipientError = nyctisRecipientError(
    recipient,
    networkName: config.networkName,
  );
  if (recipientError != null) {
    return NyctisPayPlanResult.failed(error: recipientError);
  }
  if (!config.hasProvingKeyDir) {
    return const NyctisPayPlanResult.failed(
      error: kNyctisProvingKeyNotSetText,
      detail: 'No proving-key folder is configured.',
    );
  }

  onPhase?.call(NyctisBuildPhase.readingChannel);

  final NyctisIndexerStatus status;
  final NyctisVerifyingKey key;
  final List<NyctisMessage> messages;
  try {
    status = await client.fetchStatus();
    key = await client.fetchVerifyingKey();
    messages = await client.fetchAllMessages();
  } on NyctisIndexerException catch (error) {
    return NyctisPayPlanResult.failed(
      error: error.message,
      detail: error.toString(),
    );
  } catch (error) {
    return NyctisPayPlanResult.failed(
      error: kNyctisUnreachableText,
      detail: 'Reading the indexer failed: $error',
    );
  }

  // The key the proofs will be checked against has to be the key this server
  // says it serves. `nyctisBuildPay` verifies every proof with whatever is
  // handed to it, so a key that does not hash to its own published value would
  // make the replay underneath the plan meaningless.
  if (!key.matchesVkHash(status.info.vkHash)) {
    return NyctisPayPlanResult.failed(
      error: kNyctisVerifyingKeyMismatchText,
      detail:
          'The indexer publishes vk_hash ${status.info.vkHash} and served a '
          'key hashing to ${key.vkHash}.',
    );
  }

  final inputs = <rust_nyctis.NyMessageInput>[];
  for (final message in messages) {
    final body = message.body;
    if (body == null) {
      return NyctisPayPlanResult.failed(
        error:
            'The Nyctis indexer served a message without its body, so this '
            'channel cannot be replayed.',
        detail: 'message ${message.msgId} at ord ${message.ord} has no body',
      );
    }
    inputs.add(
      rust_nyctis.NyMessageInput(
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
    return const NyctisPayPlanResult.failed(
      error: 'Unlock this wallet before sending Nyctis assets.',
      detail: 'No seed is available for the active account.',
    );
  }

  onPhase?.call(NyctisBuildPhase.proving);

  // Issued before the seed is zeroed and awaited after it: the plaintext seed
  // is live for the synchronous argument encoding and not for the seconds of
  // replay and proving that follow.
  final Future<rust_nyctis.NyPayPlan> call;
  try {
    call = bridge.buildPay(
      network: config.networkName,
      channelUivk: config.channelUivk,
      channelAddress: config.channelAddress,
      birthday: config.birthday,
      chainTip: chainTip,
      vk: key.vk,
      vkPin: config.vkPin,
      messages: inputs,
      mnemonic: seed,
      keysDir: config.provingKeyDir,
      assetId: assetId,
      amount: amount,
      recipient: recipient.trim(),
      zecSources: zecSources,
    );
  } finally {
    seed.fillRange(0, seed.length, 0);
  }

  final rust_nyctis.NyPayPlan plan;
  try {
    plan = await call;
  } catch (error) {
    // Rust's sentences name the shortfall, the two-note input limit and the
    // finality depth — all three of which are what make an "insufficient
    // funds" against a larger visible balance explicable rather than absurd.
    return NyctisPayPlanResult.failed(
      error: nyctisErrorText(error),
      detail: 'nyctisBuildPay failed: $error',
    );
  }

  if (plan.memos.isEmpty) {
    return const NyctisPayPlanResult.failed(
      error: 'This payment produced no memos to send.',
      detail: 'NyPayPlan.memos was empty.',
    );
  }

  return NyctisPayPlanResult.ready(
    NyctisSendReviewArgs(
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
      // Rust's figure is the protocol's window. The indexer's `anchor_window`
      // is a claim, and a larger one would keep an expired plan looking fresh.
      anchorWindow: nyctisEffectiveAnchorWindow(plan.anchorWindow),
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
const String kNyctisHardwareAccountText =
    'A Nyctis payment is proved from this wallet’s seed, and a hardware '
    'account keeps its seed on the device. Switch to a software account to '
    'send Nyctis assets.';

/// Where the broadcast leg has got to. Both steps are the wallet's own
/// ordinary send path; neither touches Nyctis.
enum NyctisSendPhase {
  /// Selecting ZEC inputs for the memo outputs.
  proposing,

  /// Signing and handing the transaction to lightwalletd.
  broadcasting,
}

enum NyctisSendOutcomePhase { succeeded, pendingBroadcast, failed, aborted }

@immutable
class NyctisSendOutcome {
  const NyctisSendOutcome({
    required this.phase,
    required this.proposalConsumed,
    this.txid,
    this.statusMessage,
    this.error,
  });

  final NyctisSendOutcomePhase phase;

  /// Whether the Rust execute call took ownership of the proposal. False
  /// outside [NyctisSendOutcomePhase.aborted] means the caller must not
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
Future<NyctisSendOutcome> runNyctisSendBroadcast({
  required WidgetRef ref,
  required NyctisSendReviewArgs args,
  void Function(NyctisSendPhase phase)? onPhase,
  Future<bool> Function()? shouldAbort,
}) {
  final accountNotifier = ref.read(accountProvider.notifier);
  return runNyctisSendBroadcastWith(
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

/// [runNyctisSendBroadcast] with every read passed in.
///
/// The proposal-lifecycle invariants are the ZEC flow's, unchanged:
/// `execute_proposal` consumes on entry, the consumed flag flips the moment
/// the call is issued, and every non-consuming exit runs the idempotent
/// [discardSendProposal].
Future<NyctisSendOutcome> runNyctisSendBroadcastWith({
  required NyctisSendReviewArgs args,
  required SyncNotifier syncNotifier,
  required RpcEndpointConfig Function() readEndpoint,
  required NyctisSeedReader readSeed,
  bool Function()? isHardwareAccount,
  void Function(NyctisSendPhase phase)? onPhase,
  Future<bool> Function()? shouldAbort,
  Future<String> Function() loadDbPath = getWalletDbPath,
  NyctisSendBridge bridge = const NyctisSendBridge(),
}) async {
  if (args.memos.isEmpty) {
    return const NyctisSendOutcome(
      phase: NyctisSendOutcomePhase.failed,
      proposalConsumed: false,
      error: 'This payment has no memos to send.',
    );
  }
  if (isHardwareAccount?.call() ?? false) {
    return const NyctisSendOutcome(
      phase: NyctisSendOutcomePhase.failed,
      proposalConsumed: false,
      error: kNyctisHardwareAccountText,
    );
  }
  final channelError = nyctisChannelAddressError(args.channelAddress);
  if (channelError != null) {
    return NyctisSendOutcome(
      phase: NyctisSendOutcomePhase.failed,
      proposalConsumed: false,
      error: channelError,
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
      logContext: 'NyctisSend($context)',
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
      return NyctisSendOutcome(
        phase: NyctisSendOutcomePhase.aborted,
        proposalConsumed: proposalConsumed,
      );
    }

    onPhase?.call(NyctisSendPhase.proposing);
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
      return NyctisSendOutcome(
        phase: NyctisSendOutcomePhase.aborted,
        proposalConsumed: proposalConsumed,
      );
    }

    // The channel address is an Ironwood/Orchard unified address and a memo
    // output to it never needs Sapling proving parameters. If one ever did,
    // sending without them fails inside Rust with an opaque error after the
    // proposal exists, so it is refused here with a sentence instead.
    if (proposal.needsSaplingParams) {
      await releaseProposal('sapling-required');
      return const NyctisSendOutcome(
        phase: NyctisSendOutcomePhase.failed,
        proposalConsumed: false,
        error: kNyctisSaplingCarrierText,
      );
    }

    // The fee the user confirmed is a ceiling, not a guess: a proposal that
    // now costs more (different notes selected since the review) is released
    // unsigned, and the user reviews the new figure.
    final quoted = args.quotedFeeZatoshi;
    if (quoted != null && proposal.feeZatoshi > quoted) {
      await releaseProposal('fee-changed');
      return NyctisSendOutcome(
        phase: NyctisSendOutcomePhase.failed,
        proposalConsumed: false,
        error: nyctisFeeChangedText(
          quoted: quoted,
          current: proposal.feeZatoshi,
        ),
      );
    }

    onPhase?.call(NyctisSendPhase.broadcasting);

    final seed = await readSeed();
    if (seed == null || seed.isEmpty) {
      await releaseProposal('no-seed');
      return const NyctisSendOutcome(
        phase: NyctisSendOutcomePhase.failed,
        proposalConsumed: false,
        error: 'Unlock this wallet before sending Nyctis assets.',
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

    final txids = _nyctisTxids(result.txids);
    final broadcastComplete = result.status == 'broadcasted';

    try {
      await syncNotifier.refreshAfterSend();
    } catch (e) {
      log('NyctisSend: refreshAfterSend failed (non-critical): $e');
    }

    // One transaction is the whole contract. Two means the memos were split
    // and the message is undecodable, and the user has to be told rather than
    // shown a receipt: the ZEC is spent and the asset did not move.
    if (txids.length > 1) {
      return NyctisSendOutcome(
        phase: NyctisSendOutcomePhase.failed,
        proposalConsumed: true,
        txid: txids.first,
        error:
            'This payment was split across ${txids.length} transactions, so '
            'the channel cannot reassemble it. The ZEC was spent and the '
            'asset did not move. Do not send it again; report it to Vizor '
            'support with the transaction hash below.',
      );
    }

    return NyctisSendOutcome(
      phase: broadcastComplete
          ? NyctisSendOutcomePhase.succeeded
          : NyctisSendOutcomePhase.pendingBroadcast,
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
    log('NyctisSend: ERROR: $error');
    if (await abortRequested('abort-on-error')) {
      return NyctisSendOutcome(
        phase: NyctisSendOutcomePhase.aborted,
        proposalConsumed: proposalConsumed,
      );
    }
    await releaseProposal('failure');
    return NyctisSendOutcome(
      phase: NyctisSendOutcomePhase.failed,
      proposalConsumed: proposalConsumed,
      error: nyctisErrorText(error),
    );
  }
}

// ---------------------------------------------------------------------------
// The ZEC side, checked before anything is proved or signed
// ---------------------------------------------------------------------------

/// Shown when the proposer would need a Sapling output to carry the memos.
const String kNyctisSaplingCarrierText =
    'This payment would have to be carried by a Sapling output, which '
    'Nyctis memos cannot use. Check the channel address in Nyctis '
    'settings.';

/// Why [channelAddress] cannot carry a Nyctis payment in one transaction,
/// or null when it can.
///
/// Every memo of one payment must ride one transaction. A TEX address is the
/// one Zcash recipient the proposer always pays in two steps (shielded to an
/// ephemeral transparent address, then on), which would split the memos and
/// make the message undecodable — so it is refused before a proposal exists,
/// rather than detected after the ZEC has been spent.
String? nyctisChannelAddressError(String channelAddress) {
  final address = channelAddress.trim().toLowerCase();
  if (address.isEmpty) {
    return 'Nyctis has no channel address to pay. Check Nyctis settings.';
  }
  if (address.startsWith('tex')) {
    return 'The channel address is a TEX address, which Zcash pays in two '
        'transactions. A Nyctis payment must ride one transaction, so it '
        'cannot be sent to this channel. Check the channel address in '
        'Nyctis settings.';
  }
  return null;
}

/// Zatoshi the smallest possible Nyctis payment needs before it is proved:
/// one memo's value ([kNyctisMemoValueZatoshi]) plus the ZIP 317 minimum
/// fee of two logical actions.
///
/// A lower bound, not an estimate. The memo count is only known once the
/// payment is proved; the review screen then quotes the exact figure. What
/// this buys is refusing, before a proof, a wallet that could not pay for
/// even the cheapest message.
const int kNyctisMemoValueZatoshi = 10000;
const int kNyctisZip317MinimumFeeZatoshi = 10000;
final BigInt kNyctisMinimumZecZatoshi = BigInt.from(
  kNyctisMemoValueZatoshi + kNyctisZip317MinimumFeeZatoshi,
);

/// Why this account's spendable ZEC cannot carry any Nyctis payment, or null
/// when it might.
String? nyctisZecShortfallText(BigInt spendableZatoshi) {
  if (spendableZatoshi >= kNyctisMinimumZecZatoshi) return null;
  final needed = ZecAmount.fromZatoshi(kNyctisMinimumZecZatoshi).fee;
  final held = ZecAmount.fromZatoshi(spendableZatoshi).fee;
  return 'A Nyctis payment is carried by a shielded Zcash transaction that '
      'costs at least $needed, paid to the channel and as the network fee. '
      'This account has $held spendable.';
}

/// Shown when the proposal at send time would cost more than the review said.
String nyctisFeeChangedText({
  required BigInt quoted,
  required BigInt current,
}) =>
    'The network fee changed from ${ZecAmount.fromZatoshi(quoted).fee} to '
    '${ZecAmount.fromZatoshi(current).fee} since you reviewed this payment. '
    'Nothing was sent. Review it again to see the new total.';

/// The ZEC a plan will cost, quoted by proposing it and releasing the
/// proposal straight away.
@immutable
class NyctisZecQuote {
  const NyctisZecQuote.ready({
    required BigInt this.feeZatoshi,
    required this.channelZatoshi,
  }) : error = null;

  const NyctisZecQuote.failed({
    required String this.error,
    required this.channelZatoshi,
  }) : feeZatoshi = null;

  /// The Zcash network fee the proposer charged, or null when it could not
  /// propose.
  final BigInt? feeZatoshi;

  /// The memo value paid to the channel. Known from the plan alone.
  final BigInt channelZatoshi;

  /// Sentence-case reason the plan cannot be carried, or null.
  final String? error;

  bool get isReady => feeZatoshi != null && error == null;

  /// Everything that leaves this account in ZEC, or null without a fee.
  BigInt? get totalZatoshi {
    final fee = feeZatoshi;
    return fee == null ? null : fee + channelZatoshi;
  }
}

/// A quote for one plan. Injectable, like the broadcast runner, so a widget
/// test can answer without Rust.
typedef NyctisSendQuoter =
    Future<NyctisZecQuote> Function(NyctisSendReviewArgs plan);

/// The shipped quoter: this wallet's own proposer, for the plan's account.
final nyctisSendQuoterProvider = Provider<NyctisSendQuoter>((ref) {
  return (plan) {
    final sync = ref.read(syncProvider.notifier);
    return quoteNyctisSendWith(
      plan: plan,
      syncNotifier: sync,
      readEndpoint: () => ref.read(rpcEndpointFailoverProvider).current,
      spendableZatoshi: ref.read(syncProvider).value?.spendableBalance,
    );
  };
});

/// Quotes [plan]'s ZEC cost: proposes exactly the outputs the broadcast will,
/// reads the fee, and releases the proposal.
///
/// Releasing rather than holding it keeps the review screen free of input
/// locks — a user may read a review for minutes, or leave it — and the
/// broadcast proposes again with [NyctisSendReviewArgs.quotedFeeZatoshi] as
/// its ceiling, so the figure shown is the most that can be charged.
Future<NyctisZecQuote> quoteNyctisSendWith({
  required NyctisSendReviewArgs plan,
  required SyncNotifier syncNotifier,
  required RpcEndpointConfig Function() readEndpoint,
  BigInt? spendableZatoshi,
  Future<String> Function() loadDbPath = getWalletDbPath,
  NyctisSendBridge bridge = const NyctisSendBridge(),
  Future<void> Function(BigInt proposalId, String sendFlowId)? releaseProposal,
}) async {
  final channelZatoshi = plan.channelZatoshi;
  if (plan.memos.isEmpty) {
    return NyctisZecQuote.failed(
      error: 'This payment has no memos to send.',
      channelZatoshi: channelZatoshi,
    );
  }
  final channelError = nyctisChannelAddressError(plan.channelAddress);
  if (channelError != null) {
    return NyctisZecQuote.failed(
      error: channelError,
      channelZatoshi: channelZatoshi,
    );
  }

  // Its own flow id: the quote's proposal is released here and must never be
  // confused with the one the broadcast makes.
  final quoteFlowId = newSendFlowId();
  final rust_sync.ProposalResult proposal;
  try {
    final dbPath = await loadDbPath();
    final endpoint = readEndpoint();
    proposal = await syncNotifier.runWithAuthoritativeSpendable(
      accountUuid: plan.accountUuid,
      operation: () => bridge.proposeSendRaw(
        dbPath: dbPath,
        network: endpoint.networkName,
        accountUuid: plan.accountUuid,
        sendFlowId: quoteFlowId,
        outputs: plan.outputs,
      ),
    );
  } catch (error) {
    return NyctisZecQuote.failed(
      error: _nyctisQuoteErrorText(
        error,
        channelZatoshi: channelZatoshi,
        spendableZatoshi: spendableZatoshi,
      ),
      channelZatoshi: channelZatoshi,
    );
  }

  try {
    if (releaseProposal != null) {
      await releaseProposal(proposal.proposalId, quoteFlowId);
    } else {
      await discardSendProposal(
        proposalId: proposal.proposalId,
        sendFlowId: quoteFlowId,
        logContext: 'NyctisSend(quote)',
        syncNotifier: syncNotifier,
        accountUuid: plan.accountUuid,
      );
    }
  } catch (error) {
    log('NyctisSend: releasing the quote failed (non-critical): $error');
  }

  if (proposal.needsSaplingParams) {
    return NyctisZecQuote.failed(
      error: kNyctisSaplingCarrierText,
      channelZatoshi: channelZatoshi,
    );
  }
  return NyctisZecQuote.ready(
    feeZatoshi: proposal.feeZatoshi,
    channelZatoshi: channelZatoshi,
  );
}

String _nyctisQuoteErrorText(
  Object error, {
  required BigInt channelZatoshi,
  BigInt? spendableZatoshi,
}) {
  final text = nyctisErrorText(error);
  if (!text.toLowerCase().contains('insufficient')) return text;
  final needed = ZecAmount.fromZatoshi(channelZatoshi).fee;
  final held = spendableZatoshi == null
      ? null
      : ZecAmount.fromZatoshi(spendableZatoshi).fee;
  return 'This account does not have enough ZEC to carry this payment. It '
      'needs $needed for the channel plus the network fee'
      '${held == null ? '' : ', and has $held spendable'}. Nothing was proved '
      'again and nothing was sent.';
}

// ---------------------------------------------------------------------------
// Time, said in words
// ---------------------------------------------------------------------------

/// How long [depth] blocks take on [networkName], for copy.
///
/// Mainnet and testnet target 75-second blocks, so 10 blocks is about 13
/// minutes. A regtest chain moves only when blocks are mined, so it gets no
/// clock time at all rather than a made-up one.
String nyctisFinalityEstimateText(String networkName, int depth) {
  return switch (zcashNetworkFromName(networkName)) {
    ZcashNetwork.regtest =>
      depth == 1
          ? 'once 1 more block is mined'
          : 'once $depth more blocks are mined',
    ZcashNetwork.mainnet ||
    ZcashNetwork.testnet => 'in about ${((depth * 75) / 60).ceil()} minutes',
  };
}

/// Roughly how long proving takes, said before it starts.
const String kNyctisProvingEstimateText =
    'about 2 seconds on a laptop, longer on a phone';

List<String> _nyctisTxids(String txids) => [
  for (final part in txids.split(','))
    if (part.trim().isNotEmpty) part.trim(),
];
