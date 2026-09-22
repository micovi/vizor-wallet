// ignore_for_file: depend_on_referenced_packages
// widgetbook is dev-only; see `widgetbook.dart` for the boundary.

/// Widgetbook use cases for every presentational Nightjar widget.
///
/// Each one is a fixture built from the plain view models, so the gallery
/// never touches a provider, the Rust bridge, or the network. The states
/// here are the ones that are hard to reach by hand: an unnamed asset, a
/// private asset with no supply figure, an unreachable indexer, and a
/// receive waiting out the finality depth.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../src/core/theme/app_theme.dart';
import '../src/features/nightjar_assets/models/nightjar_asset_acceptance.dart';
import '../src/features/nightjar_assets/screens/nightjar_asset_detail_screen.dart';
import '../src/features/nightjar_assets/screens/nightjar_receive_screen.dart';
import '../src/features/nightjar_assets/services/nightjar_metadata_fetcher.dart';
import '../src/features/nightjar_assets/widgets/nightjar_artwork_data.dart';
import '../src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import '../src/features/nightjar_assets/widgets/nightjar_asset_row_mapper.dart';
import '../src/features/nightjar_assets/widgets/nightjar_assets_feed.dart';
import '../src/features/nightjar_assets/widgets/nightjar_collection_acceptance_card.dart';
import '../src/features/nightjar_assets/widgets/nightjar_collection_data.dart';
import '../src/features/nightjar_assets/widgets/nightjar_collection_grid.dart';
import '../src/features/nightjar_assets/widgets/nightjar_collection_mapper.dart';
import '../src/features/nightjar_assets/widgets/nightjar_collection_sections.dart';
import '../src/features/nightjar_assets/widgets/nightjar_facts_card.dart';
import '../src/features/nightjar_assets/widgets/nightjar_receive_panel.dart';

const _namedAssetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
const _unnamedAssetId =
    '0f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f4030201009f8e7d6c5b4a';
const _privateAssetId =
    '77aa11bb22cc33dd44ee55ff6600778899aabbccddeeff001122334455667788';

const _nightjarAddress =
    'njreg1qqxvz8k3m7ph2j6ldu4cwesa9r0tg5y7n2q4v8xz3m6k9p2r5t8w1c4f7h0j3l6';

NightjarAssetDetailData _namedAsset() => NightjarAssetDetailData(
  assetId: _namedAssetId,
  name: 'Harbour credit',
  symbol: 'HBC',
  collection: 'Harbour',
  isPublic: true,
  balance: BigInt.from(1250000),
  decimals: 6,
  issuedSupply: BigInt.from(500000000000),
  maxSupply: BigInt.from(1000000000000),
  declaredMetadata: const [
    NightjarAssetFactData(label: 'Issuer note', value: 'Port of call credit'),
    NightjarAssetFactData(label: 'Declared at height', value: '1,204'),
  ],
  notes: [
    NightjarNoteRowData(
      position: BigInt.from(41),
      amount: BigInt.from(1000000),
      decimals: 6,
      createdHeight: BigInt.from(1240),
    ),
    NightjarNoteRowData(
      position: BigInt.from(58),
      amount: BigInt.from(250000),
      decimals: 6,
      createdHeight: BigInt.from(1281),
      policyText: 'Spendable after height 1,300',
    ),
  ],
);

NightjarAssetDetailData _unnamedAsset() => NightjarAssetDetailData(
  assetId: _unnamedAssetId,
  isPublic: true,
  balance: BigInt.from(3),
  decimals: 0,
  issuedSupply: BigInt.from(21),
  notes: [
    NightjarNoteRowData(
      position: BigInt.from(7),
      amount: BigInt.from(3),
      decimals: 0,
      createdHeight: BigInt.from(1199),
    ),
  ],
);

NightjarAssetDetailData _privateAsset() => NightjarAssetDetailData(
  assetId: _privateAssetId,
  name: 'Crew pass',
  balance: BigInt.from(1),
  decimals: 0,
  notes: [
    NightjarNoteRowData(
      position: BigInt.from(2),
      amount: BigInt.from(1),
      decimals: 0,
      createdHeight: BigInt.from(1010),
      policyText: 'Non-transferable',
    ),
  ],
);

NightjarViewData _readyView({int pendingMessageCount = 1}) => NightjarViewData(
  status: NightjarViewStatus.ready,
  identity: const NightjarIdentityData(
    address: _nightjarAddress,
    networkLabel: 'Regtest',
  ),
  assets: [_namedAsset(), _unnamedAsset(), _privateAsset()],
  pendingMessageCount: pendingMessageCount,
  appliedMessageCount: 6,
  ignoredMessageCount: 343,
  viewHeight: BigInt.from(1280),
  indexerHeight: BigInt.from(1290),
  chainTipHeight: BigInt.from(1290),
);

List<NightjarAssetsSectionData> _sections() {
  return buildNightjarAssetSections(
    buildNightjarAssetRows(assets: _readyView().assets, onAssetTap: (_) {}),
  );
}

Widget _stage(BuildContext context, Widget child, {double width = 440}) {
  return ColoredBox(
    color: context.colors.background.window,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
}

Widget buildNightjarAssetsFeedUseCase(BuildContext context) {
  return _stage(
    context,
    NightjarAssetsFeed(sections: _sections(), rowKeyPrefix: 'widgetbook'),
  );
}

Widget buildNightjarAssetsFeedLoadingUseCase(BuildContext context) {
  return _stage(
    context,
    const NightjarAssetsFeed(sections: [], isLoading: true),
  );
}

Widget buildNightjarAssetsFeedEmptyUseCase(BuildContext context) {
  return _stage(
    context,
    const NightjarAssetsFeed(sections: [], emptyText: kNightjarEmptyText),
  );
}

Widget buildNightjarAssetsFeedNotConfiguredUseCase(BuildContext context) {
  return _stage(
    context,
    const NightjarAssetsFeed(
      sections: [],
      errorText: kNightjarNotConfiguredText,
      errorTone: NightjarMessageTone.neutral,
    ),
  );
}

Widget buildNightjarAssetsFeedUnreachableUseCase(BuildContext context) {
  return _stage(
    context,
    const NightjarAssetsFeed(
      sections: [],
      errorText: kNightjarUnreachableText,
      errorTone: NightjarMessageTone.error,
    ),
  );
}

Widget buildNightjarAssetsFeedStaleUseCase(BuildContext context) {
  return _stage(
    context,
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NightjarMessageCard(
          text: kNightjarStaleText,
          tone: kNightjarNoticeTone,
        ),
        const SizedBox(height: AppSpacing.md),
        NightjarAssetsFeed(sections: _sections(), cardWidth: null),
      ],
    ),
  );
}

Widget buildNightjarPendingNoticeUseCase(BuildContext context) {
  return _stage(
    context,
    NightjarMessageCard(
      text:
          nightjarPendingMessagesText(
            pendingMessageCount: 2,
            finalityDepth: kNightjarDefaultFinalityDepth,
          ) ??
          '',
      tone: kNightjarNoticeTone,
    ),
  );
}

Widget buildNightjarAssetDetailUseCase(BuildContext context) {
  final view = _readyView();
  return _stage(
    context,
    NightjarAssetDetailBody(
      assetId: _namedAssetId,
      view: view,
      asset: view.assetById(_namedAssetId),
    ),
  );
}

Widget buildNightjarUnnamedAssetDetailUseCase(BuildContext context) {
  final view = _readyView(pendingMessageCount: 0);
  return _stage(
    context,
    NightjarAssetDetailBody(
      assetId: _unnamedAssetId,
      view: view,
      asset: view.assetById(_unnamedAssetId),
    ),
  );
}

Widget buildNightjarPrivateAssetDetailUseCase(BuildContext context) {
  final view = _readyView(pendingMessageCount: 0);
  return _stage(
    context,
    NightjarAssetDetailBody(
      assetId: _privateAssetId,
      view: view,
      asset: view.assetById(_privateAssetId),
    ),
  );
}

Widget buildNightjarFactsCardUseCase(BuildContext context) {
  final asset = _namedAsset();
  return _stage(
    context,
    NightjarFactsCard(
      title: 'Identity',
      facts: buildNightjarAssetIdentityFacts(asset),
      footnote: kNightjarSupplyPrivacyNote,
    ),
  );
}

Widget buildNightjarReceiveUseCase(BuildContext context) {
  return _stage(context, NightjarReceiveBody(view: _readyView()));
}

Widget buildNightjarReceiveNotConfiguredUseCase(BuildContext context) {
  return _stage(
    context,
    const NightjarReceiveBody(view: NightjarViewData.notConfigured()),
  );
}

Widget buildNightjarReceivePanelUseCase(BuildContext context) {
  return _stage(
    context,
    const NightjarReceivePanel(
      address: _nightjarAddress,
      networkLabel: 'Regtest',
    ),
  );
}

// ---------------------------------------------------------------------------
// Collections and unique items
// ---------------------------------------------------------------------------

const _collectionId =
    'c0113c710490aaaabbbbccccddddeeeeffff00001111222233334444555566667';

NightjarAssetDetailData _piece(int i, {bool owned = false, int? index}) =>
    NightjarAssetDetailData(
      assetId: 'pon${i.toString().padLeft(61, '0')}',
      name: 'Phases of one night #$i',
      symbol: 'PON',
      collection: _collectionId,
      index: index,
      isPublic: true,
      balance: owned ? BigInt.one : BigInt.zero,
      decimals: 0,
      issuedSupply: BigInt.one,
      maxSupply: BigInt.one,
      metadataUri:
          'https://raw.githubusercontent.invalid/pon/$i.json'
          '#b2=Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0',
    );

List<NightjarAssetDetailData> _pieces({int count = 100}) => [
  for (var i = 0; i < count; i++) _piece(i, owned: i < 3, index: i),
];

NightjarCollectionData _collection({int count = 100}) =>
    groupNightjarCollections(_pieces(count: count)).collections.single;

/// The assets list as the devnet actually looks: two ordinary tokens that
/// happen to share a `collection_id`, and a hundred unique items that form
/// one. The point of the fixture is that the first two still render as
/// balances.
Widget buildNightjarCollectionsFeedUseCase(BuildContext context) {
  final listing = groupNightjarCollections([
    ..._readyView().assets,
    ..._pieces(),
  ]);
  return _stage(
    context,
    NightjarAssetsFeed(
      sections: buildNightjarAssetSections(
        buildNightjarAssetRows(assets: listing.ungrouped, onAssetTap: (_) {}),
      ),
      collections: buildNightjarCollectionRows(
        collections: listing.collections,
        onCollectionTap: (_) {},
        // The state every collection is in until somebody publishes a `logo`
        // (`spec/asset-collection-v0.md` section 3.5.1): the face is member
        // 0's artwork, and the row says so rather than letting the wallet's
        // inference pass for a statement by the issuer.
        artworkFor: (_) => NightjarCollectionArtworkData(
          artwork: NightjarArtworkData(
            status: NightjarArtworkStatus.unpinned,
            bytes: kNightjarWidgetbookArtwork,
            sourceOrigin: 'raw.githubusercontent.com',
          ),
          source: NightjarCollectionArtworkSource.derived,
          derivedFromIndex: 0,
        ),
      ),
      collectionsTitle: kNightjarCollectionsSectionTitle,
      cardWidth: null,
    ),
  );
}

/// One unique item as a row, so the "Owned / Unique item" column is visible
/// beside the balances it deliberately is not.
Widget buildNightjarUniqueItemRowUseCase(BuildContext context) {
  return _stage(
    context,
    NightjarAssetsFeed(
      sections: [
        NightjarAssetsSectionData(
          title: 'Public assets',
          rows: [
            _piece(7, owned: true, index: 7).toRowData(onTap: () {}),
            _piece(8, index: 8).toRowData(onTap: () {}),
            _namedAsset().toRowData(onTap: () {}),
          ],
        ),
      ],
      cardWidth: null,
    ),
  );
}

/// The accept-the-whole-collection card before anything is accepted. This is
/// the state the wording matters most in.
Widget buildNightjarCollectionAcceptUseCase(BuildContext context) {
  return _stage(
    context,
    NightjarCollectionAcceptanceCard(
      data: buildNightjarCollectionAcceptanceData(
        collection: _collection(),
        acceptance: const NightjarAssetAcceptance.empty(),
      ),
      onAcceptAll: () {},
    ),
  );
}

/// The same card once a piece has been accepted elsewhere — the partial
/// state a collection lands in when it grows.
Widget buildNightjarCollectionPartialUseCase(BuildContext context) {
  return _stage(
    context,
    NightjarCollectionAcceptanceCard(
      data: buildNightjarCollectionAcceptanceData(
        collection: _collection(count: 6),
        acceptance: const NightjarAssetAcceptance([
          NightjarAcceptedAsset(
            assetId:
                'pon000000000000000000000000000000000000000000000000000000000000',
          ),
        ]),
      ),
      onAcceptAll: () {},
      onForgetAll: () {},
    ),
  );
}

/// A grid of unaccepted pieces: empty frames, each carrying its own id, and
/// not a single fetch behind them.
Widget buildNightjarCollectionGridUseCase(BuildContext context) {
  final members = _collection(count: 12).members;
  return ColoredBox(
    color: context.colors.background.window,
    child: CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(AppSpacing.md),
          sliver: NightjarCollectionSliverGrid(
            members: members,
            tileBuilder: (context, member) =>
                NightjarCollectionTile(member: member, onTap: () {}),
          ),
        ),
      ],
    ),
  );
}

/// The same grid with artwork, showing every state a tile can be in.
///
/// It is a mix rather than twelve identical pictures because the states are
/// the point: `spec/asset-collection-v0.md` section 3.3 requires a pinned and
/// an unpinned piece to be distinguishable, and the gallery is where a
/// designer would notice that they are not. Tiles 0-7 are verified, 8 and 9
/// are unpinned (no `digests` entry for them), 10 was refused, and 11 is still
/// fetching.
Widget buildNightjarCollectionGridArtworkUseCase(BuildContext context) {
  final members = _collection(count: 12).members;
  return ColoredBox(
    color: context.colors.background.window,
    child: CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(AppSpacing.md),
          sliver: NightjarCollectionSliverGrid(
            members: members,
            tileBuilder: (context, member) => NightjarCollectionTile(
              member: member,
              artwork: _widgetbookArtwork(members.indexOf(member)),
              onTap: () {},
            ),
          ),
        ),
      ],
    ),
  );
}

/// One of each artwork state, by position in the fixture grid.
NightjarArtworkData _widgetbookArtwork(int position) {
  if (position >= 0 && position < 8) {
    return NightjarArtworkData(
      status: NightjarArtworkStatus.verified,
      bytes: kNightjarWidgetbookArtwork,
      sourceOrigin: 'example.invalid',
      documentPinned: true,
    );
  }
  if (position == 8 || position == 9) {
    return NightjarArtworkData(
      status: NightjarArtworkStatus.unpinned,
      bytes: kNightjarWidgetbookArtwork,
      sourceOrigin: 'example.invalid',
    );
  }
  if (position == 10) {
    return const NightjarArtworkData(
      status: NightjarArtworkStatus.refused,
      reason: NightjarMetadataAbandonReason.digestMismatch,
      sourceOrigin: 'example.invalid',
      documentPinned: true,
    );
  }
  return const NightjarArtworkData.pending();
}

/// One piece's own screen: the artwork, the name, the index, the id, and a
/// supply card that says "one, and only one" instead of two rows of 1.
Widget buildNightjarUniqueItemDetailUseCase(BuildContext context) {
  final asset = _piece(7, owned: true, index: 7);
  final view = NightjarViewData(
    status: NightjarViewStatus.ready,
    assets: [asset],
  );
  return _stage(
    context,
    NightjarAssetDetailBody(
      assetId: asset.assetId,
      view: view,
      asset: asset,
      heroSection: const NightjarArtworkPreview(),
    ),
  );
}

/// A stand-in for the provider-connected header, so the gallery shows the
/// artwork without a wallet, a fetcher, or an acceptance record behind it.
class NightjarArtworkPreview extends StatelessWidget {
  const NightjarArtworkPreview({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Center(
        child: NightjarArtwork(
          bytes: kNightjarWidgetbookArtwork,
          size: kNightjarUniqueArtworkSize,
        ),
      ),
    );
  }
}

/// A 1x1 PNG, scaled up by the frame. Real bytes, so the decode path in the
/// gallery is the decode path in the app.
final Uint8List kNightjarWidgetbookArtwork = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);
