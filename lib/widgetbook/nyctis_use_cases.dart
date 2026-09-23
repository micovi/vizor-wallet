// ignore_for_file: depend_on_referenced_packages
// widgetbook is dev-only; see `widgetbook.dart` for the boundary.

/// Widgetbook use cases for every presentational Nyctis widget.
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
import '../src/features/nyctis_assets/models/nyctis_asset_acceptance.dart';
import '../src/features/nyctis_assets/models/nyctis_asset_metadata.dart';
import '../src/features/nyctis_assets/models/nyctis_metadata_pointer.dart';
import '../src/features/nyctis_assets/screens/nyctis_asset_detail_screen.dart';
import '../src/features/nyctis_assets/screens/nyctis_receive_screen.dart';
import '../src/features/nyctis_assets/services/nyctis_metadata_fetcher.dart';
import '../src/features/nyctis_assets/widgets/nyctis_artwork_data.dart';
import '../src/features/nyctis_assets/widgets/nyctis_asset_metadata_card.dart';
import '../src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import '../src/features/nyctis_assets/widgets/nyctis_asset_row_mapper.dart';
import '../src/features/nyctis_assets/widgets/nyctis_assets_feed.dart';
import '../src/features/nyctis_assets/widgets/nyctis_collection_acceptance_card.dart';
import '../src/features/nyctis_assets/widgets/nyctis_collection_data.dart';
import '../src/features/nyctis_assets/widgets/nyctis_collection_grid.dart';
import '../src/features/nyctis_assets/widgets/nyctis_collection_mapper.dart';
import '../src/features/nyctis_assets/widgets/nyctis_collection_sections.dart';
import '../src/features/nyctis_assets/widgets/nyctis_facts_card.dart';
import '../src/features/nyctis_assets/widgets/nyctis_metadata_copy.dart';
import '../src/features/nyctis_assets/widgets/nyctis_receive_panel.dart';

const _namedAssetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
const _unnamedAssetId =
    '0f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f4030201009f8e7d6c5b4a';
const _privateAssetId =
    '77aa11bb22cc33dd44ee55ff6600778899aabbccddeeff001122334455667788';

const _nyctisAddress =
    'nyreg1qqxvz8k3m7ph2j6ldu4cwesa9r0tg5y7n2q4v8xz3m6k9p2r5t8w1c4f7h0j3l6';

NyctisAssetDetailData _namedAsset() => NyctisAssetDetailData(
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
    NyctisAssetFactData(label: 'Issuer note', value: 'Port of call credit'),
    NyctisAssetFactData(label: 'Declared at height', value: '1,204'),
  ],
  notes: [
    NyctisNoteRowData(
      position: BigInt.from(41),
      amount: BigInt.from(1000000),
      decimals: 6,
      createdHeight: BigInt.from(1240),
    ),
    NyctisNoteRowData(
      position: BigInt.from(58),
      amount: BigInt.from(250000),
      decimals: 6,
      createdHeight: BigInt.from(1281),
      policyText: 'Spendable after height 1,300',
    ),
  ],
);

NyctisAssetDetailData _unnamedAsset() => NyctisAssetDetailData(
  assetId: _unnamedAssetId,
  isPublic: true,
  balance: BigInt.from(3),
  decimals: 0,
  issuedSupply: BigInt.from(21),
  notes: [
    NyctisNoteRowData(
      position: BigInt.from(7),
      amount: BigInt.from(3),
      decimals: 0,
      createdHeight: BigInt.from(1199),
    ),
  ],
);

NyctisAssetDetailData _privateAsset() => NyctisAssetDetailData(
  assetId: _privateAssetId,
  name: 'Crew pass',
  balance: BigInt.from(1),
  decimals: 0,
  notes: [
    NyctisNoteRowData(
      position: BigInt.from(2),
      amount: BigInt.from(1),
      decimals: 0,
      createdHeight: BigInt.from(1010),
      policyText: 'Non-transferable',
    ),
  ],
);

NyctisViewData _readyView({int pendingMessageCount = 1}) => NyctisViewData(
  status: NyctisViewStatus.ready,
  identity: const NyctisIdentityData(
    address: _nyctisAddress,
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

List<NyctisAssetsSectionData> _sections() {
  return buildNyctisAssetSections(
    buildNyctisAssetRows(assets: _readyView().assets, onAssetTap: (_) {}),
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

Widget buildNyctisAssetsFeedUseCase(BuildContext context) {
  return _stage(
    context,
    NyctisAssetsFeed(sections: _sections(), rowKeyPrefix: 'widgetbook'),
  );
}

Widget buildNyctisAssetsFeedLoadingUseCase(BuildContext context) {
  return _stage(
    context,
    const NyctisAssetsFeed(sections: [], isLoading: true),
  );
}

Widget buildNyctisAssetsFeedEmptyUseCase(BuildContext context) {
  return _stage(
    context,
    const NyctisAssetsFeed(sections: [], emptyText: kNyctisEmptyText),
  );
}

Widget buildNyctisAssetsFeedNotConfiguredUseCase(BuildContext context) {
  return _stage(
    context,
    const NyctisAssetsFeed(
      sections: [],
      errorText: kNyctisNotConfiguredText,
      errorTone: NyctisMessageTone.neutral,
    ),
  );
}

Widget buildNyctisAssetsFeedUnreachableUseCase(BuildContext context) {
  return _stage(
    context,
    const NyctisAssetsFeed(
      sections: [],
      errorText: kNyctisUnreachableText,
      errorTone: NyctisMessageTone.error,
    ),
  );
}

Widget buildNyctisAssetsFeedStaleUseCase(BuildContext context) {
  return _stage(
    context,
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NyctisMessageCard(
          text: kNyctisStaleText,
          tone: kNyctisNoticeTone,
        ),
        const SizedBox(height: AppSpacing.md),
        NyctisAssetsFeed(sections: _sections(), cardWidth: null),
      ],
    ),
  );
}

Widget buildNyctisPendingNoticeUseCase(BuildContext context) {
  return _stage(
    context,
    NyctisMessageCard(
      text:
          nyctisPendingMessagesText(
            pendingMessageCount: 2,
            finalityDepth: kNyctisDefaultFinalityDepth,
          ) ??
          '',
      tone: kNyctisNoticeTone,
    ),
  );
}

Widget buildNyctisAssetDetailUseCase(BuildContext context) {
  final view = _readyView();
  return _stage(
    context,
    NyctisAssetDetailBody(
      assetId: _namedAssetId,
      view: view,
      asset: view.assetById(_namedAssetId),
    ),
  );
}

Widget buildNyctisUnnamedAssetDetailUseCase(BuildContext context) {
  final view = _readyView(pendingMessageCount: 0);
  return _stage(
    context,
    NyctisAssetDetailBody(
      assetId: _unnamedAssetId,
      view: view,
      asset: view.assetById(_unnamedAssetId),
    ),
  );
}

Widget buildNyctisPrivateAssetDetailUseCase(BuildContext context) {
  final view = _readyView(pendingMessageCount: 0);
  return _stage(
    context,
    NyctisAssetDetailBody(
      assetId: _privateAssetId,
      view: view,
      asset: view.assetById(_privateAssetId),
    ),
  );
}

Widget buildNyctisFactsCardUseCase(BuildContext context) {
  final asset = _namedAsset();
  return _stage(
    context,
    NyctisFactsCard(
      title: 'Identity',
      facts: buildNyctisAssetIdentityFacts(asset),
      footnote: kNyctisSupplyPrivacyNote,
    ),
  );
}

Widget buildNyctisReceiveUseCase(BuildContext context) {
  return _stage(context, NyctisReceiveBody(view: _readyView()));
}

Widget buildNyctisReceiveNotConfiguredUseCase(BuildContext context) {
  return _stage(
    context,
    const NyctisReceiveBody(view: NyctisViewData.notConfigured()),
  );
}

Widget buildNyctisReceivePanelUseCase(BuildContext context) {
  return _stage(
    context,
    const NyctisReceivePanel(
      address: _nyctisAddress,
      networkLabel: 'Regtest',
    ),
  );
}

// ---------------------------------------------------------------------------
// Collections and unique items
// ---------------------------------------------------------------------------

const _collectionId =
    'c0113c710490aaaabbbbccccddddeeeeffff00001111222233334444555566667';

NyctisAssetDetailData _piece(int i, {bool owned = false, int? index}) =>
    NyctisAssetDetailData(
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

List<NyctisAssetDetailData> _pieces({int count = 100}) => [
  for (var i = 0; i < count; i++) _piece(i, owned: i < 3, index: i),
];

NyctisCollectionData _collection({int count = 100}) =>
    groupNyctisCollections(_pieces(count: count)).collections.single;

/// The assets list as the devnet actually looks: two ordinary tokens that
/// happen to share a `collection_id`, and a hundred unique items that form
/// one. The point of the fixture is that the first two still render as
/// balances.
Widget buildNyctisCollectionsFeedUseCase(BuildContext context) {
  final listing = groupNyctisCollections([
    ..._readyView().assets,
    ..._pieces(),
  ]);
  return _stage(
    context,
    NyctisAssetsFeed(
      sections: buildNyctisAssetSections(
        buildNyctisAssetRows(assets: listing.ungrouped, onAssetTap: (_) {}),
      ),
      collections: buildNyctisCollectionRows(
        collections: listing.collections,
        onCollectionTap: (_) {},
        // The state every collection is in until somebody publishes a `logo`
        // (`spec/asset-collection-v0.md` section 3.5.1): the face is member
        // 0's artwork, and the row says so rather than letting the wallet's
        // inference pass for a statement by the issuer.
        artworkFor: (_) => NyctisCollectionArtworkData(
          artwork: NyctisArtworkData(
            status: NyctisArtworkStatus.unpinned,
            bytes: kNyctisWidgetbookArtwork,
            sourceOrigin: 'raw.githubusercontent.com',
          ),
          source: NyctisCollectionArtworkSource.derived,
          derivedFromIndex: 0,
        ),
      ),
      collectionsTitle: kNyctisCollectionsSectionTitle,
      cardWidth: null,
    ),
  );
}

/// One unique item as a row, so the "Owned / Unique item" column is visible
/// beside the balances it deliberately is not.
Widget buildNyctisUniqueItemRowUseCase(BuildContext context) {
  return _stage(
    context,
    NyctisAssetsFeed(
      sections: [
        NyctisAssetsSectionData(
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
Widget buildNyctisCollectionAcceptUseCase(BuildContext context) {
  return _stage(
    context,
    NyctisCollectionAcceptanceCard(
      data: buildNyctisCollectionAcceptanceData(
        collection: _collection(),
        acceptance: const NyctisAssetAcceptance.empty(),
      ),
      onAcceptAll: () {},
    ),
  );
}

/// The same card once a piece has been accepted elsewhere — the partial
/// state a collection lands in when it grows.
Widget buildNyctisCollectionPartialUseCase(BuildContext context) {
  return _stage(
    context,
    NyctisCollectionAcceptanceCard(
      data: buildNyctisCollectionAcceptanceData(
        collection: _collection(count: 6),
        acceptance: const NyctisAssetAcceptance([
          NyctisAcceptedAsset(
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
Widget buildNyctisCollectionGridUseCase(BuildContext context) {
  final members = _collection(count: 12).members;
  return ColoredBox(
    color: context.colors.background.window,
    child: CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(AppSpacing.md),
          sliver: NyctisCollectionSliverGrid(
            members: members,
            tileBuilder: (context, member) =>
                NyctisCollectionTile(member: member, onTap: () {}),
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
Widget buildNyctisCollectionGridArtworkUseCase(BuildContext context) {
  final members = _collection(count: 12).members;
  return ColoredBox(
    color: context.colors.background.window,
    child: CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(AppSpacing.md),
          sliver: NyctisCollectionSliverGrid(
            members: members,
            tileBuilder: (context, member) => NyctisCollectionTile(
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
NyctisArtworkData _widgetbookArtwork(int position) {
  if (position >= 0 && position < 8) {
    return NyctisArtworkData(
      status: NyctisArtworkStatus.verified,
      bytes: kNyctisWidgetbookArtwork,
      sourceOrigin: 'example.invalid',
      documentPinned: true,
    );
  }
  if (position == 8 || position == 9) {
    return NyctisArtworkData(
      status: NyctisArtworkStatus.unpinned,
      bytes: kNyctisWidgetbookArtwork,
      sourceOrigin: 'example.invalid',
    );
  }
  if (position == 10) {
    return const NyctisArtworkData(
      status: NyctisArtworkStatus.refused,
      reason: NyctisMetadataAbandonReason.digestMismatch,
      sourceOrigin: 'example.invalid',
      documentPinned: true,
    );
  }
  return const NyctisArtworkData.pending();
}

/// One piece's own screen: the artwork, the name, the index, the id, and a
/// supply card that says "one, and only one" instead of two rows of 1.
Widget buildNyctisUniqueItemDetailUseCase(BuildContext context) {
  final asset = _piece(7, owned: true, index: 7);
  final view = NyctisViewData(
    status: NyctisViewStatus.ready,
    assets: [asset],
  );
  return _stage(
    context,
    NyctisAssetDetailBody(
      assetId: asset.assetId,
      view: view,
      asset: asset,
      heroSection: const NyctisArtworkPreview(),
    ),
  );
}

/// A stand-in for the provider-connected header, so the gallery shows the
/// artwork without a wallet, a fetcher, or an acceptance record behind it.
class NyctisArtworkPreview extends StatelessWidget {
  const NyctisArtworkPreview({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Center(
        child: NyctisArtwork(
          bytes: kNyctisWidgetbookArtwork,
          size: kNyctisUniqueArtworkSize,
        ),
      ),
    );
  }
}

/// A 1x1 PNG, scaled up by the frame. Real bytes, so the decode path in the
/// gallery is the decode path in the app.
final Uint8List kNyctisWidgetbookArtwork = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);

// ---------------------------------------------------------------------------
// Acceptance, large numbers, caps and text scaling
// ---------------------------------------------------------------------------

/// A signed `uri` with a `#b2=` pin, so the card has a host and a pin to show.
const _metadataUri =
    'https://metadata.example.invalid/harbour.json'
    '#b2=Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0';

/// The asset a collision is against: accepted earlier, same name and symbol,
/// different id.
const _acceptedLookalike = NyctisAcceptedAsset(
  assetId: '9e9e11bb22cc33dd44ee55ff6600778899aabbccddeeff00112233445566e5f4',
  name: 'Harbour credit',
  symbol: 'HBC',
);

NyctisAssetMetadataCardData _metadataCardData({
  bool accepted = false,
  List<NyctisNameCollision> collisions = const [],
  NyctisAssetMetadataView? view,
  String uri = _metadataUri,
}) {
  final read = readNyctisMetadataUri(uri);
  return NyctisAssetMetadataCardData(
    assetId: _namedAssetId,
    name: 'Harbour credit',
    symbol: 'HBC',
    pointer: read.pointer,
    refusalText: nyctisPointerRefusalText(read.rejection),
    accepted: accepted,
    view: view,
    collisions: collisions,
  );
}

/// Before acceptance: one sentence, the id, the button, and the rest behind
/// "What this means".
Widget buildNyctisMetadataCardBeforeUseCase(BuildContext context) {
  return _stage(
    context,
    NyctisAssetMetadataCard(data: _metadataCardData(), onAccept: () {}),
  );
}

/// The impersonation case: the name and symbol match an asset already shown,
/// both ids are listed, and accepting takes a second, deliberate press.
Widget buildNyctisMetadataCardCollisionUseCase(BuildContext context) {
  return _stage(
    context,
    NyctisAssetMetadataCard(
      data: _metadataCardData(
        collisions: const [
          NyctisNameCollision(
            existing: _acceptedLookalike,
            matchesName: true,
            matchesSymbol: true,
          ),
        ],
      ),
      onAccept: () {},
    ),
  );
}

/// After acceptance: the logo with the asset id beside it, the description,
/// a link carrying its origin, and the way back.
Widget buildNyctisMetadataCardAcceptedUseCase(BuildContext context) {
  return _stage(
    context,
    NyctisAssetMetadataCard(
      data: _metadataCardData(
        accepted: true,
        view: NyctisAssetMetadataView(
          assetId: _namedAssetId,
          metadata: NyctisAssetMetadata(
            description: 'Credit redeemable at the harbour office.',
            website: Uri.parse('https://harbour.example.invalid/'),
          ),
          documentPinned: true,
          sourceOrigin: 'metadata.example.invalid',
          logoBytes: kNyctisWidgetbookArtwork,
          logoPinned: true,
        ),
      ),
      onForget: () {},
      onOpenLink: (_) {},
    ),
  );
}

/// A pointer the wallet refuses to resolve, and says why.
Widget buildNyctisMetadataCardRefusedUseCase(BuildContext context) {
  return _stage(
    context,
    NyctisAssetMetadataCard(
      data: _metadataCardData(uri: 'http://metadata.example.invalid/a.json'),
    ),
  );
}

/// The largest balance a u64 can hold, beside ordinary ones. The amount
/// scales down to fit rather than overflowing or being clipped.
Widget buildNyctisLargeNumbersUseCase(BuildContext context) {
  final huge = NyctisAssetDetailData(
    assetId: _unnamedAssetId,
    name: 'A token with a name long enough to need an ellipsis in any row',
    symbol: 'LONGSYMBOL',
    isPublic: true,
    balance: BigInt.parse('18446744073709551615'),
    decimals: 0,
    issuedSupply: BigInt.parse('18446744073709551615'),
  );
  final view = NyctisViewData(
    status: NyctisViewStatus.ready,
    assets: [huge, _namedAsset()],
  );
  return _stage(
    context,
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NyctisAssetsFeed(
          sections: buildNyctisAssetSections(
            buildNyctisAssetRows(assets: view.assets, onAssetTap: (_) {}),
          ),
          cardWidth: null,
        ),
        const SizedBox(height: AppSpacing.md),
        NyctisAssetDetailBody(
          assetId: huge.assetId,
          view: view,
          asset: huge,
        ),
      ],
    ),
    width: kNyctisCardWidth,
  );
}

/// The list at 200% text on a phone-width pane: rows stack their amount
/// under the title instead of overflowing.
Widget buildNyctisLargeTextUseCase(BuildContext context) {
  return MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(2)),
    child: _stage(
      context,
      NyctisAssetsFeed(sections: _sections(), cardWidth: null),
      width: 343,
    ),
  );
}

NyctisCollectionData _cappedCollection({int count = 10, int? cap = 100}) =>
    groupNyctisCollections([
      for (var i = 0; i < count; i++)
        NyctisAssetDetailData(
          assetId: 'cap${i.toString().padLeft(61, '0')}',
          name: 'Phases of One Night #$i',
          collection: _collectionId,
          index: i,
          collectionMaxSupply: cap,
          isPublic: true,
          balance: i < 3 ? BigInt.one : BigInt.zero,
          decimals: 0,
          issuedSupply: BigInt.one,
          maxSupply: BigInt.one,
        ),
    ]).collections.single;

Widget _collectionFacts(BuildContext context, NyctisCollectionData c) {
  return _stage(
    context,
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NyctisAssetsFeed(
          sections: const [],
          collections: buildNyctisCollectionRows(
            collections: [c],
            onCollectionTap: (_) {},
          ),
          cardWidth: null,
        ),
        const SizedBox(height: AppSpacing.md),
        NyctisFactsCard(
          title: 'Collection',
          facts: buildNyctisCollectionFacts(c),
          footnote: nyctisCollectionCountNote(c),
        ),
      ],
    ),
  );
}

/// A capped collection: "10 of at most 100", and the cap as a fact.
Widget buildNyctisCollectionCappedUseCase(BuildContext context) =>
    _collectionFacts(context, _cappedCollection());

/// An uncapped one, which says so rather than implying a missing number.
Widget buildNyctisCollectionUncappedUseCase(BuildContext context) =>
    _collectionFacts(context, _cappedCollection(cap: null));

/// The collection card when one of its pieces shares a name with an asset
/// already shown: the ids side by side and a second, deliberate step.
Widget buildNyctisCollectionCollisionUseCase(BuildContext context) {
  return _stage(
    context,
    NyctisCollectionAcceptanceCard(
      data: buildNyctisCollectionAcceptanceData(
        collection: _collection(count: 6),
        acceptance: const NyctisAssetAcceptance([
          NyctisAcceptedAsset(
            assetId:
                'aa11bb22cc33dd44ee55ff6600778899aabbccddeeff0011223344556677ff',
            name: 'Phases of one night #0',
            symbol: 'PON',
          ),
        ]),
        warmupMaxBytes: 4 * 1024 * 1024,
      ),
      onAcceptAll: () {},
    ),
  );
}
