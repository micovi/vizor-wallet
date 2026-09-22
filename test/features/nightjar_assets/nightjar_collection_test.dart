/// The pure half of collections and unique items: what counts as one, what
/// groups, and what the copy says about it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/models/nightjar_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_mapper.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_assets_feed.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_collection_acceptance_card.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_collection_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_collection_mapper.dart';

/// The collection label the devnet issues the hundred-piece set under.
const _ponCollection =
    'c0113c7104900000000000000000000000000000000000000000000000000000';

/// The one the devnet's two *fungible* assets share. They really do share one:
/// NIGHTJAR and NIGHTCASH are issued into the same `collection_id` at indices
/// 0 and 1, which is why grouping on `collection_id` alone is wrong.
const _tokenCollection =
    '7a169e762b7c17817d999601c1f25fb56dcd24dfde3cb8f22c61e11860584a05';

String _pieceId(int i) => 'pon${i.toString().padLeft(61, '0')}';

NightjarAssetDetailData _piece(
  int i, {
  bool owned = false,
  String collection = _ponCollection,
  String? uri = 'https://raw.githubusercontent.invalid/pon.json',
  int? index,
  int? collectionMaxSupply,
}) => NightjarAssetDetailData(
  assetId: _pieceId(i),
  name: 'Phases of one night #$i',
  symbol: 'PON',
  collection: collection,
  index: index,
  collectionMaxSupply: collectionMaxSupply,
  isPublic: true,
  balance: owned ? BigInt.one : BigInt.zero,
  decimals: 0,
  issuedSupply: BigInt.one,
  maxSupply: BigInt.one,
  metadataUri: uri,
  notes: owned
      ? [
          NightjarNoteRowData(
            position: BigInt.from(i),
            amount: BigInt.one,
            decimals: 0,
            createdHeight: BigInt.from(7000 + i),
          ),
        ]
      : const [],
);

NightjarAssetDetailData _token({
  required String assetId,
  required String name,
  required String symbol,
  String? collection = _tokenCollection,
}) => NightjarAssetDetailData(
  assetId: assetId,
  name: name,
  symbol: symbol,
  collection: collection,
  isPublic: true,
  balance: BigInt.from(125000000),
  decimals: 8,
  issuedSupply: BigInt.from(100000000000000),
  maxSupply: BigInt.from(2100000000000000),
);

void main() {
  group('recognizing a unique item', () {
    test('max_supply 1 at 0 decimals is one', () {
      expect(_piece(0).isUniqueItem, isTrue);
    });

    test('a cap of one at eight decimals is not', () {
      // 0.00000001 of a divisible asset. A cap, but not a thing.
      final dust = NightjarAssetDetailData(
        assetId: 'dust',
        isPublic: true,
        balance: BigInt.zero,
        decimals: 8,
        maxSupply: BigInt.one,
      );
      expect(dust.isUniqueItem, isFalse);
    });

    test('an undisclosed cap is not one', () {
      // `maxSupply` is null for a private asset and for the uncapped
      // `Some(0)` case alike; neither may be read as a cap of one, and the
      // loader is what collapses both onto null.
      final private = NightjarAssetDetailData(
        assetId: 'private',
        balance: BigInt.one,
        decimals: 0,
      );
      expect(private.maxSupply, isNull);
      expect(private.isUniqueItem, isFalse);
    });

    test('an ordinary token is not one', () {
      expect(
        _token(assetId: 'a', name: 'NIGHTJAR', symbol: 'Nj').isUniqueItem,
        isFalse,
      );
    });
  });

  group('rendering a unique item', () {
    test('the row says Owned rather than a quantity', () {
      final row = _piece(7, owned: true).toRowData();

      expect(row.isUniqueItem, isTrue);
      expect(nightjarAssetRowBalanceText(row), kNightjarUniqueOwnedText);
      expect(nightjarAssetRowBalanceText(row), isNot('1'));
      expect(nightjarAssetRowNoteCountText(row), kNightjarUniqueItemLabel);
      expect(nightjarAssetRowNoteCountText(row), isNot('1 note'));
    });

    test('a piece the wallet does not hold says so instead of zero', () {
      final row = _piece(7).toRowData();

      expect(nightjarAssetRowBalanceText(row), kNightjarUniqueNotOwnedText);
      expect(nightjarAssetRowBalanceText(row), isNot('0'));
    });

    test('the holding card is a yes or a no, not a balance of one', () {
      final facts = buildNightjarWalletHoldingFacts(_piece(7, owned: true));

      expect(facts, hasLength(1));
      expect(facts.single.label, 'Yours');
      expect(facts.single.value, kNightjarUniqueOwnedText);
      expect(facts.map((f) => f.label), isNot(contains('Your balance')));
    });

    test('the supply card states the cap once rather than twice', () {
      final facts = buildNightjarAssetSupplyFacts(_piece(7));

      expect(facts, hasLength(1));
      expect(facts.single.value, 'One, and only one');
      expect(facts.map((f) => f.label), isNot(contains('Max supply')));
    });

    test('the footnote says where the cap is enforced', () {
      expect(nightjarSupplyFootnote(_piece(7)), kNightjarUniqueSupplyNote);
      expect(
        nightjarSupplyFootnote(
          _token(assetId: 'a', name: 'NIGHTJAR', symbol: 'Nj'),
        ),
        kNightjarSupplyPrivacyNote,
      );
    });

    test('an index the wallet has not read is named, not invented', () {
      final facts = buildNightjarAssetIdentityFacts(_piece(7));
      final index = facts.firstWhere((f) => f.label == 'Index in collection');

      expect(index.value, 'Not read yet');
      expect(index.value, isNot('7'));
      expect(index.value, isNot('0'));
    });

    test('an index the wallet has read is shown', () {
      final facts = buildNightjarAssetIdentityFacts(_piece(7, index: 7));

      expect(
        facts.firstWhere((f) => f.label == 'Index in collection').value,
        '7',
      );
    });

    test('the collection row carries the full id behind a truncation', () {
      final fact = buildNightjarAssetIdentityFacts(
        _piece(7),
      ).firstWhere((f) => f.label == 'Collection');

      expect(fact.value, truncateNightjarAssetId(_ponCollection));
      expect(fact.copyText, _ponCollection);
    });
  });

  group('grouping', () {
    test('a hundred pieces become one collection entry', () {
      final listing = groupNightjarCollections([
        for (var i = 0; i < 100; i++) _piece(i, owned: i < 3),
      ]);

      expect(listing.collections, hasLength(1));
      expect(listing.ungrouped, isEmpty);
      final collection = listing.collections.single;
      expect(collection.memberCount, 100);
      expect(collection.ownedCount, 3);
      expect(
        nightjarCollectionCountText(collection),
        '100 pieces · you hold 3',
      );
    });

    test('fungible assets sharing a collection id stay two balance rows', () {
      // The regression this whole rule exists for. On the reference devnet
      // NIGHTJAR and NIGHTCASH really are issued into one collection.
      final listing = groupNightjarCollections([
        _token(assetId: 'nj', name: 'NIGHTJAR', symbol: 'Nj'),
        _token(assetId: 'nc', name: 'NIGHTCASH', symbol: 'NC'),
      ]);

      expect(listing.collections, isEmpty);
      expect(listing.ungrouped, hasLength(2));

      final rows = buildNightjarAssetRows(assets: listing.ungrouped);
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row.isUniqueItem, isFalse);
        expect(nightjarAssetRowBalanceText(row), '1.25');
        expect(nightjarAssetRowNoteCountText(row), '0 notes');
      }
    });

    test('a single-member collection is not worth a group', () {
      final listing = groupNightjarCollections([_piece(0, owned: true)]);

      expect(listing.collections, isEmpty);
      expect(listing.ungrouped.single.assetId, _pieceId(0));
    });

    test('two members are', () {
      final listing = groupNightjarCollections([_piece(0), _piece(1)]);

      expect(kNightjarCollectionMinMembers, 2);
      expect(listing.collections.single.memberCount, 2);
    });

    test('a unique item with no collection stays a row', () {
      final listing = groupNightjarCollections([
        _piece(0, collection: ''),
        _piece(1, collection: ''),
      ]);

      expect(listing.collections, isEmpty);
      expect(listing.ungrouped, hasLength(2));
    });

    test('a mixed collection groups the pieces and keeps the token', () {
      final listing = groupNightjarCollections([
        _piece(0, collection: _tokenCollection),
        _piece(1, collection: _tokenCollection),
        _token(assetId: 'nj', name: 'NIGHTJAR', symbol: 'Nj'),
      ]);

      expect(listing.collections.single.memberCount, 2);
      expect(listing.ungrouped.single.assetId, 'nj');
    });

    test(
      'members order by index where one is known, by asset id where not',
      () {
        final listing = groupNightjarCollections([
          _piece(2, index: 2),
          _piece(0, index: 0),
          _piece(1, index: 1),
        ]);

        expect(listing.collections.single.members.map((m) => m.index), [
          0,
          1,
          2,
        ]);

        final unindexed = groupNightjarCollections([_piece(9), _piece(3)]);
        expect(unindexed.collections.single.members.map((m) => m.assetId), [
          _pieceId(3),
          _pieceId(9),
        ]);
      },
    );

    test('grouped member ids are exactly what the flat list drops', () {
      final listing = groupNightjarCollections([
        for (var i = 0; i < 4; i++) _piece(i),
        _token(assetId: 'nj', name: 'NIGHTJAR', symbol: 'Nj'),
      ]);

      expect(listing.groupedMemberIds, hasLength(4));
      expect(listing.groupedMemberIds.contains('nj'), isFalse);
    });
  });

  group('collection copy', () {
    test('the title is the members\' shared name prefix, trimmed', () {
      final collection = groupNightjarCollections([
        _piece(7),
        _piece(8),
      ]).collections.single;

      expect(collection.title, 'Phases of one night');
      expect(nightjarCollectionTitle(collection), 'Phases of one night');
    });

    test('unrelated names yield no title rather than a fragment', () {
      final collection = groupNightjarCollections([
        NightjarAssetDetailData(
          assetId: 'a' * 64,
          name: 'Anvil',
          collection: _ponCollection,
          isPublic: true,
          balance: BigInt.zero,
          decimals: 0,
          maxSupply: BigInt.one,
        ),
        NightjarAssetDetailData(
          assetId: 'b' * 64,
          name: 'Zebra',
          collection: _ponCollection,
          isPublic: true,
          balance: BigInt.zero,
          decimals: 0,
          maxSupply: BigInt.one,
        ),
      ]).collections.single;

      expect(collection.title, isNull);
      expect(
        nightjarCollectionTitle(collection),
        kNightjarUnnamedCollectionTitle,
      );
    });

    test('the subtitle always identifies the collection by id', () {
      final collection = groupNightjarCollections([
        _piece(0),
        _piece(1),
      ]).collections.single;

      expect(
        nightjarCollectionSubtitle(collection),
        truncateNightjarAssetId(_ponCollection),
      );
    });

    test('the count note refuses to claim a total', () {
      expect(kNightjarCollectionCountNote, contains('no total'));
    });
  });

  group('the cap bound into collection_id', () {
    NightjarCollectionData capped(int cap, {int members = 3, int owned = 0}) =>
        groupNightjarCollections([
          for (var i = 0; i < members; i++)
            _piece(i, owned: i < owned, index: i, collectionMaxSupply: cap),
        ]).collections.single;

    NightjarCollectionData uncapped({int members = 3, int owned = 0}) =>
        groupNightjarCollections([
          for (var i = 0; i < members; i++)
            _piece(i, owned: i < owned, index: i),
        ]).collections.single;

    test('a collection with no cap reads as uncapped', () {
      final collection = uncapped();

      expect(collection.maxSupply, isNull);
      expect(collection.isCapped, isFalse);
      expect(nightjarCollectionPiecesText(collection), '3 pieces');
    });

    test('the cap comes off the members, which all agree by construction', () {
      // `transition-v0.md` section 5 hashes the cap into `collection_id`, so
      // two members declaring different caps are members of two different
      // collections. Reading it off one member is reading it off all of them.
      final collection = capped(10000);

      expect(collection.maxSupply, 10000);
      expect(collection.isCapped, isTrue);
    });

    test('a capped count says "of at most", never a plain total', () {
      // Section 6 step 6f in as many words: "three of at most ten thousand" is
      // the honest rendering and "three of ten thousand" is not, because a cap
      // bounds a collection above and promises nothing about the pieces below
      // it existing yet.
      final collection = capped(10000, owned: 1);

      expect(
        nightjarCollectionCountText(collection),
        '3 of at most 10,000 · you hold 1',
      );
      expect(nightjarCollectionCountText(collection), isNot(contains('3 of 10,000')));
    });

    test('an uncapped count is unchanged', () {
      expect(
        nightjarCollectionCountText(uncapped(members: 100, owned: 3)),
        '100 pieces · you hold 3',
      );
    });

    test('a capped collection holding none still says "none held"', () {
      expect(
        nightjarCollectionCountText(capped(10000)),
        '3 of at most 10,000 · none held',
      );
    });

    test('capped and uncapped collections get different footnotes', () {
      expect(
        nightjarCollectionCountNote(uncapped()),
        kNightjarCollectionCountNote,
      );
      expect(
        nightjarCollectionCountNote(capped(10000)),
        kNightjarCappedCollectionCountNote,
      );
      expect(
        kNightjarCappedCollectionCountNote,
        isNot(kNightjarCollectionCountNote),
      );
    });

    test('the capped footnote says the cap is a ceiling and not a total', () {
      expect(kNightjarCappedCollectionCountNote, contains('ceiling, not a total'));
      // The sentence the old footnote made about every collection is now only
      // made about the uncapped ones.
      expect(
        kNightjarCappedCollectionCountNote,
        isNot(contains('Nothing in a collection id says how many')),
      );
    });

    test('only a capped collection lists a cap among its facts', () {
      final labels = [
        for (final fact in buildNightjarCollectionFacts(capped(10000)))
          fact.label,
      ];
      expect(labels, contains('Cap in the collection id'));
      expect(
        buildNightjarCollectionFacts(capped(10000))
            .firstWhere((f) => f.label == 'Cap in the collection id')
            .value,
        'At most 10,000',
      );

      expect(
        [
          for (final fact in buildNightjarCollectionFacts(uncapped()))
            fact.label,
        ],
        isNot(contains('Cap in the collection id')),
      );
    });

    test('members past the cap are still members', () {
      // `asset-collection-v0.md` section 3.1: a wallet **MUST NOT** treat a
      // member whose index is >= the cap as invalid. Nothing filters here, and
      // the count says what it read rather than what it expected to read.
      final collection = groupNightjarCollections([
        _piece(0, index: 0, collectionMaxSupply: 2),
        _piece(1, index: 1, collectionMaxSupply: 2),
        _piece(9, index: 9, collectionMaxSupply: 2),
      ]).collections.single;

      expect(collection.memberCount, 3);
      expect(collection.members.map((m) => m.index), [0, 1, 9]);
      expect(nightjarCollectionPiecesText(collection), '3 of at most 2');
    });
  });

  group('the document cap against the chain cap', () {
    NightjarCollectionData collectionWith(int? cap) => groupNightjarCollections([
      for (var i = 0; i < 3; i++) _piece(i, index: i, collectionMaxSupply: cap),
    ]).collections.single;

    test('agreement says nothing', () {
      expect(
        nightjarCollectionCapDisagreementText(
          collection: collectionWith(10000),
          documentMaxSupply: 10000,
        ),
        isNull,
      );
    });

    test('disagreement names both numbers and says which one counts', () {
      final text = nightjarCollectionCapDisagreementText(
        collection: collectionWith(9000),
        documentMaxSupply: 10000,
      );

      expect(text, isNotNull);
      expect(text, contains('10,000'));
      expect(text, contains('9,000'));
      expect(text, contains('collection id'));
    });

    test('a missing number on either side is not a disagreement', () {
      // An uncapped collection contradicts nothing, and a document that
      // declares no `max_supply` claims nothing. Reporting either as a
      // disagreement would turn the ordinary shape of a collection into a
      // warning.
      expect(
        nightjarCollectionCapDisagreementText(
          collection: collectionWith(null),
          documentMaxSupply: 10000,
        ),
        isNull,
      );
      expect(
        nightjarCollectionCapDisagreementText(
          collection: collectionWith(10000),
          documentMaxSupply: null,
        ),
        isNull,
      );
    });
  });

  group('collection acceptance', () {
    NightjarCollectionData collectionOf(
      List<NightjarAssetDetailData> members,
    ) => groupNightjarCollections(members).collections.single;

    test('offers every unaccepted member that has a resolvable uri', () {
      final collection = collectionOf([
        for (var i = 0; i < 100; i++) _piece(i),
      ]);

      final data = buildNightjarCollectionAcceptanceData(
        collection: collection,
        acceptance: const NightjarAssetAcceptance.empty(),
      );

      expect(data.state, NightjarCollectionAcceptanceState.none);
      expect(data.pendingCount, 100);
      expect(data.origins, ['https://raw.githubusercontent.invalid']);
      expect(
        nightjarCollectionAcceptAction(data.pendingCount),
        'Accept 100 pieces',
      );
    });

    test('the explainer names the host and the issuer, not the picture', () {
      final text = nightjarCollectionAcceptExplainer(
        count: 100,
        origins: const ['https://example.invalid'],
      );

      expect(text, contains('100 pieces'));
      expect(text, contains('https://example.invalid'));
      expect(text, contains('one issuer'));
      expect(text, contains('tells that host'));
    });

    test('several hosts are counted rather than silently reduced to one', () {
      final text = nightjarCollectionAcceptExplainer(
        count: 4,
        origins: const ['https://a.invalid', 'https://b.invalid'],
      );

      expect(text, contains('2 hosts'));
    });

    test('a member with an http uri is not offered', () {
      final collection = collectionOf([
        _piece(0, uri: 'http://example.invalid/0.json'),
        _piece(1),
      ]);

      final data = buildNightjarCollectionAcceptanceData(
        collection: collection,
        acceptance: const NightjarAssetAcceptance.empty(),
      );

      expect(data.pendingIds, [_pieceId(1)]);
    });

    test('a collection with nothing to fetch says so', () {
      final collection = collectionOf([
        _piece(0, uri: null),
        _piece(1, uri: null),
      ]);

      final data = buildNightjarCollectionAcceptanceData(
        collection: collection,
        acceptance: const NightjarAssetAcceptance.empty(),
      );

      expect(data.hasNothingToFetch, isTrue);
    });

    test('a partly accepted collection is partial, not all', () {
      final collection = collectionOf([_piece(0), _piece(1), _piece(2)]);
      final acceptance = NightjarAssetAcceptance([
        NightjarAcceptedAsset(assetId: _pieceId(0)),
      ]);

      final data = buildNightjarCollectionAcceptanceData(
        collection: collection,
        acceptance: acceptance,
      );

      expect(data.state, NightjarCollectionAcceptanceState.partial);
      expect(data.acceptedCount, 1);
      expect(data.pendingCount, 2);
    });

    test('the section 5 collision is aggregated, not dropped', () {
      final collection = collectionOf([_piece(0), _piece(1)]);
      // Something already accepted under a different id with a colliding name.
      final acceptance = NightjarAssetAcceptance([
        const NightjarAcceptedAsset(
          assetId: 'deadbeef',
          name: 'Phases of one night #0',
          symbol: 'PON',
        ),
      ]);

      final text = nightjarCollectionCollisionText(
        collection: collection,
        acceptance: acceptance,
      );

      expect(text, isNotNull);
      expect(text, contains('2 pieces'));
      expect(text, contains('different asset id'));
      expect(
        nightjarCollectionCollidingIds(
          collection: collection,
          acceptance: acceptance,
        ),
        [_pieceId(0), _pieceId(1)],
      );
    });

    test('the per-asset record is promised in the copy', () {
      expect(kNightjarCollectionPerAssetNote, contains('piece by piece'));
      expect(kNightjarCollectionPerAssetNote, contains('published later'));
    });
  });
}
