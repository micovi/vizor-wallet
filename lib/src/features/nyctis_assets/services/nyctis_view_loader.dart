/// The real Nyctis view loader: indexer for data availability, Rust for
/// everything that decides what the wallet believes.
///
/// The split is the whole point of the PoC and is worth restating where it is
/// implemented. This file fetches three things over HTTP — the indexer's
/// status, its verifying key, and every message body on the channel — and then
/// hands them to `nyctisReplay`, which verifies each Groth16 proof, replays
/// the state machine, and trial-decrypts the ciphertexts with the wallet's own
/// Nyctis viewing key. The replay never sees the seed: the viewing key is
/// derived from it once per unlock ([NyctisViewingKeyCache]) and kept in
/// memory until the wallet locks.
///
/// Four things the indexer does **not** get to decide, each checked here:
///
/// * **Which channel this is.** `/api/status` says which channel it serves;
///   the wallet derives the same id from its own configured UIVK and refuses
///   to replay anything else.
/// * **Which key proofs are checked against.** `/api/vk` carries the key and
///   `/api/status` publishes its hash; a key that does not hash to the value
///   its own server advertises is not used at all, and Rust refuses any key
///   that does not hash to the configuration's own [NyctisConfig.vkPin].
/// * **Where the finality cut-off falls.** The chain tip comes from this
///   wallet's own lightwalletd sync. Falling back to the indexer's tip is
///   allowed, but the view records that it did and the UI discloses it.
/// * **Whether it served everything.** The replay's own state root is compared
///   against the one the indexer publishes for the same height, and the
///   indexer's read height is compared against the height the view closes at.
///   Withholding a message is the one attack this cut cannot prevent; it can
///   still be noticed, and those are the two places it shows.
///
/// See `docs/NYCTIS-POC.md`.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/nyctis_config.dart';
import '../../../core/storage/wallet_paths.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../../../providers/nyctis_config_provider.dart';
import '../../../providers/rpc_endpoint_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../../rust/api/nyctis.dart' as rust_nyctis;
import '../models/nyctis_indexer_status.dart';
import '../models/nyctis_message.dart';
import '../models/nyctis_verifying_key.dart';
import '../widgets/nyctis_asset_row_data.dart';
import '../widgets/nyctis_asset_row_mapper.dart';
import 'nyctis_indexer_client.dart';

/// Hands over the active account's stored secret (the mnemonic bytes as the
/// wallet keeps them), or null when there are none to hand over (a locked
/// wallet, a hardware account).
///
/// A callback rather than a value so the caller controls *when* the secret is
/// in memory: it is read at the last moment, handed to the FFI call, and
/// zeroed before the result is awaited. The pay path reads it per payment,
/// because signing needs it; the read path reads it once per unlock, to
/// derive the viewing key ([NyctisViewingKeyCache]).
typedef NyctisSeedReader = Future<Uint8List?> Function();

/// Hands over this wallet's Nyctis viewing key, or null when there is none to
/// hand over (a locked wallet, a hardware account).
///
/// The key reads every payment the account has received, so it is secret; it
/// cannot sign, which is why the read path holds it instead of the seed.
typedef NyctisViewingKeyReader = Future<rust_nyctis.NyViewingKey?> Function();

/// The three Rust calls this loader makes, behind a seam.
///
/// Every method returns the FFI future *without* awaiting it, so a caller can
/// zero the secret between issuing a call and collecting its result. A test
/// subclasses this to drive the loader without the native library.
class NyctisReplayBridge {
  const NyctisReplayBridge();

  Future<String> channelId({
    required String network,
    required String channelUivk,
    required String channelAddress,
  }) => rust_nyctis.nyctisChannelId(
    network: network,
    channelUivk: channelUivk,
    channelAddress: channelAddress,
  );

  /// The one read-side call that takes the wallet secret. See
  /// [NyctisViewingKeyCache] for when it is made.
  Future<rust_nyctis.NyViewingKey> viewingKey({
    required Uint8List mnemonic,
    required String network,
  }) => rust_nyctis.nyctisViewingKey(mnemonic: mnemonic, network: network);

  Future<rust_nyctis.NyView> replay({
    required String network,
    required String channelUivk,
    required int birthday,
    required int chainTip,
    required Uint8List vk,
    required String vkPin,
    required List<rust_nyctis.NyMessageInput> messages,
    required Uint8List viewingKey,
    required rust_nyctis.NyZecSources zecSources,
  }) => rust_nyctis.nyctisReplay(
    network: network,
    channelUivk: channelUivk,
    birthday: birthday,
    chainTip: chainTip,
    vk: vk,
    vkPin: vkPin,
    messages: messages,
    viewingKey: viewingKey,
    zecSources: zecSources,
  );
}

/// This wallet's Nyctis viewing keys, derived once per unlock and held in
/// memory only.
///
/// `nyctisViewingKey` is the one read-side call that takes the wallet secret;
/// everything after it — every refresh of every Nyctis screen — replays with
/// the viewing key instead. So the secret is read once per account per
/// unlock, not once per refresh, and the key it yields never reaches storage.
/// [nyctisViewingKeyCacheProvider] replaces the cache when the wallet locks,
/// and [clear] zeroes every key it held.
///
/// Only keys are cached. A locked wallet or a failed derivation is not: the
/// next read tries again rather than repeating a stale "locked".
class NyctisViewingKeyCache {
  NyctisViewingKeyCache({this.bridge = const NyctisReplayBridge()});

  final NyctisReplayBridge bridge;
  final _keys = <String, rust_nyctis.NyViewingKey>{};

  /// The viewing key of [accountUuid] on [network], deriving it from
  /// [readSecret] only when this unlock has not already done so.
  Future<rust_nyctis.NyViewingKey?> read({
    required String accountUuid,
    required String network,
    required NyctisSeedReader readSecret,
  }) async {
    final slot = '$network/$accountUuid';
    final cached = _keys[slot];
    if (cached != null) return cached;

    final secret = await readSecret();
    if (secret == null || secret.isEmpty) return null;
    // Issued before the secret is zeroed and awaited after it, so the
    // plaintext is live for the synchronous argument encoding only.
    final Future<rust_nyctis.NyViewingKey> call;
    try {
      call = bridge.viewingKey(mnemonic: secret, network: network);
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
    final key = await call;
    _keys[slot] = key;
    return key;
  }

  /// Zeroes and forgets every key. Called when the wallet locks.
  void clear() {
    for (final key in _keys.values) {
      key.key.fillRange(0, key.key.length, 0);
    }
    _keys.clear();
  }
}

/// The in-memory viewing-key cache, replaced — and the old one zeroed — every
/// time the wallet locks or unlocks.
final nyctisViewingKeyCacheProvider = Provider<NyctisViewingKeyCache>((ref) {
  // A widget test that stubs the view leaves `appBootstrapProvider` throwing
  // by design; the cache is still usable there, it just never sees a lock.
  try {
    ref.watch(appSecurityProvider.select((state) => state.isUnlocked));
  } catch (_) {}
  final cache = NyctisViewingKeyCache();
  ref.onDispose(cache.clear);
  return cache;
});

/// Nowhere to look for a carrying transaction.
///
/// The default because most callers of [loadNyctisView] are tests and
/// widget fixtures replaying channels that carry no ZEC claim at all, and
/// because "no source" is a *safe* default: it refuses claims rather than
/// assuming them. [loadNyctisViewFor] supplies the real pair.
const _noZecSources = rust_nyctis.NyZecSources(dbPath: '', lightwalletdUrl: '');

/// Builds the view for `config` using `client`, the wallet's own chain tip,
/// and whatever `readViewingKey` hands over.
///
/// Separate from the provider so a test can drive it with a fake client, a
/// fake bridge and a known key without standing up Riverpod, secure storage
/// or the native library.
Future<NyctisViewData> loadNyctisView({
  required NyctisConfig config,
  required NyctisIndexerClient client,
  required NyctisViewingKeyReader readViewingKey,
  int? walletChainTip,
  // Where Rust may look for the Zcash transaction behind a ZEC claim (an order
  // fill). Both may be empty — an unsynced or locked wallet has neither — and
  // the consequence is a *refused* claim, never an assumed one: the view then
  // reports `zecUnverifiable` and the card says the balance is incomplete.
  //
  // Deliberately not the indexer. It served the message; it does not also get
  // to serve the evidence about the message.
  rust_nyctis.NyZecSources zecSources = _noZecSources,
  NyctisReplayBridge bridge = const NyctisReplayBridge(),
}) async {
  if (!config.isUsable) {
    // One sentence covers three situations here — switched off, no channel on
    // this network, no indexer — which is a real wart: `config.unconfiguredReason`
    // distinguishes them and the settings screen shows it, but this screen's
    // empty state is a fixed string that tests and widgetbook both pin.
    return const NyctisViewData.notConfigured();
  }

  /// The wallet's own Nyctis address, which depends on the seed and the
  /// network and on nothing the indexer said. Read even on the failure paths
  /// so a misconfigured channel does not also take away the receive address.
  Future<NyctisIdentityData?> identityOnly() async {
    try {
      final key = await readViewingKey();
      if (key == null) return null;
      return _identityOf(key, config);
    } catch (_) {
      // An address the wallet cannot derive is not worth failing a view over.
      // The receive screen renders its own empty state for a null identity.
      return null;
    }
  }

  Future<NyctisViewData> failure(
    NyctisViewStatus status, {
    required String message,
    String? detail,
  }) async {
    return NyctisViewData(
      status: status,
      statusMessage: message,
      statusDetail: detail,
      identity: await identityOnly(),
    );
  }

  final NyctisIndexerStatus status;
  final NyctisVerifyingKey key;
  final List<NyctisMessage> messages;
  try {
    status = await client.fetchStatus();
    key = await client.fetchVerifyingKey();
    messages = await client.fetchAllMessages();
  } on NyctisIndexerException catch (error) {
    // The client's own `message` is already sentence case and user-facing,
    // and it tells a timeout from a refused connection from a 429. Replacing
    // it with one generic line is what made every failure on this path look
    // like the same failure.
    return failure(
      NyctisViewStatus.unreachable,
      message: error.message,
      detail: error.toString(),
    );
  } catch (error) {
    // Anything the client did not convert still has to land in a state the UI
    // can render, rather than escaping into the provider's generic error.
    return failure(
      NyctisViewStatus.unreachable,
      message: kNyctisUnreachableText,
      detail: 'Reading the indexer failed: $error',
    );
  }

  // The channel the indexer is actually serving has to be the channel this
  // wallet asked about. They are configured independently — an indexer URL and
  // a channel UIVK are two separate settings — and pointing at an indexer for
  // a different channel would otherwise replay someone else's messages into
  // this wallet's view and report a balance of zero with no error to show.
  // That is a settings problem, and saying "can't reach the indexer" for it
  // sends the user to look at a network that is working fine.
  final String channelId;
  try {
    channelId = await bridge.channelId(
      network: config.networkName,
      channelUivk: config.channelUivk,
      channelAddress: config.channelAddress,
    );
  } catch (error) {
    return failure(
      NyctisViewStatus.unverified,
      message:
          'This wallet cannot read the configured Nyctis channel key. '
          'Check the channel in Nyctis settings.',
      detail: 'Could not derive the channel id: $error',
    );
  }
  if (channelId != status.info.channelId) {
    return failure(
      NyctisViewStatus.unverified,
      message: kNyctisChannelMismatchText,
      detail:
          'The indexer serves channel ${status.info.channelId}, not $channelId.',
    );
  }

  // The key, against the hash the same server publishes for it. Equal hashes
  // do not make either trustworthy — both come from one indexer — but a
  // mismatch makes the key unusable, and it is the cheapest way to catch a
  // server that has been upgraded past the circuit it still advertises.
  if (!key.matchesVkHash(status.info.vkHash)) {
    return failure(
      NyctisViewStatus.unverified,
      message: kNyctisVerifyingKeyMismatchText,
      detail:
          'The indexer publishes vk_hash ${status.info.vkHash} and served a '
          'key hashing to ${key.vkHash}.',
    );
  }

  // Every message here was requested with `body=1`. A row without one is a
  // broken response, not a row to skip: dropping it shifts every later note
  // position, and the balances that come out are wrong with nothing at all to
  // show for it.
  final inputs = <rust_nyctis.NyMessageInput>[];
  for (final message in messages) {
    final body = message.body;
    if (body == null) {
      return failure(
        NyctisViewStatus.unverified,
        message:
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
        // Verbatim from the indexer: it is hashed into `msg_id` with the
        // kind and the body, so it cannot be reconstructed from the body.
        fragments: message.fragments,
        // The transaction the indexer says carried this message. A fetch key
        // only: Rust proves the fetched transaction is this message's by
        // finding the message's own fragments inside it under the channel key,
        // so a wrong value costs a refused claim, not a wrong verdict.
        txid: message.txid,
        body: body,
      ),
    );
  }

  // The chain tip, not the indexer's replay height: the wallet's own finality
  // cut-off is computed from the tip, and the anchor prune that the state root
  // folds in is a function of the height the last block closes at. Taking the
  // indexer's tip would make the wallet agree with the indexer by construction
  // rather than by verification — so it is a disclosed fallback for a wallet
  // that has not synced a tip yet, never the default.
  final walletTip = walletChainTip ?? 0;
  final tipSource = walletTip > 0
      ? NyctisChainTipSource.wallet
      : NyctisChainTipSource.indexer;
  final chainTip = walletTip > 0 ? walletTip : status.live.tip;

  final rust_nyctis.NyViewingKey? viewingKey;
  try {
    viewingKey = await readViewingKey();
  } catch (error) {
    return NyctisViewData(
      status: NyctisViewStatus.unverified,
      statusMessage:
          'This wallet could not derive its Nyctis key, so it is not showing '
          'a balance for this channel.',
      statusDetail: 'Viewing key derivation failed: $error',
    );
  }
  if (viewingKey == null) {
    return const NyctisViewData(
      status: NyctisViewStatus.notConfigured,
      statusDetail: 'The wallet is locked.',
    );
  }
  final identity = _identityOf(viewingKey, config);

  final rust_nyctis.NyView view;
  try {
    view = await bridge.replay(
      network: config.networkName,
      channelUivk: config.channelUivk,
      birthday: config.birthday,
      chainTip: chainTip,
      vk: key.vk,
      vkPin: config.vkPin,
      messages: inputs,
      viewingKey: viewingKey.key,
      zecSources: zecSources,
    );
  } catch (error) {
    return NyctisViewData(
      status: NyctisViewStatus.unverified,
      statusMessage:
          'This wallet could not replay the Nyctis channel, so it is not '
          'showing a balance for it.',
      statusDetail: 'Replay failed: $error',
      identity: identity,
    );
  }

  return nyctisViewFrom(
    view: view,
    status: status,
    identity: identity,
    chainTipSource: tipSource,
  );
}

/// Folds the replay's own diagnostics and the indexer's freshness fields into
/// one view. Everything here is a comparison between two parties that are
/// supposed to agree; nothing is taken on the indexer's word.
///
/// Public because it is the part worth testing on its own: it needs an
/// [rust_nyctis.NyView] and a [NyctisIndexerStatus] and no native library.
NyctisViewData nyctisViewFrom({
  required rust_nyctis.NyView view,
  required NyctisIndexerStatus status,
  NyctisIdentityData? identity,
  NyctisChainTipSource chainTipSource = NyctisChainTipSource.wallet,
}) {
  final assets = _assetsOf(view);
  final live = status.live;

  NyctisViewData at(
    NyctisViewStatus viewStatus, {
    String? message,
    String? detail,
  }) {
    return NyctisViewData(
      status: viewStatus,
      identity: identity,
      // An unverified view has no balance to show. Rendering the assets
      // underneath the sentence that says they could not be verified is how
      // a number nobody checked ends up being read as one that was.
      assets: viewStatus == NyctisViewStatus.unverified ? const [] : assets,
      finalityDepth: status.info.finalityDepth,
      pendingMessageCount: view.previewMessages,
      appliedMessageCount: view.applied,
      ignoredMessageCount: view.ignored,
      viewHeight: BigInt.from(view.height),
      indexerHeight: BigInt.from(live.height),
      chainTipHeight: BigInt.from(view.chainTip),
      chainTipSource: chainTipSource,
      // What the replay verified against, not what it was handed. Carried on
      // every status, including the unverified ones, because the settings
      // screen's proving-key comparison is exactly what a caller wants when
      // the replay has just refused a key.
      vkHash: view.vkHash,
      statusMessage: message,
      statusDetail: detail,
    );
  }

  // What the replay actually checked the proofs against, not what the caller
  // meant to hand it. Fetching a key and its hash from one server pins
  // nothing by itself; this is the half that is worth something — the verdict
  // and the advertised circuit have to be about the same key.
  if (!_sameRoot(view.vkHash, status.info.vkHash)) {
    return at(
      NyctisViewStatus.unverified,
      message: kNyctisVerifyingKeyMismatchText,
      detail:
          'The replay verified against vk_hash ${view.vkHash}; the indexer '
          'publishes ${status.info.vkHash}.',
    );
  }

  // A channel where the state machine refused everything it was handed is the
  // shape a wrong verifying key makes: every proof fails, every message is
  // ignored, and what is left renders as a clean, confident, empty wallet. An
  // empty channel is a different thing — it has nothing to refuse.
  if (view.applied == 0 && view.ignored > 0) {
    return at(
      NyctisViewStatus.unverified,
      message: kNyctisNothingVerifiedText,
      detail: _ignoredSummary(view),
    );
  }

  // The one symptom a withheld message leaves behind. Only comparable when
  // the indexer settled its root at the height this view closed at; when it
  // did not, the comparison is skipped rather than faked.
  final indexerStateRoot = live.stateRoot;
  if (indexerStateRoot != null && live.stateRootHeight == view.height) {
    if (!_sameRoot(indexerStateRoot, view.stateRoot)) {
      return at(
        NyctisViewStatus.unverified,
        message: kNyctisStateRootMismatchText,
        detail:
            'At height ${view.height} the indexer publishes state root '
            '$indexerStateRoot; this wallet computed ${view.stateRoot}. '
            // The roots alone say *that* the two disagree and nothing about
            // where. These four numbers split the answer in half on sight: a
            // tree root that matches puts the divergence in the folded
            // collections rather than in the notes, and counts that differ from
            // the indexer's say the two replays did not even accept the same
            // messages — which is a different bug from computing the same
            // messages differently.
            'Tree root here is ${view.treeRoot}, the indexer publishes '
            '${live.treeRoot ?? "none"}. This replay applied ${view.applied} '
            'and ignored ${view.ignored}'
            '${view.ignoredReasons.isEmpty ? "" : ": ${_reasonHistogram(view.ignoredReasons)}"}.'
            // Named separately because it is the one cause of a mismatch the
            // user can fix, and because without it a wallet that simply could
            // not reach its lightwalletd reads as an indexer that is lying.
            // A ZEC claim this wallet could not check is refused, and a
            // refused claim takes every later message that names its anchor
            // or its notes down with it — so one unchecked claim moves the
            // root, exactly as a withheld message would.
            '${view.zecUnverifiable == 0 ? "" : " ${view.zecUnverifiable} of those were ZEC claims this wallet could not check at all, because it could not fetch the Zcash transaction that carried them; that alone is enough to move the root."}',
      );
    }
    final indexerTreeRoot = live.treeRoot;
    if (indexerTreeRoot != null && !_sameRoot(indexerTreeRoot, view.treeRoot)) {
      return at(
        NyctisViewStatus.unverified,
        message: kNyctisStateRootMismatchText,
        detail:
            'At height ${view.height} the indexer publishes tree root '
            '$indexerTreeRoot; this wallet computed ${view.treeRoot}.',
      );
    }
  }

  // The indexer only served messages up to the height it has read. When the
  // view closes above that, the replay ran on a set missing every message in
  // between — which is exactly the mid-sync indexer that reports `stale:
  // false` and is nonetheless hundreds of blocks behind.
  if (live.height < view.height) {
    return at(
      NyctisViewStatus.stale,
      message: kNyctisIndexerBehindText,
      detail:
          'The indexer has read to ${live.height}; this view closes at '
          '${view.height} (status ${live.status}, syncing ${live.syncing}).',
    );
  }

  if (status.isStale) {
    return at(
      NyctisViewStatus.stale,
      message: kNyctisStaleText,
      detail: live.status,
    );
  }

  return at(NyctisViewStatus.ready);
}

/// `applied 0, ignored 343: …` — the first few reasons the state machine
/// gave, which is what tells channel spam apart from a wrong key.
String _ignoredSummary(rust_nyctis.NyView view) {
  const shown = 3;
  final reasons = view.ignoredReasons.take(shown).join('; ');
  final more = view.ignoredReasons.length > shown
      ? ' (+${view.ignoredReasons.length - shown} more)'
      : '';
  return 'applied ${view.applied}, ignored ${view.ignored}: $reasons$more';
}

bool _sameRoot(String a, String b) => a.toLowerCase() == b.toLowerCase();

/// The issuer's declared supply cap, or null when there is none to show.
/// The collection's cap, or null when there is none to show.
///
/// The Rust side reports `0` both for an uncapped collection and for one that
/// is not disclosed, and only a public asset discloses it — the same rule as
/// `issued`. A cap too large for a Dart `int` is left unshown rather than
/// truncated: a wrong cap would be presented as verified.
int? _collectionCap(rust_nyctis.NyAsset asset) {
  if (!asset.public) return null;
  final cap = asset.collectionMaxSupply;
  if (cap <= BigInt.zero || !cap.isValidInt) return null;
  return cap.toInt();
}

BigInt? _declaredMaxSupply(rust_nyctis.NyAsset asset) {
  if (!asset.public) return null;
  final max = asset.maxSupply;
  if (max == null || max <= BigInt.zero) return null;
  return max;
}

NyctisIdentityData _identityOf(
  rust_nyctis.NyViewingKey viewingKey,
  NyctisConfig config,
) {
  return NyctisIdentityData(
    address: viewingKey.address,
    networkLabel: nyctisNetworkLabel(config.networkName),
  );
}

List<NyctisAssetDetailData> _assetsOf(rust_nyctis.NyView view) {
  final assets = <NyctisAssetDetailData>[];
  for (final asset in view.assets) {
    final notes = [
      for (final note in view.notes)
        if (note.assetId == asset.assetId)
          NyctisNoteRowData(
            position: note.position,
            amount: note.amount,
            decimals: asset.decimals,
            createdHeight: BigInt.from(note.created),
            policyText: note.policy.isEmpty ? null : note.policy,
            // Carried verbatim. `view.notes` is every note this wallet has
            // ever owned, spent ones included, and the provenance is the only
            // thing that tells a receipt from the change of a payment this
            // wallet made. Dropping it here is what made a 988-unit change
            // note render as 988 units arriving.
            spent: note.spent,
            createdBy: note.createdBy,
            createdInputs: note.createdInputs,
            createdOutputs: note.createdOutputs,
            spentBy: note.spentBy,
            spentHeight: switch (note.spentHeight) {
              null => null,
              final height => BigInt.from(height),
            },
            spentInputs: note.spentInputs,
            spentOutputs: note.spentOutputs,
          ),
    ];
    assets.add(
      NyctisAssetDetailData(
        assetId: asset.assetId,
        name: asset.name.isEmpty ? null : asset.name,
        symbol: asset.symbol.isEmpty ? null : asset.symbol,
        collection: asset.collectionId.isEmpty ? null : asset.collectionId,
        // From the issuing transition's `terms`, which is hashed into
        // `asset_id` — so this is a fact about the chain, not a label. It is
        // what resolves `{index}` in a collection document's `item.image`
        // (`spec/asset-collection-v0.md` section 3.2), and that substitution is
        // safe only because of that binding.
        index: asset.index,
        // The cap bound into `collection_id` (`transition-v0.md` section 5,
        // enforced at section 6 step 6f). Step 6f lets a wallet call a
        // *capped* collection's count verified and forbids it for an uncapped
        // one, so anything short of a disclosed, non-zero cap reads as null.
        collectionMaxSupply: _collectionCap(asset),
        isPublic: asset.public,
        balance: asset.balance,
        decimals: asset.decimals,
        // Only a public asset discloses these, and the Rust side reports zero
        // for one that does not. Zero and "not disclosed" must not render the
        // same way, so a private asset carries null rather than a number the
        // protocol never made knowable.
        issuedSupply: asset.public ? asset.issued : null,
        // `null` is "not disclosed" and `Some(0)` is "uncapped"; neither is a
        // cap to print, and the row says "Not declared" for both.
        maxSupply: _declaredMaxSupply(asset),
        // Signed, on-chain, and carried no further than this: a pointer in a
        // field, not a fetch. `spec/asset-metadata-v0.md` section 3.1 makes
        // holding a note the one thing that must never trigger a request, and
        // this loader is exactly the place a "while we are here, grab the
        // logo" line would go.
        metadataUri: asset.uri.isEmpty ? null : asset.uri,
        declaredMetadata: [
          if (asset.uri.isNotEmpty)
            NyctisAssetFactData(label: 'URI', value: asset.uri),
        ],
        notes: notes,
      ),
    );
  }
  return assets;
}

/// The loader the app runs: reads the configuration, the wallet's own chain
/// tip and the active account's viewing key, then delegates to
/// [loadNyctisView].
///
/// The viewing key comes from [nyctisViewingKeyCacheProvider], which reads the
/// seed once per unlock to derive it. Nyctis needs a key at all because
/// ownership *is* decryption, but it needs a *viewing* key, not the seed: the
/// replay never signs.
Future<NyctisViewData> loadNyctisViewFor(Ref ref) async {
  // A configuration this wallet cannot even read is "not set up", never
  // "the indexer is unreachable". The two states send the user to different
  // places — one to settings, one to their network — and reporting the wrong
  // one sends them somewhere there is nothing to fix. Bootstrap can legitimately
  // fail to produce a config (locked secure storage, a first run, a test that
  // renders the screen on its own), and none of those are network faults.
  final NyctisConfig config;
  try {
    config = ref.read(nyctisConfigProvider);
  } catch (_) {
    return const NyctisViewData.notConfigured();
  }
  if (!config.isUsable) {
    return const NyctisViewData.notConfigured();
  }

  // Documented to throw on a URL that does not parse, and reached before any
  // secret is in memory precisely so that it can.
  final Uri baseUri;
  try {
    baseUri = config.indexerBaseUri;
  } on FormatException catch (error) {
    return NyctisViewData(
      status: NyctisViewStatus.notConfigured,
      statusMessage: 'Add a Nyctis indexer before loading assets.',
      statusDetail: error.message,
    );
  }

  final accounts = await ref.read(accountProvider.future);
  final uuid = accounts.activeAccountUuid;
  if (uuid == null) {
    return const NyctisViewData(
      status: NyctisViewStatus.notConfigured,
      statusMessage: 'Create or import a wallet account first.',
      statusDetail: 'No active account.',
    );
  }

  // The wallet's own tip, from its own lightwalletd sync. Zero until the
  // first sync reports one, which is the case [loadNyctisView] discloses
  // rather than silently borrowing the indexer's number for.
  final walletChainTip = ref.read(syncProvider).value?.chainTipHeight;

  // The two places a Zcash transaction can be had, for the ZEC claims that
  // carry an order fill. Both are this wallet's own: its database, which holds
  // every transaction it was a party to, and the lightwalletd it syncs against,
  // which serves any transaction on the chain. The indexer is not among them.
  //
  // Reading the path can fail on a locked or half-initialised wallet, and that
  // is not worth failing a view over — it costs the claims and the view says so.
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
    return await loadNyctisView(
      config: config,
      client: client,
      walletChainTip: walletChainTip,
      zecSources: zecSources,
      readViewingKey: () => ref
          .read(nyctisViewingKeyCacheProvider)
          .read(
            accountUuid: uuid,
            network: config.networkName,
            readSecret: () => ref
                .read(accountProvider.notifier)
                .getMnemonicBytesForAccount(uuid),
          ),
    );
  } finally {
    client.close();
  }
}

/// Counts the *kinds* of refusal rather than listing every one.
///
/// A list of ids and reasons runs off the card and buries the shape: twenty
/// refusals that are all one rule is a different bug from twenty that are
/// twenty rules, and only the histogram shows which. The id is dropped because
/// it identifies a message, and what is wanted here is the rule.
String _reasonHistogram(List<String> reasons) {
  final counts = <String, int>{};
  for (final line in reasons) {
    // Each line is `<msg_id> <reason>`; the id is 64 hex characters.
    final space = line.indexOf(' ');
    final reason = space < 0 ? line : line.substring(space + 1);
    counts[reason] = (counts[reason] ?? 0) + 1;
  }
  final ordered = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return ordered.map((e) => '${e.value}x ${e.key}').join('; ');
}
