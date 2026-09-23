import 'nyctis_json.dart';

typedef NyctisItemDecoder<T> = T Function(Map<String, Object?> json);

/// One page of a Nyctis indexer listing.
///
/// Listings are newest-first and `limit` is clamped server-side, so the
/// `limit` here is what the server actually used, not what was asked for.
///
/// [hasMore] is derived from [nextCursor] rather than read from the response's
/// `has_more`. The indexer's own contract is `has_more == (next_cursor !=
/// null)`, and deriving it means a page that claims more rows without a usable
/// cursor ends the walk instead of looping forever on one boundary.
class NyctisPage<T> {
  const NyctisPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.nextCursor,
  });

  final List<T> items;

  /// Rows matching the query's filters, ignoring the page cursor. The same
  /// number on every page of one walk, so `sum(count) == total` is the
  /// completeness check at the end — made by
  /// `NyctisIndexerClient.fetchAllMessages`, because a replay over a walk
  /// that quietly ended early produces wrong balances rather than an error.
  final int total;

  final int limit;

  /// Pass back as `before=` for the next page. `null` exactly at the end.
  final int? nextCursor;

  int get count => items.length;

  bool get hasMore => nextCursor != null;

  bool get isEmpty => items.isEmpty;

  static NyctisPage<T> fromJson<T>(
    Map<String, Object?> json,
    NyctisItemDecoder<T> decodeItem,
  ) {
    final rawItems = nyctisList(json['items'], 'page has no items');
    return NyctisPage<T>(
      items: List<T>.unmodifiable([
        for (final item in rawItems) decodeItem(nyctisObject(item, 'item')),
      ]),
      total: nyctisIntOr(json, 'total', rawItems.length),
      limit: nyctisIntOr(json, 'limit', rawItems.length),
      nextCursor: nyctisIntOrNull(json, 'next_cursor'),
    );
  }

  NyctisPage<R> map<R>(R Function(T item) transform) => NyctisPage<R>(
    items: List<R>.unmodifiable(items.map(transform)),
    total: total,
    limit: limit,
    nextCursor: nextCursor,
  );
}
