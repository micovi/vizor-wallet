/// Which assets the user has explicitly accepted, and what they looked like
/// at the moment of acceptance.
///
/// Section 5 of `spec/asset-metadata-v0.md` is the reason this exists at all:
///
/// * a wallet **MUST NOT** display a logo for an asset the user has not
///   explicitly accepted — a default-on logo is the impersonation of section
///   1.1 delivered at no cost to the attacker;
/// * acceptance is **per `asset_id`**, never per name, symbol or issuer;
/// * a wallet **SHOULD** warn, at the moment of acceptance, when the name or
///   symbol matches one already accepted for a different `asset_id`.
///
/// That last rule is why this stores the name and symbol beside the id rather
/// than just the id. The collision to catch is against what the user *has
/// already accepted*, and an asset accepted six months ago may not be in the
/// channel view today — recomputing the names from the current view would
/// quietly stop warning about exactly the assets a user has lived with longest.
library;

import 'dart:convert';

/// One accepted asset, as it read when the user accepted it.
class NyctisAcceptedAsset {
  const NyctisAcceptedAsset({required this.assetId, this.name, this.symbol});

  /// The only true identifier. Hex, lowercase as the indexer serves it.
  final String assetId;

  /// The signed `name` at the time of acceptance, or null when the asset had
  /// none. Never authoritative — kept only to detect the section 5 collision.
  final String? name;

  /// The signed `symbol` at the time of acceptance, or null.
  final String? symbol;

  Map<String, Object?> toJson() => {
    'id': assetId,
    if (name != null) 'name': name,
    if (symbol != null) 'symbol': symbol,
  };

  static NyctisAcceptedAsset? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) return null;
    final name = json['name'];
    final symbol = json['symbol'];
    return NyctisAcceptedAsset(
      assetId: id.trim(),
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
      symbol: symbol is String && symbol.trim().isNotEmpty
          ? symbol.trim()
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NyctisAcceptedAsset &&
      other.assetId == assetId &&
      other.name == name &&
      other.symbol == symbol;

  @override
  int get hashCode => Object.hash(assetId, name, symbol);
}

/// How an asset the user is about to accept collides with one already
/// accepted. Section 1.1: this is the expected case, not the attack.
class NyctisNameCollision {
  const NyctisNameCollision({
    required this.existing,
    required this.matchesName,
    required this.matchesSymbol,
  });

  /// The asset already accepted under a *different* id.
  final NyctisAcceptedAsset existing;

  final bool matchesName;
  final bool matchesSymbol;
}

/// The persisted set of accepted assets.
class NyctisAssetAcceptance {
  const NyctisAssetAcceptance(this.accepted);

  const NyctisAssetAcceptance.empty() : accepted = const [];

  /// In the order they were accepted. Small by construction: a user accepts
  /// the handful of assets they care about, not a channel's worth.
  final List<NyctisAcceptedAsset> accepted;

  bool isAccepted(String assetId) {
    for (final entry in accepted) {
      if (entry.assetId == assetId) return true;
    }
    return false;
  }

  NyctisAcceptedAsset? entryFor(String assetId) {
    for (final entry in accepted) {
      if (entry.assetId == assetId) return entry;
    }
    return null;
  }

  /// Every already-accepted asset whose `name` or `symbol` matches the one
  /// being considered, under a different `asset_id`.
  ///
  /// Matching is case-insensitive and whitespace-trimmed, which is wider than
  /// the spec's wording and deliberately so: `NYCTIS` and `Nyctis` are the
  /// same imitation, and a warning that only fires on an exact byte match is a
  /// warning an attacker turns off by holding shift.
  List<NyctisNameCollision> collisionsWith({
    required String assetId,
    String? name,
    String? symbol,
  }) {
    final candidateName = _fold(name);
    final candidateSymbol = _fold(symbol);
    if (candidateName == null && candidateSymbol == null) return const [];
    final collisions = <NyctisNameCollision>[];
    for (final entry in accepted) {
      if (entry.assetId == assetId) continue;
      final matchesName =
          candidateName != null && _fold(entry.name) == candidateName;
      final matchesSymbol =
          candidateSymbol != null && _fold(entry.symbol) == candidateSymbol;
      if (!matchesName && !matchesSymbol) continue;
      collisions.add(
        NyctisNameCollision(
          existing: entry,
          matchesName: matchesName,
          matchesSymbol: matchesSymbol,
        ),
      );
    }
    return collisions;
  }

  /// Adds [entry], replacing any earlier acceptance of the same `asset_id`.
  NyctisAssetAcceptance accepting(NyctisAcceptedAsset entry) {
    return NyctisAssetAcceptance([
      for (final existing in accepted)
        if (existing.assetId != entry.assetId) existing,
      entry,
    ]);
  }

  NyctisAssetAcceptance without(String assetId) {
    return NyctisAssetAcceptance([
      for (final existing in accepted)
        if (existing.assetId != assetId) existing,
    ]);
  }

  /// The stored form. A list, not a map, because the order the user accepted
  /// things in is the order the collision warning should name them in.
  String encode() => jsonEncode([for (final entry in accepted) entry.toJson()]);

  /// Reads the stored form. Anything unreadable comes back empty rather than
  /// throwing: a corrupt acceptance list must cost decoration, not startup —
  /// and "empty" is the safe direction, since it shows no logo at all.
  static NyctisAssetAcceptance decode(String? stored) {
    final raw = stored?.trim() ?? '';
    if (raw.isEmpty) return const NyctisAssetAcceptance.empty();
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const NyctisAssetAcceptance.empty();
    }
    if (decoded is! List) return const NyctisAssetAcceptance.empty();
    final entries = <NyctisAcceptedAsset>[];
    final seen = <String>{};
    for (final item in decoded) {
      final entry = NyctisAcceptedAsset.fromJson(item);
      if (entry == null) continue;
      if (!seen.add(entry.assetId)) continue;
      entries.add(entry);
    }
    return NyctisAssetAcceptance(entries);
  }

  static String? _fold(String? value) {
    final trimmed = value?.trim().toLowerCase() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}
