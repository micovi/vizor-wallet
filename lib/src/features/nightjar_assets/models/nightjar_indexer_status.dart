import 'nightjar_json.dart';

/// `GET /api/status` — what the indexer is, and how far behind it is.
class NightjarIndexerStatus {
  const NightjarIndexerStatus({
    required this.info,
    required this.live,
    required this.counts,
  });

  final NightjarIndexerInfo info;
  final NightjarIndexerLive live;
  final NightjarIndexerCounts counts;

  /// The one field a client must check before trusting anything else: a stale
  /// index is serving a view of the channel that has stopped moving, and every
  /// balance derived from it is as old as `live.lastSyncAt`.
  bool get isStale => live.stale;

  /// Last height whose state root is settled. Assets below this are safe to
  /// show; anything above it can still be reorged away.
  int get canonicalHeight => live.canonicalHeight;

  factory NightjarIndexerStatus.fromJson(Map<String, Object?> json) {
    return NightjarIndexerStatus(
      info: NightjarIndexerInfo.fromJson(
        nightjarObject(json['info'], 'status has no info'),
      ),
      live: NightjarIndexerLive.fromJson(
        nightjarObject(json['live'], 'status has no live section'),
      ),
      counts: NightjarIndexerCounts.fromJson(
        nightjarObject(json['counts'], 'status has no counts'),
      ),
    );
  }
}

/// The static half of `/api/status`: identity of the channel and the circuit.
class NightjarIndexerInfo {
  const NightjarIndexerInfo({
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

  factory NightjarIndexerInfo.fromJson(Map<String, Object?> json) {
    return NightjarIndexerInfo(
      network: nightjarString(json, 'network'),
      channelId: nightjarString(json, 'channel_id'),
      uivk: nightjarString(json, 'uivk'),
      birthday: nightjarInt(json, 'birthday'),
      circuit: nightjarString(json, 'circuit'),
      circuitVersion: nightjarInt(json, 'circuit_version'),
      protocolVersion: nightjarIntOr(json, 'protocol_version', 0),
      vkHash: nightjarString(json, 'vk_hash'),
      anchorWindow: nightjarInt(json, 'anchor_window'),
      finalityDepth: nightjarInt(json, 'finality_depth'),
      version: nightjarString(json, 'version'),
    );
  }
}

/// The moving half of `/api/status`: how far the index has followed the chain.
class NightjarIndexerLive {
  const NightjarIndexerLive({
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

  factory NightjarIndexerLive.fromJson(Map<String, Object?> json) {
    return NightjarIndexerLive(
      status: nightjarStringOrNull(json, 'status') ?? 'unknown',
      stale: nightjarBoolOr(json, 'stale', true),
      tip: nightjarIntOr(json, 'tip', 0),
      height: nightjarIntOr(json, 'height', 0),
      canonicalHeight: nightjarIntOr(json, 'canonical_height', 0),
      stateRoot: nightjarStringOrNull(json, 'state_root'),
      stateRootHeight: nightjarIntOr(json, 'state_root_height', 0),
      treeRoot: nightjarStringOrNull(json, 'tree_root'),
      synced: nightjarBoolOr(json, 'synced', false),
      syncing: nightjarBoolOr(json, 'syncing', false),
      lastSyncAt: nightjarIntOrNull(json, 'last_sync_at'),
      lastError: nightjarStringOrNull(json, 'last_error'),
      notes: nightjarIntOr(json, 'notes', 0),
      nullifiers: nightjarIntOr(json, 'nullifiers', 0),
      anchors: nightjarIntOr(json, 'anchors', 0),
      rollbacks: nightjarIntOr(json, 'rollbacks', 0),
      deepReorgs: nightjarIntOr(json, 'deep_reorgs', 0),
    );
  }
}

/// Row counts from `/api/status`. Only the figures the wallet has a use for are
/// typed; [raw] keeps the rest for diagnostics without a model change per
/// indexer release.
class NightjarIndexerCounts {
  const NightjarIndexerCounts({
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

  factory NightjarIndexerCounts.fromJson(Map<String, Object?> json) {
    return NightjarIndexerCounts(
      blocks: nightjarIntOr(json, 'blocks', 0),
      memos: nightjarIntOr(json, 'memos', 0),
      messages: nightjarIntOr(json, 'messages', 0),
      applied: nightjarIntOr(json, 'applied', 0),
      assetsSeen: nightjarIntOr(json, 'assets_seen', 0),
      assetsPublic: nightjarIntOr(json, 'assets_public', 0),
      notes: nightjarIntOr(json, 'notes', 0),
      nullifiers: nightjarIntOr(json, 'nullifiers', 0),
      lastHeight: nightjarIntOr(json, 'last_height', 0),
      lastCanonicalHeight: nightjarIntOr(json, 'last_canonical_height', 0),
      raw: Map<String, Object?>.unmodifiable(json),
    );
  }
}
