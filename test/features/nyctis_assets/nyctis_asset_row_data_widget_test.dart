import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_mapper.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_assets_feed.dart';

void main() {
  group('formatNyctisAmount', () {
    test('renders base units at the asset decimals without floating point', () {
      expect(formatNyctisAmount(BigInt.from(1250000), 6), '1.25');
      expect(formatNyctisAmount(BigInt.from(1000000), 6), '1');
      expect(formatNyctisAmount(BigInt.one, 6), '0.000001');
      expect(formatNyctisAmount(BigInt.zero, 6), '0');
    });

    test('groups the integer part and keeps zero decimals integral', () {
      expect(formatNyctisAmount(BigInt.from(1234567), 0), '1,234,567');
      expect(
        formatNyctisAmount(BigInt.parse('123456789000000'), 6),
        '123,456,789',
      );
    });

    test('survives amounts far past a 64-bit double', () {
      final huge = BigInt.parse('9007199254740993000000');
      expect(formatNyctisAmount(huge, 6), '9,007,199,254,740,993');
    });

    test('keeps the sign on a negative amount', () {
      expect(formatNyctisAmount(BigInt.from(-1500), 3), '-1.5');
    });
  });

  group('truncateNyctisAssetId', () {
    test('keeps both ends so two ids cannot collide visually', () {
      const id =
          'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
      final truncated = truncateNyctisAssetId(id);
      expect(
        truncated,
        '${id.substring(0, kNyctisAssetIdAffixLength)}…'
        '${id.substring(id.length - kNyctisAssetIdAffixLength)}',
      );
      expect(truncated, 'b2c1f7…e5f401');
    });

    test('leaves a short id alone', () {
      expect(truncateNyctisAssetId('abc'), 'abc');
    });
  });

  group('asset row copy', () {
    test('an unnamed asset shows its truncated id and says so', () {
      final row = NyctisAssetRowData(
        assetId: '0f1e2d3c4b5a69788796a5b4c3d2e1f0',
        balance: BigInt.from(3),
        decimals: 0,
        noteCount: 1,
      );
      expect(row.hasName, isFalse);
      expect(nyctisAssetRowTitle(row), truncateNyctisAssetId(row.assetId));
      expect(nyctisAssetRowSubtitle(row), 'Unnamed asset');
    });

    test('a named asset prefers its name and symbol', () {
      final row = NyctisAssetRowData(
        assetId: 'ffee',
        name: 'Harbour credit',
        symbol: 'HBC',
        balance: BigInt.from(1250000),
        decimals: 6,
        noteCount: 2,
      );
      expect(nyctisAssetRowTitle(row), 'Harbour credit');
      expect(nyctisAssetRowSubtitle(row), 'HBC');
      expect(nyctisAssetRowBalanceText(row), '1.25');
    });

    test('the note line pluralises and counts only final notes', () {
      NyctisAssetRowData row(int notes) => NyctisAssetRowData(
        assetId: 'aa',
        balance: BigInt.zero,
        decimals: 0,
        noteCount: notes,
      );
      expect(nyctisAssetRowNoteCountText(row(1)), '1 note');
      expect(nyctisAssetRowNoteCountText(row(4)), '4 notes');
    });
  });

  group('state copy', () {
    test('each degraded state has its own sentence and tone', () {
      const notConfigured = NyctisViewData.notConfigured();
      const unreachable = NyctisViewData(
        status: NyctisViewStatus.unreachable,
      );
      const stale = NyctisViewData(status: NyctisViewStatus.stale);
      const ready = NyctisViewData(status: NyctisViewStatus.ready);

      expect(nyctisListErrorText(notConfigured), kNyctisNotConfiguredText);
      expect(nyctisListErrorText(unreachable), kNyctisUnreachableText);
      expect(nyctisListErrorText(stale), kNyctisStaleText);
      expect(nyctisListErrorText(ready), isNull);

      expect(
        nyctisListErrorTone(notConfigured),
        NyctisMessageTone.neutral,
        reason: 'a wallet that was never set up has not failed at anything',
      );
      expect(nyctisListErrorTone(unreachable), NyctisMessageTone.error);
      expect(nyctisListErrorTone(stale), NyctisMessageTone.warning);

      expect(
        kNyctisNotConfiguredText,
        isNot(kNyctisUnreachableText),
        reason: 'the three states must not share copy',
      );
      expect(kNyctisUnreachableText, isNot(kNyctisStaleText));
      expect(kNyctisStaleText, isNot(kNyctisEmptyText));
    });

    test('an unverified view is its own state, not the unreachable one', () {
      const unverified = NyctisViewData(
        status: NyctisViewStatus.unverified,
      );

      expect(nyctisListErrorText(unverified), kNyctisUnverifiedText);
      expect(nyctisListErrorTone(unverified), NyctisMessageTone.error);
      expect(
        kNyctisUnverifiedText,
        isNot(kNyctisUnreachableText),
        reason:
            'a channel mismatch and a dead socket send the user to different '
            'places',
      );
      for (final copy in const [
        kNyctisChannelMismatchText,
        kNyctisVerifyingKeyMismatchText,
        kNyctisNothingVerifiedText,
        kNyctisStateRootMismatchText,
        kNyctisIndexerBehindText,
      ]) {
        expect(copy, isNot(kNyctisUnreachableText));
        expect(copy, isNot(kNyctisEmptyText));
      }
    });

    test("the loader's own sentence is preferred over the canned one", () {
      const view = NyctisViewData(
        status: NyctisViewStatus.unverified,
        statusMessage: kNyctisChannelMismatchText,
      );

      expect(nyctisListErrorText(view), kNyctisChannelMismatchText);
    });

    test('an unreadable state carries no caveats to render', () {
      for (final status in const [
        NyctisViewStatus.notConfigured,
        NyctisViewStatus.unreachable,
        NyctisViewStatus.unverified,
      ]) {
        expect(
          nyctisNoticeLines(
            NyctisViewData(
              status: status,
              pendingMessageCount: 3,
              chainTipSource: NyctisChainTipSource.indexer,
            ),
          ),
          isEmpty,
          reason: '$status',
        );
      }
    });

    test('every caveat the view owes is in the banner, in order', () {
      final view = NyctisViewData(
        status: NyctisViewStatus.stale,
        assets: [
          NyctisAssetDetailData(
            assetId: 'aa',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
        pendingMessageCount: 2,
        chainTipSource: NyctisChainTipSource.indexer,
      );

      expect(nyctisNoticeLines(view), [
        kNyctisStaleText,
        kNyctisBorrowedChainTipText,
        nyctisPendingMessagesText(
          pendingMessageCount: 2,
          finalityDepth: view.finalityDepth,
        ),
      ]);
      expect(nyctisNoticeText(view), contains(kNyctisStaleText));
    });

    test('the supply footnote follows the asset, not the screen', () {
      final public = NyctisAssetDetailData(
        assetId: 'aa',
        balance: BigInt.one,
        decimals: 0,
        isPublic: true,
      );
      final private = NyctisAssetDetailData(
        assetId: 'bb',
        balance: BigInt.one,
        decimals: 0,
      );

      expect(nyctisSupplyFootnote(public), kNyctisSupplyPrivacyNote);
      expect(nyctisSupplyFootnote(private), kNyctisPrivateSupplyNote);
      expect(
        kNyctisPrivateSupplyNote,
        isNot(contains('Issued supply is public')),
      );
    });

    test('a stale view that still has assets keeps its list and warns', () {
      final stale = NyctisViewData(
        status: NyctisViewStatus.stale,
        assets: [
          NyctisAssetDetailData(
            assetId: 'aa',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
      );
      expect(nyctisListErrorText(stale), isNull);
      expect(nyctisNoticeText(stale), kNyctisStaleText);
    });

    test('the pending notice names the finality depth', () {
      expect(
        nyctisPendingMessagesText(pendingMessageCount: 0, finalityDepth: 10),
        isNull,
      );
      expect(
        nyctisPendingMessagesText(pendingMessageCount: 1, finalityDepth: 10),
        contains('1 channel message is'),
      );
      expect(
        nyctisPendingMessagesText(pendingMessageCount: 3, finalityDepth: 10),
        contains('3 channel messages are'),
      );
      expect(
        nyctisPendingMessagesText(pendingMessageCount: 3, finalityDepth: 10),
        contains('10 confirmations'),
      );
    });
  });

  group('sections and ordering', () {
    test(
      'splits by what is public about the asset, never about the wallet',
      () {
        final rows = buildNyctisAssetRows(
          assets: [
            NyctisAssetDetailData(
              assetId: 'cc',
              name: 'Zulu',
              isPublic: true,
              balance: BigInt.one,
              decimals: 0,
            ),
            NyctisAssetDetailData(
              assetId: 'aa',
              balance: BigInt.zero,
              decimals: 0,
            ),
            NyctisAssetDetailData(
              assetId: 'bb',
              name: 'Alpha',
              balance: BigInt.two,
              decimals: 0,
            ),
          ],
        );
        // Named first, alphabetically; unnamed last.
        expect(rows.map((row) => row.assetId).toList(), ['bb', 'cc', 'aa']);

        final sections = buildNyctisAssetSections(rows);
        // U6: named for what is public — the issued supply — so the headings
        // cannot be read as the privacy of the user's holdings.
        expect(sections.map((section) => section.title).toList(), [
          'Supply is public',
          'Supply is private',
        ]);
        for (final section in sections) {
          expect(section.subtitle, contains('Your balance is private'));
        }
        expect(sections.first.rows.single.assetId, 'cc');
        expect(sections.last.rows.map((row) => row.assetId).toList(), [
          'bb',
          'aa',
        ]);
      },
    );

    test('a section is omitted rather than shown empty', () {
      final rows = buildNyctisAssetRows(
        assets: [
          NyctisAssetDetailData(
            assetId: 'aa',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
      );
      final sections = buildNyctisAssetSections(rows);
      expect(sections.single.title, 'Supply is private');
    });
  });

  group('detail facts', () {
    test('a private asset gets no issued-supply figure at all', () {
      final asset = NyctisAssetDetailData(
        assetId: 'aa',
        name: 'Crew pass',
        balance: BigInt.one,
        decimals: 0,
      );
      expect(buildNyctisAssetSupplyFacts(asset), isEmpty);
      final identity = buildNyctisAssetIdentityFacts(asset);
      expect(
        identity.firstWhere((fact) => fact.label == 'Supply').value,
        'Private',
      );
    });

    test('a public asset separates issued from max supply', () {
      final asset = NyctisAssetDetailData(
        assetId: 'aa',
        isPublic: true,
        balance: BigInt.zero,
        decimals: 6,
        issuedSupply: BigInt.from(500000000000),
        maxSupply: BigInt.from(1000000000000),
      );
      final facts = buildNyctisAssetSupplyFacts(asset);
      expect(facts.map((fact) => fact.label).toList(), [
        'Issued supply',
        'Max supply',
      ]);
      expect(facts.first.value, '500,000');
      expect(facts.last.value, '1,000,000');
    });

    test('an uncapped public supply is not rendered as zero or missing', () {
      final asset = NyctisAssetDetailData(
        assetId: 'aa',
        isPublic: true,
        balance: BigInt.zero,
        decimals: 0,
      );
      final facts = buildNyctisAssetSupplyFacts(asset);
      expect(facts.first.value, 'Not read yet');
      // A public asset with a null max supply was issued with a zero cap —
      // uncapped, a fact from the chain rather than a gap (U29).
      expect(facts.last.value, 'Uncapped');
    });

    test('the asset id row copies the full id, not the truncated one', () {
      const fullId =
          'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
      final facts = buildNyctisAssetIdentityFacts(
        NyctisAssetDetailData(
          assetId: fullId,
          balance: BigInt.zero,
          decimals: 0,
        ),
      );
      final idFact = facts.first;
      expect(idFact.label, 'Asset id');
      expect(idFact.value, truncateNyctisAssetId(fullId));
      expect(idFact.copyText, fullId);
      expect(
        facts.firstWhere((fact) => fact.label == 'Name').value,
        'Not declared',
      );
    });

    test('the wallet holding counts every note the view carries', () {
      final asset = NyctisAssetDetailData(
        assetId: 'aa',
        balance: BigInt.from(15),
        decimals: 0,
        notes: [
          NyctisNoteRowData(
            position: BigInt.one,
            amount: BigInt.from(10),
            decimals: 0,
            createdHeight: BigInt.from(100),
          ),
          NyctisNoteRowData(
            position: BigInt.two,
            amount: BigInt.from(5),
            decimals: 0,
            createdHeight: BigInt.from(120),
          ),
        ],
      );
      final facts = buildNyctisWalletHoldingFacts(asset);
      expect(
        facts.map((fact) => fact.label).toList(),
        ['Your balance', 'Your notes'],
        reason:
            'the replay closes the view below the finality depth, so there is '
            'no per-asset pending count to show',
      );
      expect(facts[1].value, '2');
      expect(asset.toRowData().noteCount, 2);
    });

    test('a note with no policy says so rather than leaving a blank', () {
      final facts = buildNyctisNoteFacts(
        NyctisNoteRowData(
          position: BigInt.from(41),
          amount: BigInt.from(1000000),
          decimals: 6,
          createdHeight: BigInt.from(1240),
        ),
      );
      expect(facts.map((fact) => fact.label).toList(), [
        'Amount',
        'Position',
        'Created at height',
        'Policy',
      ]);
      expect(facts.first.value, '1');
      expect(facts.last.value, 'None');
    });
  });

  test('assetById finds nothing for an id the view does not hold', () {
    const view = NyctisViewData.notConfigured();
    expect(view.assetById('aa'), isNull);
    expect(view.isConfigured, isFalse);
    expect(view.finalityDepth, kNyctisDefaultFinalityDepth);
  });
}
