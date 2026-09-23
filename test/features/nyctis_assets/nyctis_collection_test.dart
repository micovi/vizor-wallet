/// The pure half of collections and unique items: what counts as one, what
/// groups, and what the copy says about it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_mapper.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_assets_feed.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_collection_acceptance_card.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_collection_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_collection_mapper.dart';

/// The collection label the devnet issues the hundred-piece set under.
const _ponCollection =
    'c0113c7104900000000000000000000000000000000000000000000000000000';

/// The one the devnet's two *fungible* assets share. They really do share one:
/// NIGHTJAR and NIGHTCASH are issued into the same `collection_id` at indices
/// 0 and 1, which is why grouping on `collection_id` alone is wrong.
const _tokenCollection =
    '7a169e762b7c17817d999601c1f25fb56dcd24dfde3cb8f22c61e11860584a05';

String _pieceId(int i) => 'pon${i.toString().padLeft(61, '0')}';

NyctisAssetDetailData _piece(
  int i, {
  bool owned = false,
  String collection = _ponCollection,
  String? uri = 'https://raw.githubusercontent.invalid/pon.json',
  int? index,
  int? collectionMaxSupply,
}) => NyctisAssetDetailData(
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
          NyctisNoteRowData(
            position: BigInt.from(i),
            amount: BigInt.one,
            decimals: 0,
            createdHeight: BigInt.from(7000 + i),
          ),
        ]
      : const [],
);

NyctisAssetDetailData _token({
  required String assetId,
  required String name,
  required String symbol,
  String? collection = _tokenCollection,
}) => NyctisAssetDetailData(
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
      final dust = NyctisAssetDetailData(
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
      final private = NyctisAssetDetailData(
        assetId: 'private',
        balance: BigInt.one,
        decimals: 0,
      );
      expect(private.maxSupply, isNull);
      expect(private.isUniqueItem, isFalse);
    });

    test('an ordinary token is not one', () {
      expect(
        _token(assetId: 'a', name: 'NYCTIS', symbol: 'Ny').isUniqueItem,
        isFalse,
      );
    });
  });

  group('rendering a unique item', () {
    test('the row says Owned rather than a quantity', () {
      final row = _piece(7, owned: true).toRowData();

      expect(row.isUniqueItem, isTrue);
      expect(nyctisAssetRowBalanceText(row), kNyctisUniqueOwnedText);
      expect(nyctisAssetRowBalanceText(row), isNot('1'));
      expect(nyctisAssetRowNoteCountText(row), kNyctisUniqueItemLabel);
      expect(nyctisAssetRowNoteCountText(row), isNot('1 note'));
    });

    test('a piece the wallet does not hold says so instead of zero', () {
      final row = _piece(7).toRowData();

      expect(nyctisAssetRowBalanceText(row), kNyctisUniqueNotOwnedText);
      expect(nyctisAssetRowBalanceText(row), isNot('0'));
    });

    test('the holding card is a yes or a no, not a balance of one', () {
      final facts = buildNyctisWalletHoldingFacts(_piece(7, owned: true));

      expect(facts, hasLength(1));
      expect(facts.single.label, 'Yours');
      expect(facts.single.value, kNyctisUniqueOwnedText);
      expect(facts.map((f) => f.label), isNot(contains('Your balance')));
    });

    test('the supply card states the cap once rather than twice', () {
      final facts = buildNyctisAssetSupplyFacts(_piece(7));

      expect(facts, hasLength(1));
      expect(facts.single.value, 'One, and only one');
      expect(facts.map((f) => f.label), isNot(contains('Max supply')));
    });

    test('the footnote says where the cap is enforced', () {
      expect(nyctisSupplyFootnote(_piece(7)), kNyctisUniqueSupplyNote);
      expect(
        nyctisSupplyFootnote(
          _token(assetId: 'a', name: 'NYCTIS', symbol: 'Ny'),
        ),
        kNyctisSupplyPrivacyNote,
      );
    });

    test('an index the wallet has not read is named, not invented', () {
      final facts = buildNyctisAssetIdentityFacts(_piece(7));
      final index = facts.firstWhere((f) => f.label == 'Index in collection');

      expect(index.value, 'Not read yet');
      expect(index.value, isNot('7'));
      expect(index.value, isNot('0'));
    });

    test('an index the wallet has read is shown', () {
      final facts = buildNyctisAssetIdentityFacts(_piece(7, index: 7));

      expect(
        facts.firstWhere((f) => f.label == 'Index in collection').value,
        '7',
      );
    });

    test('the collection row carries the full id behind a truncation', () {
      final fact = buildNyctisAssetIdentityFacts(
        _piece(7),
      ).firstWhere((f) => f.label == 'Collection');

      expect(fact.value, truncateNyctisAssetId(_ponCollection));
      expect(fact.copyText, _ponCollection);
    });
  });

  group('grouping', () {
    test('a hundred pieces become one collection entry', () {
      final listing = groupNyctisCollections([
        for (var i = 0; i < 100; i++) _piece(i, owned: i < 3),
      ]);

      expect(listing.collections, hasLength(1));
      expect(listing.ungrouped, isEmpty);
      final collection = listing.collections.single;
      expect(collection.memberCount, 100);
      expect(collection.ownedCount, 3);
      expect(
        nyctisCollectionCountText(collection),
        '100 pieces · you hold 3',
      );
    });

    test('fungible assets sharing a collection id stay two balance rows', () {
      // The regression this whole rule exists for. On the reference devnet
      // NYCTIS and NIGHTCASH really are issued into one collection.
      final listing = groupNyctisCollections([
        _token(assetId: 'ny', name: 'NYCTIS', symbol: 'Ny'),
        _token(assetId: 'nc', name: 'NIGHTCASH', symbol: 'NC'),
      ]);

      expect(listing.collections, isEmpty);
      expect(listing.ungrouped, hasLength(2));

      final rows = buildNyctisAssetRows(assets: listing.ungrouped);
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row.isUniqueItem, isFalse);
        expect(nyctisAssetRowBalanceText(row), '1.25');
        expect(nyctisAssetRowNoteCountText(row), '0 notes');
      }
    });

    test('a single-member collection is not worth a group', () {
      final listing = groupNyctisCollections([_piece(0, owned: true)]);

      expect(listing.collections, isEmpty);
      expect(listing.ungrouped.single.assetId, _pieceId(0));
    });

    test('two members are', () {
      final listing = groupNyctisCollections([_piece(0), _piece(1)]);

      expect(kNyctisCollectionMinMembers, 2);
      expect(listing.collections.single.memberCount, 2);
    });

    test('a unique item with no collection stays a row', () {
      final listing = groupNyctisCollections([
        _piece(0, collection: ''),
        _piece(1, collection: ''),
      ]);

      expect(listing.collections, isEmpty);
      expect(listing.ungrouped, hasLength(2));
    });

    test('a mixed collection groups the pieces and keeps the token', () {
      final listing = groupNyctisCollections([
        _piece(0, collection: _tokenCollection),
        _piece(1, collection: _tokenCollection),
        _token(assetId: 'ny', name: 'NYCTIS', symbol: 'Ny'),
      ]);

      expect(listing.collections.single.memberCount, 2);
      expect(listing.ungrouped.single.assetId, 'ny');
    });

    test(
      'members order by index where one is known, by asset id where not',
      () {
        final listing = groupNyctisCollections([
          _piece(2, index: 2),
          _piece(0, index: 0),
          _piece(1, index: 1),
        ]);

        expect(listing.collections.single.members.map((m) => m.index), [
          0,
          1,
          2,
        ]);

        final unindexed = groupNyctisCollections([_piece(9), _piece(3)]);
        expect(unindexed.collections.single.members.map((m) => m.assetId), [
          _pieceId(3),
          _pieceId(9),
        ]);
      },
    );

    test('grouped member ids are exactly what the flat list drops', () {
      final listing = groupNyctisCollections([
        for (var i = 0; i < 4; i++) _piece(i),
        _token(assetId: 'ny', name: 'NYCTIS', symbol: 'Ny'),
      ]);

      expect(listing.groupedMemberIds, hasLength(4));
      expect(listing.groupedMemberIds.contains('ny'), isFalse);
    });
  });

  group('collection copy', () {
    test('the title is the members\' shared name prefix, trimmed', () {
      final collection = groupNyctisCollections([
        _piece(7),
        _piece(8),
      ]).collections.single;

      expect(collection.title, 'Phases of one night');
      expect(nyctisCollectionTitle(collection), 'Phases of one night');
    });

    test('unrelated names yield no title rather than a fragment', () {
      final collection = groupNyctisCollections([
        NyctisAssetDetailData(
          assetId: 'a' * 64,
          name: 'Anvil',
          collection: _ponCollection,
          isPublic: true,
          balance: BigInt.zero,
          decimals: 0,
          maxSupply: BigInt.one,
        ),
        NyctisAssetDetailData(
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
        nyctisCollectionTitle(collection),
        kNyctisUnnamedCollectionTitle,
      );
    });

    test('the subtitle always identifies the collection by id', () {
      final collection = groupNyctisCollections([
        _piece(0),
        _piece(1),
      ]).collections.single;

      expect(
        nyctisCollectionSubtitle(collection),
        truncateNyctisAssetId(_ponCollection),
      );
    });

    test('the uncapped count note says uncapped and claims no total', () {
      // U4: the old note said nothing in a collection id says how many there
      // should be, which is false since the id binds a cap.
      expect(kNyctisCollectionCountNote, contains('uncapped'));
      expect(kNyctisCollectionCountNote, contains('not a share of a total'));
      expect(
        kNyctisCollectionCountNote,
        isNot(contains('Nothing in a collection id says how many')),
      );
    });
  });

  group('the cap bound into collection_id', () {
    NyctisCollectionData capped(int cap, {int members = 3, int owned = 0}) =>
        groupNyctisCollections([
          for (var i = 0; i < members; i++)
            _piece(i, owned: i < owned, index: i, collectionMaxSupply: cap),
        ]).collections.single;

    NyctisCollectionData uncapped({int members = 3, int owned = 0}) =>
        groupNyctisCollections([
          for (var i = 0; i < members; i++)
            _piece(i, owned: i < owned, index: i),
        ]).collections.single;

    test('a collection with no cap reads as uncapped', () {
      final collection = uncapped();

      expect(collection.maxSupply, isNull);
      expect(collection.isCapped, isFalse);
      expect(nyctisCollectionPiecesText(collection), '3 pieces');
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
        nyctisCollectionCountText(collection),
        '3 of at most 10,000 · you hold 1',
      );
      expect(nyctisCollectionCountText(collection), isNot(contains('3 of 10,000')));
    });

    test('an uncapped count is unchanged', () {
      expect(
        nyctisCollectionCountText(uncapped(members: 100, owned: 3)),
        '100 pieces · you hold 3',
      );
    });

    test('a capped collection holding none still says "none held"', () {
      expect(
        nyctisCollectionCountText(capped(10000)),
        '3 of at most 10,000 · none held',
      );
    });

    test('capped and uncapped collections get different footnotes', () {
      expect(
        nyctisCollectionCountNote(uncapped()),
        kNyctisCollectionCountNote,
      );
      expect(
        nyctisCollectionCountNote(capped(10000)),
        kNyctisCappedCollectionCountNote,
      );
      expect(
        kNyctisCappedCollectionCountNote,
        isNot(kNyctisCollectionCountNote),
      );
    });

    test('the capped footnote says the cap is a ceiling and not a total', () {
      expect(kNyctisCappedCollectionCountNote, contains('ceiling, not a total'));
      // The sentence the old footnote made about every collection is now only
      // made about the uncapped ones.
      expect(
        kNyctisCappedCollectionCountNote,
        isNot(contains('Nothing in a collection id says how many')),
      );
    });

    test('the cap row says the cap, or says uncapped', () {
      String capValue(NyctisCollectionData collection) =>
          buildNyctisCollectionFacts(collection)
              .firstWhere((f) => f.label == 'Cap in the collection id')
              .value;
      expect(capValue(capped(10000)), 'At most 10,000');
      expect(capValue(uncapped()), 'Uncapped');
    });

    test('a row carries the public count only and reads as one sentence', () {
      final row = buildNyctisCollectionRows(
        collections: [capped(100, members: 10, owned: 3)],
      ).single;
      // U30: the owned count is the right-hand column, said once.
      expect(row.countText, '10 of at most 100');
      expect(row.ownedText, '3');
      expect(
        row.semanticsLabel,
        startsWith('Phases of one night, 10 of at most 100 pieces, you hold 3'),
      );
      expect(row.semanticsLabel, contains('collection id'));

      final open = buildNyctisCollectionRows(
        collections: [uncapped(members: 10)],
      ).single;
      expect(open.countText, '10 pieces');
      expect(open.semanticsLabel, contains('10 pieces, none held'));
    });

    test('members past the cap are still members', () {
      // `asset-collection-v0.md` section 3.1: a wallet **MUST NOT** treat a
      // member whose index is >= the cap as invalid. Nothing filters here, and
      // the count says what it read rather than what it expected to read.
      final collection = groupNyctisCollections([
        _piece(0, index: 0, collectionMaxSupply: 2),
        _piece(1, index: 1, collectionMaxSupply: 2),
        _piece(9, index: 9, collectionMaxSupply: 2),
      ]).collections.single;

      expect(collection.memberCount, 3);
      expect(collection.members.map((m) => m.index), [0, 1, 9]);
      expect(nyctisCollectionPiecesText(collection), '3 of at most 2');
    });
  });

  group('the document cap against the chain cap', () {
    NyctisCollectionData collectionWith(int? cap) => groupNyctisCollections([
      for (var i = 0; i < 3; i++) _piece(i, index: i, collectionMaxSupply: cap),
    ]).collections.single;

    test('agreement says nothing', () {
      expect(
        nyctisCollectionCapDisagreementText(
          collection: collectionWith(10000),
          documentMaxSupply: 10000,
        ),
        isNull,
      );
    });

    test('disagreement names both numbers and says which one counts', () {
      final text = nyctisCollectionCapDisagreementText(
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
        nyctisCollectionCapDisagreementText(
          collection: collectionWith(null),
          documentMaxSupply: 10000,
        ),
        isNull,
      );
      expect(
        nyctisCollectionCapDisagreementText(
          collection: collectionWith(10000),
          documentMaxSupply: null,
        ),
        isNull,
      );
    });
  });

  group('collection acceptance', () {
    NyctisCollectionData collectionOf(
      List<NyctisAssetDetailData> members,
    ) => groupNyctisCollections(members).collections.single;

    test('offers every unaccepted member that has a resolvable uri', () {
      final collection = collectionOf([
        for (var i = 0; i < 100; i++) _piece(i),
      ]);

      final data = buildNyctisCollectionAcceptanceData(
        collection: collection,
        acceptance: const NyctisAssetAcceptance.empty(),
      );

      expect(data.state, NyctisCollectionAcceptanceState.none);
      expect(data.pendingCount, 100);
      expect(data.origins, ['https://raw.githubusercontent.invalid']);
      expect(
        nyctisCollectionAcceptAction(data.pendingCount),
        'Show artwork for 100 pieces',
      );
    });

    test('the explainer names the host and the issuer, not the picture', () {
      final text = nyctisCollectionAcceptExplainer(
        count: 100,
        origins: const ['https://example.invalid'],
      );

      expect(text, contains('100 pieces'));
      expect(text, contains('https://example.invalid'));
      expect(text, contains('one issuer'));
    });

    test('several hosts are counted rather than silently reduced to one', () {
      final text = nyctisCollectionAcceptExplainer(
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

      final data = buildNyctisCollectionAcceptanceData(
        collection: collection,
        acceptance: const NyctisAssetAcceptance.empty(),
      );

      expect(data.pendingIds, [_pieceId(1)]);
    });

    test('a collection with nothing to fetch says so', () {
      final collection = collectionOf([
        _piece(0, uri: null),
        _piece(1, uri: null),
      ]);

      final data = buildNyctisCollectionAcceptanceData(
        collection: collection,
        acceptance: const NyctisAssetAcceptance.empty(),
      );

      expect(data.hasNothingToFetch, isTrue);
    });

    test('a partly accepted collection is partial, not all', () {
      final collection = collectionOf([_piece(0), _piece(1), _piece(2)]);
      final acceptance = NyctisAssetAcceptance([
        NyctisAcceptedAsset(assetId: _pieceId(0)),
      ]);

      final data = buildNyctisCollectionAcceptanceData(
        collection: collection,
        acceptance: acceptance,
      );

      expect(data.state, NyctisCollectionAcceptanceState.partial);
      expect(data.acceptedCount, 1);
      expect(data.pendingCount, 2);
    });

    test('the section 5 collision is aggregated, not dropped', () {
      final collection = collectionOf([_piece(0), _piece(1)]);
      // Something already accepted under a different id with a colliding name.
      final acceptance = NyctisAssetAcceptance([
        const NyctisAcceptedAsset(
          assetId: 'deadbeef',
          name: 'Phases of one night #0',
          symbol: 'PON',
        ),
      ]);

      final text = nyctisCollectionCollisionText(
        collection: collection,
        acceptance: acceptance,
      );

      expect(text, isNotNull);
      expect(text, contains('2 pieces'));
      expect(text, contains('different asset id'));
      expect(
        nyctisCollectionCollidingIds(
          collection: collection,
          acceptance: acceptance,
        ),
        [_pieceId(0), _pieceId(1)],
      );
    });

    test('the per-asset record is promised in the copy', () {
      expect(kNyctisCollectionPerAssetNote, contains('piece by piece'));
      expect(kNyctisCollectionPerAssetNote, contains('published later'));
    });
  });
}
