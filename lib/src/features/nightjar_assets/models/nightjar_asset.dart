import 'nightjar_json.dart';

/// One asset as `/api/assets` serves it.
///
/// An asset is only ever *seen* until a public issuance names it, so the
/// supply fields are nullable rather than zero: "not disclosed" and "none
/// issued" are different facts and collapsing them would invent a supply.
///
/// Every u64 amount is a [BigInt] decoded from a decimal string. The indexer
/// folds `issued` into `issued_hash` as a u64, so a JSON number that rounds
/// above 2^53 would be a wrong hash with no error attached.
class NightjarAsset {
  const NightjarAsset({
    required this.assetId,
    required this.isPublic,
    required this.collectionId,
    required this.index,
    required this.issued,
    required this.maxSupply,
    required this.issuances,
    required this.firstIssued,
    required this.lastIssued,
    required this.orders,
    required this.open,
    required this.amountOpen,
    required this.firstSeen,
    required this.lastSeen,
    required this.name,
    required this.symbol,
    required this.decimals,
    required this.uri,
    required this.namedBy,
    required this.namedHeight,
    required this.namedIssuance,
  });

  final String assetId;

  /// Whether a public issuance disclosed this asset's supply. False for an
  /// asset seen only as a bare id in someone else's transition.
  final bool isPublic;

  final String? collectionId;

  /// Index within the collection. Disclosed only for a public asset.
  final int? index;

  /// Units issued so far, or `null` when the asset is not public.
  final BigInt? issued;

  /// Supply ceiling, or `null` when the asset is not public.
  final BigInt? maxSupply;

  final int issuances;
  final int? firstIssued;
  final int? lastIssued;
  final int orders;
  final int open;

  /// Units currently offered in open published notes. There is deliberately no
  /// lifetime total: a partial fill republishes the remainder as a new note,
  /// so summing published notes would double count the same units.
  final BigInt amountOpen;

  final int? firstSeen;
  final int? lastSeen;

  final String? name;
  final String? symbol;

  /// Display decimals. Presentation only — amounts stay integers everywhere.
  final int? decimals;

  final String? uri;
  final String? namedBy;
  final int? namedHeight;
  final String? namedIssuance;

  bool get hasName => (name ?? '').trim().isNotEmpty;

  /// Sentence-case fallback so a nameless asset still renders as something.
  String get displayName {
    final trimmed = name?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
    final ticker = symbol?.trim() ?? '';
    if (ticker.isNotEmpty) return ticker;
    return 'Unnamed asset';
  }

  /// Units still issuable, or `null` when the supply is not disclosed.
  BigInt? get remainingSupply {
    final issued = this.issued;
    final maxSupply = this.maxSupply;
    if (issued == null || maxSupply == null) return null;
    final remaining = maxSupply - issued;
    return remaining.isNegative ? BigInt.zero : remaining;
  }

  factory NightjarAsset.fromJson(Map<String, Object?> json) {
    return NightjarAsset(
      assetId: nightjarString(json, 'asset_id'),
      isPublic: nightjarBoolOr(json, 'public', false),
      collectionId: nightjarStringOrNull(json, 'collection_id'),
      index: nightjarIntOrNull(json, 'index'),
      issued: nightjarBigIntOrNull(json, 'issued'),
      maxSupply: nightjarBigIntOrNull(json, 'max_supply'),
      issuances: nightjarIntOr(json, 'issuances', 0),
      firstIssued: nightjarIntOrNull(json, 'first_issued'),
      lastIssued: nightjarIntOrNull(json, 'last_issued'),
      orders: nightjarIntOr(json, 'orders', 0),
      open: nightjarIntOr(json, 'open', 0),
      amountOpen: nightjarBigIntOrNull(json, 'amount_open') ?? BigInt.zero,
      firstSeen: nightjarIntOrNull(json, 'first_seen'),
      lastSeen: nightjarIntOrNull(json, 'last_seen'),
      name: nightjarStringOrNull(json, 'name'),
      symbol: nightjarStringOrNull(json, 'symbol'),
      decimals: nightjarIntOrNull(json, 'decimals'),
      uri: nightjarStringOrNull(json, 'uri'),
      namedBy: nightjarStringOrNull(json, 'named_by'),
      namedHeight: nightjarIntOrNull(json, 'named_height'),
      namedIssuance: nightjarStringOrNull(json, 'named_issuance'),
    );
  }
}
