import 'nyctis_json.dart';

/// `GET /api/status` — what the indexer is, and how far behind it is.
class NyctisIndexerStatus {
  const NyctisIndexerStatus({
    required this.info,
    required this.live,
    required this.counts,
  });

  final NyctisIndexerInfo info;
  final NyctisIndexerLive live;
  final NyctisIndexerCounts counts;

  /// The one field a client must check before trusting anything else: a stale
  /// index is serving a view of the channel that has stopped moving, and every
  /// balance derived from it is as old as `live.lastSyncAt`.
  bool get isStale => live.stale;

  /// Last height whose state root is settled. Assets below this are safe to
  /// show; anything above it can still be reorged away.
  int get canonicalHeight => live.canonicalHeight;

  factory NyctisIndexerStatus.fromJson(Map<String, Object?> json) {
    return NyctisIndexerStatus(
      info: NyctisIndexerInfo.fromJson(
        nyctisObject(json['info'], 'status has no info'),
      ),
      live: NyctisIndexerLive.fromJson(
        nyctisObject(json['live'], 'status has no live section'),
      ),
      counts: NyctisIndexerCounts.fromJson(
        nyctisObject(json['counts'], 'status has no counts'),
      ),
    );
  }
}

/// The static half of `/api/status`: identity of the channel and the circuit.
class NyctisIndexerInfo {
  const NyctisIndexerInfo({
    required this.network,
    required this.channelId,
    required this.uivk,
    required this.birthday,
    required this.circuit,
    required this.circuitVersion,
    required this.protocolVersion,
    required this.vkHash,
    required this.anchorWindow,
    required this.finalityDepth,
    required this.version,
  });

  final String network;
  final String channelId;

  /// The channel's public incoming viewing key. Compare against the configured
  /// one before replaying; an indexer for a different channel is not an error
  /// the replay can detect on its own.
  final String uivk;

  final int birthday;

  /// Circuit fingerprint (`constraints=…;instances=…;vk_hash=…`). A
  /// fingerprint, not an identity: two independent ceremonies produce the same
  /// one.
  final String circuit;

  final int circuitVersion;
  final int protocolVersion;

  /// BLAKE2b-256 over the compressed verifying-key bytes.
  final String vkHash;

  final int anchorWindow;
  final int finalityDepth;
  final String version;

  factory NyctisIndexerInfo.fromJson(Map<String, Object?> json) {
    return NyctisIndexerInfo(
      network: nyctisString(json, 'network'),
      channelId: nyctisString(json, 'channel_id'),
      uivk: nyctisString(json, 'uivk'),
      birthday: nyctisInt(json, 'birthday'),
      circuit: nyctisString(json, 'circuit'),
      circuitVersion: nyctisInt(json, 'circuit_version'),
      protocolVersion: nyctisIntOr(json, 'protocol_version', 0),
      vkHash: nyctisString(json, 'vk_hash'),
      anchorWindow: nyctisInt(json, 'anchor_window'),
      finalityDepth: nyctisInt(json, 'finality_depth'),
      version: nyctisString(json, 'version'),
    );
  }
}

/// The moving half of `/api/status`: how far the index has followed the chain.
class NyctisIndexerLive {
  const NyctisIndexerLive({
    required this.status,
    required this.stale,
    required this.tip,
    required this.height,
    required this.canonicalHeight,
    required this.stateRoot,
    required this.stateRootHeight,
    required this.treeRoot,
    required this.synced,
    required this.syncing,
    required this.lastSyncAt,
    required this.lastError,
    required this.notes,
    required this.nullifiers,
    required this.anchors,
    required this.rollbacks,
    required this.deepReorgs,
  });

  /// `synced`, `syncing`, `stopped`, and friends, verbatim from the indexer.
  final String status;

  /// Whether the index has stopped following the chain. Check this first.
  final bool stale;

  /// Chain tip the indexer can see.
  final int tip;

  /// Preview height — includes blocks shallower than the finality depth.
  final int height;

  /// Height the settled `stateRoot` belongs to.
  final int canonicalHeight;

  final String? stateRoot;
  final int stateRootHeight;
  final String? treeRoot;
  final bool synced;
  final bool syncing;

  /// Unix seconds of the last successful sync pass, or `null` if it has never
  /// completed one.
  final int? lastSyncAt;

  final String? lastError;
  final int notes;
  final int nullifiers;
  final int anchors;
  final int rollbacks;
  final int deepReorgs;

  factory NyctisIndexerLive.fromJson(Map<String, Object?> json) {
    return NyctisIndexerLive(
      status: nyctisStringOrNull(json, 'status') ?? 'unknown',
      stale: nyctisBoolOr(json, 'stale', true),
      tip: nyctisIntOr(json, 'tip', 0),
      height: nyctisIntOr(json, 'height', 0),
      canonicalHeight: nyctisIntOr(json, 'canonical_height', 0),
      stateRoot: nyctisStringOrNull(json, 'state_root'),
      stateRootHeight: nyctisIntOr(json, 'state_root_height', 0),
      treeRoot: nyctisStringOrNull(json, 'tree_root'),
      synced: nyctisBoolOr(json, 'synced', false),
      syncing: nyctisBoolOr(json, 'syncing', false),
      lastSyncAt: nyctisIntOrNull(json, 'last_sync_at'),
      lastError: nyctisStringOrNull(json, 'last_error'),
      notes: nyctisIntOr(json, 'notes', 0),
      nullifiers: nyctisIntOr(json, 'nullifiers', 0),
      anchors: nyctisIntOr(json, 'anchors', 0),
      rollbacks: nyctisIntOr(json, 'rollbacks', 0),
      deepReorgs: nyctisIntOr(json, 'deep_reorgs', 0),
    );
  }
}

/// Row counts from `/api/status`. Only the figures the wallet has a use for are
/// typed; [raw] keeps the rest for diagnostics without a model change per
/// indexer release.
class NyctisIndexerCounts {
  const NyctisIndexerCounts({
    required this.blocks,
    required this.memos,
    required this.messages,
    required this.applied,
    required this.assetsSeen,
    required this.assetsPublic,
    required this.notes,
    required this.nullifiers,
    required this.lastHeight,
    required this.lastCanonicalHeight,
    required this.raw,
  });

  final int blocks;
  final int memos;
  final int messages;
  final int applied;
  final int assetsSeen;
  final int assetsPublic;
  final int notes;
  final int nullifiers;
  final int lastHeight;
  final int lastCanonicalHeight;
  final Map<String, Object?> raw;

  factory NyctisIndexerCounts.fromJson(Map<String, Object?> json) {
    return NyctisIndexerCounts(
      blocks: nyctisIntOr(json, 'blocks', 0),
      memos: nyctisIntOr(json, 'memos', 0),
      messages: nyctisIntOr(json, 'messages', 0),
      applied: nyctisIntOr(json, 'applied', 0),
      assetsSeen: nyctisIntOr(json, 'assets_seen', 0),
      assetsPublic: nyctisIntOr(json, 'assets_public', 0),
      notes: nyctisIntOr(json, 'notes', 0),
      nullifiers: nyctisIntOr(json, 'nullifiers', 0),
      lastHeight: nyctisIntOr(json, 'last_height', 0),
      lastCanonicalHeight: nyctisIntOr(json, 'last_canonical_height', 0),
      raw: Map<String, Object?>.unmodifiable(json),
    );
  }
}
