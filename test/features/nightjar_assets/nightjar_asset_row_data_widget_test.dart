import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_mapper.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_assets_feed.dart';

void main() {
  group('formatNightjarAmount', () {
    test('renders base units at the asset decimals without floating point', () {
      expect(formatNightjarAmount(BigInt.from(1250000), 6), '1.25');
      expect(formatNightjarAmount(BigInt.from(1000000), 6), '1');
      expect(formatNightjarAmount(BigInt.one, 6), '0.000001');
      expect(formatNightjarAmount(BigInt.zero, 6), '0');
    });

    test('groups the integer part and keeps zero decimals integral', () {
      expect(formatNightjarAmount(BigInt.from(1234567), 0), '1,234,567');
      expect(
        formatNightjarAmount(BigInt.parse('123456789000000'), 6),
        '123,456,789',
      );
    });

    test('survives amounts far past a 64-bit double', () {
      final huge = BigInt.parse('9007199254740993000000');
      expect(formatNightjarAmount(huge, 6), '9,007,199,254,740,993');
    });

    test('keeps the sign on a negative amount', () {
      expect(formatNightjarAmount(BigInt.from(-1500), 3), '-1.5');
    });
  });

  group('truncateNightjarAssetId', () {
    test('keeps both ends so two ids cannot collide visually', () {
      const id =
          'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
      final truncated = truncateNightjarAssetId(id);
      expect(
        truncated,
        '${id.substring(0, kNightjarAssetIdAffixLength)}…'
        '${id.substring(id.length - kNightjarAssetIdAffixLength)}',
      );
      expect(truncated, 'b2c1f7…e5f401');
    });

    test('leaves a short id alone', () {
      expect(truncateNightjarAssetId('abc'), 'abc');
    });
  });

  group('asset row copy', () {
    test('an unnamed asset shows its truncated id and says so', () {
      final row = NightjarAssetRowData(
        assetId: '0f1e2d3c4b5a69788796a5b4c3d2e1f0',
        balance: BigInt.from(3),
        decimals: 0,
        noteCount: 1,
      );
      expect(row.hasName, isFalse);
      expect(nightjarAssetRowTitle(row), truncateNightjarAssetId(row.assetId));
      expect(nightjarAssetRowSubtitle(row), 'Unnamed asset');
    });

    test('a named asset prefers its name and symbol', () {
      final row = NightjarAssetRowData(
        assetId: 'ffee',
        name: 'Harbour credit',
        symbol: 'HBC',
        balance: BigInt.from(1250000),
        decimals: 6,
        noteCount: 2,
      );
      expect(nightjarAssetRowTitle(row), 'Harbour credit');
      expect(nightjarAssetRowSubtitle(row), 'HBC');
      expect(nightjarAssetRowBalanceText(row), '1.25');
    });

    test('the note line pluralises and counts only final notes', () {
      NightjarAssetRowData row(int notes) => NightjarAssetRowData(
        assetId: 'aa',
        balance: BigInt.zero,
        decimals: 0,
        noteCount: notes,
      );
      expect(nightjarAssetRowNoteCountText(row(1)), '1 note');
      expect(nightjarAssetRowNoteCountText(row(4)), '4 notes');
    });
  });

  group('state copy', () {
    test('each degraded state has its own sentence and tone', () {
      const notConfigured = NightjarViewData.notConfigured();
      const unreachable = NightjarViewData(
        status: NightjarViewStatus.unreachable,
      );
      const stale = NightjarViewData(status: NightjarViewStatus.stale);
      const ready = NightjarViewData(status: NightjarViewStatus.ready);

      expect(nightjarListErrorText(notConfigured), kNightjarNotConfiguredText);
      expect(nightjarListErrorText(unreachable), kNightjarUnreachableText);
      expect(nightjarListErrorText(stale), kNightjarStaleText);
      expect(nightjarListErrorText(ready), isNull);

      expect(
        nightjarListErrorTone(notConfigured),
        NightjarMessageTone.neutral,
        reason: 'a wallet that was never set up has not failed at anything',
      );
      expect(nightjarListErrorTone(unreachable), NightjarMessageTone.error);
      expect(nightjarListErrorTone(stale), NightjarMessageTone.warning);

      expect(
        kNightjarNotConfiguredText,
        isNot(kNightjarUnreachableText),
        reason: 'the three states must not share copy',
      );
      expect(kNightjarUnreachableText, isNot(kNightjarStaleText));
      expect(kNightjarStaleText, isNot(kNightjarEmptyText));
    });

    test('an unverified view is its own state, not the unreachable one', () {
      const unverified = NightjarViewData(
        status: NightjarViewStatus.unverified,
      );

      expect(nightjarListErrorText(unverified), kNightjarUnverifiedText);
      expect(nightjarListErrorTone(unverified), NightjarMessageTone.error);
      expect(
        kNightjarUnverifiedText,
        isNot(kNightjarUnreachableText),
        reason:
            'a channel mismatch and a dead socket send the user to different '
            'places',
      );
      for (final copy in const [
        kNightjarChannelMismatchText,
        kNightjarVerifyingKeyMismatchText,
        kNightjarNothingVerifiedText,
        kNightjarStateRootMismatchText,
        kNightjarIndexerBehindText,
      ]) {
        expect(copy, isNot(kNightjarUnreachableText));
        expect(copy, isNot(kNightjarEmptyText));
      }
    });

    test("the loader's own sentence is preferred over the canned one", () {
      const view = NightjarViewData(
        status: NightjarViewStatus.unverified,
        statusMessage: kNightjarChannelMismatchText,
      );

      expect(nightjarListErrorText(view), kNightjarChannelMismatchText);
    });

    test('an unreadable state carries no caveats to render', () {
      for (final status in const [
        NightjarViewStatus.notConfigured,
        NightjarViewStatus.unreachable,
        NightjarViewStatus.unverified,
      ]) {
        expect(
          nightjarNoticeLines(
            NightjarViewData(
              status: status,
              pendingMessageCount: 3,
              chainTipSource: NightjarChainTipSource.indexer,
            ),
          ),
          isEmpty,
          reason: '$status',
        );
      }
    });

    test('every caveat the view owes is in the banner, in order', () {
      final view = NightjarViewData(
        status: NightjarViewStatus.stale,
        assets: [
          NightjarAssetDetailData(
            assetId: 'aa',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
        pendingMessageCount: 2,
        chainTipSource: NightjarChainTipSource.indexer,
      );

      expect(nightjarNoticeLines(view), [
        kNightjarStaleText,
        kNightjarBorrowedChainTipText,
        nightjarPendingMessagesText(
          pendingMessageCount: 2,
          finalityDepth: view.finalityDepth,
        ),
      ]);
      expect(nightjarNoticeText(view), contains(kNightjarStaleText));
    });

    test('the supply footnote follows the asset, not the screen', () {
      final public = NightjarAssetDetailData(
        assetId: 'aa',
        balance: BigInt.one,
        decimals: 0,
        isPublic: true,
      );
      final private = NightjarAssetDetailData(
        assetId: 'bb',
        balance: BigInt.one,
        decimals: 0,
      );

      expect(nightjarSupplyFootnote(public), kNightjarSupplyPrivacyNote);
      expect(nightjarSupplyFootnote(private), kNightjarPrivateSupplyNote);
      expect(
        kNightjarPrivateSupplyNote,
        isNot(contains('Issued supply is public')),
      );
    });

    test('a stale view that still has assets keeps its list and warns', () {
      final stale = NightjarViewData(
        status: NightjarViewStatus.stale,
        assets: [
          NightjarAssetDetailData(
            assetId: 'aa',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
      );
      expect(nightjarListErrorText(stale), isNull);
      expect(nightjarNoticeText(stale), kNightjarStaleText);
    });

    test('the pending notice names the finality depth', () {
      expect(
        nightjarPendingMessagesText(pendingMessageCount: 0, finalityDepth: 10),
        isNull,
      );
      expect(
        nightjarPendingMessagesText(pendingMessageCount: 1, finalityDepth: 10),
        contains('1 channel message is'),
      );
      expect(
        nightjarPendingMessagesText(pendingMessageCount: 3, finalityDepth: 10),
        contains('3 channel messages are'),
      );
      expect(
        nightjarPendingMessagesText(pendingMessageCount: 3, finalityDepth: 10),
        contains('10 confirmations'),
      );
    });
  });

  group('sections and ordering', () {
    test(
      'splits by what is public about the asset, never about the wallet',
      () {
        final rows = buildNightjarAssetRows(
          assets: [
            NightjarAssetDetailData(
              assetId: 'cc',
              name: 'Zulu',
              isPublic: true,
              balance: BigInt.one,
              decimals: 0,
            ),
            NightjarAssetDetailData(
              assetId: 'aa',
              balance: BigInt.zero,
              decimals: 0,
            ),
            NightjarAssetDetailData(
              assetId: 'bb',
              name: 'Alpha',
              balance: BigInt.two,
              decimals: 0,
            ),
          ],
        );
        // Named first, alphabetically; unnamed last.
        expect(rows.map((row) => row.assetId).toList(), ['bb', 'cc', 'aa']);

        final sections = buildNightjarAssetSections(rows);
        expect(sections.map((section) => section.title).toList(), [
          'Public assets',
          'Private assets',
        ]);
        expect(sections.first.rows.single.assetId, 'cc');
        expect(sections.last.rows.map((row) => row.assetId).toList(), [
          'bb',
          'aa',
        ]);
      },
    );

    test('a section is omitted rather than shown empty', () {
      final rows = buildNightjarAssetRows(
        assets: [
          NightjarAssetDetailData(
            assetId: 'aa',
            balance: BigInt.one,
            decimals: 0,
          ),
        ],
      );
      final sections = buildNightjarAssetSections(rows);
      expect(sections.single.title, 'Private assets');
    });
  });

  group('detail facts', () {
    test('a private asset gets no issued-supply figure at all', () {
      final asset = NightjarAssetDetailData(
        assetId: 'aa',
        name: 'Crew pass',
        balance: BigInt.one,
        decimals: 0,
      );
      expect(buildNightjarAssetSupplyFacts(asset), isEmpty);
      final identity = buildNightjarAssetIdentityFacts(asset);
      expect(
        identity.firstWhere((fact) => fact.label == 'Supply').value,
        'Private',
      );
    });

    test('a public asset separates issued from max supply', () {
      final asset = NightjarAssetDetailData(
        assetId: 'aa',
        isPublic: true,
        balance: BigInt.zero,
        decimals: 6,
        issuedSupply: BigInt.from(500000000000),
        maxSupply: BigInt.from(1000000000000),
      );
      final facts = buildNightjarAssetSupplyFacts(asset);
      expect(facts.map((fact) => fact.label).toList(), [
        'Issued supply',
        'Max supply',
      ]);
      expect(facts.first.value, '500,000');
      expect(facts.last.value, '1,000,000');
    });

    test('an undeclared supply is not rendered as zero', () {
      final asset = NightjarAssetDetailData(
        assetId: 'aa',
        isPublic: true,
        balance: BigInt.zero,
        decimals: 0,
      );
      final facts = buildNightjarAssetSupplyFacts(asset);
      expect(facts.first.value, 'Not read yet');
      expect(facts.last.value, 'Not declared');
    });

    test('the asset id row copies the full id, not the truncated one', () {
      const fullId =
          'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
      final facts = buildNightjarAssetIdentityFacts(
        NightjarAssetDetailData(
          assetId: fullId,
          balance: BigInt.zero,
          decimals: 0,
        ),
      );
      final idFact = facts.first;
      expect(idFact.label, 'Asset id');
      expect(idFact.value, truncateNightjarAssetId(fullId));
      expect(idFact.copyText, fullId);
      expect(
        facts.firstWhere((fact) => fact.label == 'Name').value,
        'Not declared',
      );
    });

    test('the wallet holding counts every note the view carries', () {
      final asset = NightjarAssetDetailData(
        assetId: 'aa',
        balance: BigInt.from(15),
        decimals: 0,
        notes: [
          NightjarNoteRowData(
            position: BigInt.one,
            amount: BigInt.from(10),
            decimals: 0,
            createdHeight: BigInt.from(100),
          ),
          NightjarNoteRowData(
            position: BigInt.two,
            amount: BigInt.from(5),
            decimals: 0,
            createdHeight: BigInt.from(120),
          ),
        ],
      );
      final facts = buildNightjarWalletHoldingFacts(asset);
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
      final facts = buildNightjarNoteFacts(
        NightjarNoteRowData(
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
    const view = NightjarViewData.notConfigured();
    expect(view.assetById('aa'), isNull);
    expect(view.isConfigured, isFalse);
    expect(view.finalityDepth, kNightjarDefaultFinalityDepth);
  });
}
