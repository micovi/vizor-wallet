/// Which Nyctis activity items Home's recent-activity list shows.
library;

import '../../activity/nyctis_activity_message.dart';

/// [items] without the "Nyctis is settling" row.
///
/// That row counts the messages the channel carries above the finality
/// cut-off. Anyone may write to a public channel, so those are usually other
/// people's, and the wallet cannot tell which without decrypting messages it
/// has deliberately not applied. On Home — the list of what happened to *this
/// wallet* — it read as a pending payment of the user's and sat at the top
/// with a spinner whenever the channel was busy. The assets screen's notice
/// and the activity feed still carry it, where it reads as channel state.
List<NyctisActivityItem> homeNyctisActivityItems(
  Iterable<NyctisActivityItem> items,
) => [
  for (final item in items)
    if (item.kind != NyctisActivityKind.settling) item,
];
