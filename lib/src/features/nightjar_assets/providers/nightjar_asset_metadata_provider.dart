/// The metadata for one asset, and the artwork the assets list and the
/// collection grid are allowed to draw.
///
/// **The obvious implementation is the forbidden one.** Fetching every held
/// asset's document on load would make logos "just be there", and it is
/// exactly what `spec/asset-metadata-v0.md` section 3.1 prohibits: it turns
/// "this wallet holds asset X" — the fact the entire system exists to hide —
/// into an HTTP request to a host of the issuer's choosing, made from the
/// user's own address, at a moment that correlates with them opening a wallet.
/// `spec/asset-collection-v0.md` section 5 repeats it for collections and
/// sharpens it: with many pieces, the *pattern* of requests would disclose
/// which ones are held.
///
/// So the gate is first and it is unconditional: no acceptance, no fetch, no
/// artwork, and nothing below this line ever reads a balance or a note count.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/nightjar_metadata_fetcher.dart';
import '../widgets/nightjar_artwork_data.dart';
import '../widgets/nightjar_asset_row_data.dart';
import 'nightjar_asset_acceptance_provider.dart';
import 'nightjar_assets_view_provider.dart';
import 'nightjar_collections_provider.dart';
import 'nightjar_metadata_fetcher_provider.dart';

/// The fetched document for one `asset_id`, whichever shape it turned out to
/// be, or null when there is none to have: the user has not accepted the
/// asset, the asset carries no `uri`, or the fetch was abandoned under section
/// 3.2.
///
/// This is the one place that decides *whether* a request is made, and it is
/// the only provider in the feature that awaits the fetcher. Everything below
/// reads its result.
///
/// The **on-chain** `index` is passed through from the view and from nowhere
/// else. `asset-collection-v0.md` section 1: `index` is hashed into `asset_id`
/// through `terms`, so a document cannot lie about which piece is which —
/// and a wallet that let the document supply it would hand back exactly the
/// property that makes one shared document safe for a hundred pieces. A member
/// whose index the wallet has not read gets no artwork rather than a guessed
/// one.
final nightjarAssetArtworkFetchProvider =
    FutureProvider.family<NightjarArtworkFetchOutcome?, String>((
      ref,
      assetId,
    ) async {
      // Section 5, and it is first for a reason: every later line in this
      // function performs or depends on a network request.
      final accepted = ref.watch(
        nightjarAssetAcceptanceProvider.select(
          (acceptance) => acceptance.isAccepted(assetId),
        ),
      );
      if (!accepted) return null;

      // Awaited rather than sampled. Reading the view's current `AsyncValue`
      // would see `loading` on the first pass and answer "no uri, no
      // metadata" for an asset that does have one — and the fetcher's cache
      // means the recompute after the view arrives costs nothing.
      final NightjarAssetDetailData? asset;
      try {
        final view = await ref.watch(nightjarAssetsViewProvider.future);
        asset = view.assetById(assetId);
      } catch (_) {
        // No view is "nothing to decorate", never a metadata failure.
        return null;
      }
      final uri = asset?.metadataUri;
      if (uri == null || uri.isEmpty) return null;

      final fetcher = ref.watch(nightjarMetadataFetcherProvider);
      return fetcher.fetchArtwork(
        assetId: assetId,
        uri: uri,
        index: asset?.index,
      );
    });

/// The per-asset document for one `asset_id`, or null.
///
/// `null` covers "not accepted", "no uri", "abandoned" and "the document was a
/// collection document" because the metadata card treats them the same way —
/// the asset renders with its signed name and symbol and no description — and
/// because distinguishing "the host is down" from "the user has not accepted"
/// in the return type would invite a caller to retry the first.
final nightjarAssetMetadataProvider =
    FutureProvider.family<NightjarAssetMetadataView?, String>((
      ref,
      assetId,
    ) async {
      final outcome = await ref.watch(
        nightjarAssetArtworkFetchProvider(assetId).future,
      );
      return outcome?.assetView;
    });

/// Everything a tile needs to draw one piece, including *why* it is empty.
///
/// The five states are in [NightjarArtworkStatus] and the reason they are five
/// rather than two is there. The acceptance gate is repeated here rather than
/// delegated: it is the rule the whole feature hangs on, and a second copy of
/// it on a path to a picture is cheaper than the day somebody simplifies the
/// first one.
final nightjarAssetArtworkProvider =
    Provider.family<NightjarArtworkData, String>((ref, assetId) {
      final accepted = ref.watch(
        nightjarAssetAcceptanceProvider.select(
          (acceptance) => acceptance.isAccepted(assetId),
        ),
      );
      if (!accepted) return const NightjarArtworkData.notAccepted();

      final async = ref.watch(nightjarAssetArtworkFetchProvider(assetId));
      return async.when(
        // An error out of the fetch provider is not the same as a refusal by
        // it: the fetcher answers every failure with an abandonment, so
        // reaching here means the *view* threw. Pending is the honest state —
        // nothing was asked of any host.
        error: (_, _) => const NightjarArtworkData.pending(),
        loading: () => const NightjarArtworkData.pending(),
        data: (outcome) => outcome == null
            // Accepted, but there is nothing to fetch: no `uri`, or the view
            // does not carry this asset. Not a refusal by a host.
            ? const NightjarArtworkData.pending()
            : NightjarArtworkData.fromOutcome(outcome),
      );
    });

/// Artwork bytes for one accepted asset, or null.
///
/// This is the shape a *grid* needs, and the reason it exists beside the map
/// below. Watching it subscribes to exactly one asset: a tile that is built
/// asks for its own picture, one document arriving rebuilds one tile, and a
/// tile that is never built never asks. Watching the map instead would make
/// every arrival rebuild every tile and would mean scrolling a hundred-piece
/// collection was a hundred full-screen rebuilds.
final nightjarAssetLogoProvider = Provider.family<Uint8List?, String>((
  ref,
  assetId,
) {
  return ref.watch(nightjarAssetArtworkProvider(assetId)).bytes;
});

/// Logo bytes for every accepted asset **that the flat list draws**, keyed by
/// `asset_id`.
///
/// Iterating the *accepted* set rather than the held set is the original
/// point: the assets screen hands this to the row mapper, and if it were
/// built from `view.assets` instead, opening the screen would fetch one
/// document per asset the wallet holds. That is the section 3.1 leak, and it
/// would look like a nicer screen right up until someone read the request log.
///
/// Grouped collection members are excluded, and that exclusion is not
/// cosmetic. This provider watches one `FutureProvider` per id in it, and
/// watching is what starts the fetch — so before the exclusion, accepting a
/// hundred-piece collection meant a hundred HTTP requests and a hundred
/// images resident the moment any screen watching this was built, on every
/// launch, whether or not the user ever opened the collection. Members are
/// reached through [nightjarAssetArtworkProvider] from the tile that draws
/// them instead, so the work is bounded by what is on screen.
///
/// The shared collection document of `asset-collection-v0.md` changes the
/// arithmetic but not this rule: it would make those hundred requests one
/// document plus a hundred images, which is still a hundred requests and still
/// one per held piece. Section 5's "**MUST NOT** fetch because it holds a
/// member" is unaffected by the saving.
///
/// That is *stricter* than `spec/asset-metadata-v0.md` section 3.1, which
/// permits acceptance alone to trigger the fetch, and it is the direction the
/// spec is strict in: fewer requests, each still gated on an acceptance the
/// user made. What it costs is that the request now also correlates with
/// opening the collection rather than only with opening the wallet, and the
/// fetcher's process-lifetime cache keeps that to at most one request per
/// viewed piece per launch.
final nightjarAssetLogosProvider = Provider<Map<String, Uint8List>>((ref) {
  final acceptance = ref.watch(nightjarAssetAcceptanceProvider);
  final grouped = ref.watch(nightjarGroupedMemberIdsProvider);
  final logos = <String, Uint8List>{};
  for (final entry in acceptance.accepted) {
    if (grouped.contains(entry.assetId)) continue;
    final bytes = ref.watch(nightjarAssetArtworkProvider(entry.assetId)).bytes;
    if (bytes != null) logos[entry.assetId] = bytes;
  }
  return logos;
});

/// Whether [asset] is one the user could accept: it carries a `uri` this
/// wallet would resolve. An asset with no document has nothing to accept and
/// the detail screen says nothing rather than offering an empty choice.
bool nightjarAssetHasMetadataPointer(NightjarAssetDetailData? asset) {
  final uri = asset?.metadataUri;
  return uri != null && uri.trim().isNotEmpty;
}
