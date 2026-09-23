/// The one metadata fetcher the app owns.
///
/// It is a plain [Provider] and not an `autoDispose` one on purpose: the
/// fetcher *is* the cache (`spec/asset-metadata-v0.md` section 3.1 — cache
/// indefinitely, keyed by `asset_id` and the document digest, and do not
/// re-fetch on a schedule). Disposing it when the assets screen closes would
/// turn "open the screen" into a fresh request every time, which is the
/// heartbeat the same section says not to produce.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/nyctis_metadata_fetcher.dart';

final nyctisMetadataFetcherProvider = Provider<NyctisAssetMetadataFetcher>(
  (ref) => NyctisAssetMetadataFetcher(),
);
