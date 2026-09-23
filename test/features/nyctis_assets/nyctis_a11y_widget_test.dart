// Screen-reader, keyboard, overflow and contrast behaviour of the
// presentational Nyctis widgets. Lane-agnostic: runs in both the desktop
// and the mobile lane, and compares against token constants only.
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/models/nyctis_asset_acceptance.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_artwork_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_mapper.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_assets_feed.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_collection_acceptance_card.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_collection_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_collection_grid.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_collection_mapper.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_facts_card.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_interactive.dart';

const _assetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
const _collectionId =
    'c0ffee0490aaaabbbbccccddddeeeeffff00001111222233334444555566e5f4aa';

final BigInt _u64Max = BigInt.parse('18446744073709551615');

NyctisAssetRowData _nightCash({
  BigInt? balance,
  VoidCallback? onTap,
  String name = 'NightCash',
}) => NyctisAssetRowData(
  assetId: _assetId,
  name: name,
  symbol: 'NC',
  balance: balance ?? BigInt.from(988),
  decimals: 0,
  noteCount: 3,
  isPublic: true,
  onTap: onTap,
);

NyctisAssetDetailData _piece(int i, {bool owned = false, int? cap}) =>
    NyctisAssetDetailData(
      assetId: 'pon${i.toString().padLeft(61, '0')}',
      name: 'Phases of One Night #$i',
      symbol: 'PON',
      collection: _collectionId,
      index: i,
      collectionMaxSupply: cap,
      isPublic: true,
      balance: owned ? BigInt.one : BigInt.zero,
      decimals: 0,
      issuedSupply: BigInt.one,
      maxSupply: BigInt.one,
      metadataUri:
          'https://phases.example.invalid/c.json'
          '#b2=Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0',
    );

NyctisCollectionData _collection({int count = 10, int? cap}) =>
    groupNyctisCollections([
      for (var i = 0; i < count; i++) _piece(i, owned: i < 3, cap: cap),
    ]).collections.single;

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 396,
  double textScale = 1,
  AppThemeData theme = AppThemeData.dark,
}) async {
  await tester.binding.setSurfaceSize(Size(width + 32, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: AppTheme(
        data: theme,
        child: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('U9 an asset row is read once, as one sentence', () {
    testWidgets('label carries name, balance with unit, and note count', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, NyctisAssetRow(row: _nightCash(onTap: () {})));

      expect(
        tester.getSemantics(find.byType(NyctisAssetRow)),
        matchesSemantics(
          label: 'NightCash, 988 NC, 3 notes',
          hint: kNyctisOpenAssetHint,
          isButton: true,
          hasTapAction: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
        ),
      );
      // Not read a second time from the children, and no unlabeled image.
      expect(find.bySemanticsLabel('NightCash'), findsNothing);
      expect(find.bySemanticsLabel('988'), findsNothing);
      handle.dispose();
    });

    testWidgets('an unnamed asset says so before its id', (tester) async {
      expect(
        nyctisAssetRowSemanticsLabel(
          NyctisAssetRowData(
            assetId: _assetId,
            balance: BigInt.from(3),
            decimals: 0,
            noteCount: 1,
          ),
        ),
        'Unnamed asset b2c1f7…e5f401, 3, 1 note',
      );
    });

    testWidgets('a collection row says its count and owned count once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final row = buildNyctisCollectionRows(
        collections: [_collection(cap: 100)],
        onCollectionTap: (_) {},
      ).single;
      await _pump(tester, NyctisCollectionRow(row: row));

      expect(
        tester.getSemantics(find.byType(NyctisCollectionRow)),
        matchesSemantics(
          label:
              'Phases of One Night, 10 of at most 100 pieces, you hold 3, '
              'collection id c0ffee…e5f4aa',
          hint: kNyctisOpenCollectionHint,
          isButton: true,
          hasTapAction: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
        ),
      );
      // U30: the supporting line no longer repeats "you hold 3".
      expect(find.text('c0ffee…e5f4aa · 10 of at most 100'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a grid tile names the piece, ownership and artwork state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        SizedBox(
          width: 168,
          child: NyctisCollectionTile(
            member: _piece(3, owned: true),
            onTap: () {},
          ),
        ),
      );
      expect(
        tester.getSemantics(find.byType(NyctisCollectionTile)),
        matchesSemantics(
          label:
              'Phases of One Night #3, yours, artwork not shown, '
              'asset id pon000…000003',
          hint: kNyctisOpenPieceHint,
          isButton: true,
          hasTapAction: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
        ),
      );
      handle.dispose();
    });
  });

  group('U9 copy rows are buttons that say what they copied', () {
    testWidgets('the asset id fact is a copy button and announces', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _pump(
        tester,
        NyctisFactsCard(
          facts: [
            NyctisAssetFactData(
              label: 'Asset id',
              value: truncateNyctisAssetId(_assetId),
              copyText: _assetId,
            ),
          ],
        ),
      );

      final finder = find.bySemanticsLabel('Copy asset id, b2c1f7…e5f401');
      expect(finder, findsOneWidget);
      expect(
        tester.getSemantics(finder),
        matchesSemantics(
          label: 'Copy asset id, b2c1f7…e5f401',
          isButton: true,
          hasTapAction: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
        ),
      );

      await tester.tap(finder);
      await tester.pump();
      expect(copied, _assetId);
      final announcements = tester.takeAnnouncements();
      expect(
        announcements.map((a) => a.message),
        contains(nyctisCopiedAnnouncement('Asset id')),
      );
      await tester.pump(const Duration(seconds: 5));
      handle.dispose();
    });
  });

  group('U10 keyboard focus and hover', () {
    testWidgets('Tab focuses a row, draws the ring, Enter and Space open it', (
      tester,
    ) async {
      var opened = 0;
      await _pump(
        tester,
        NyctisAssetRow(row: _nightCash(onTap: () => opened++)),
      );
      expect(find.byKey(const ValueKey('nyctis_focus_ring')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('nyctis_focus_ring')),
        findsOneWidget,
      );
      final ring = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('nyctis_focus_ring')),
      );
      final border = (ring.decoration as BoxDecoration).border! as Border;
      expect(border.top.color, AppColors.dark.state.focusRing);
      expect(border.top.width, 2);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(opened, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(opened, 2);
    });

    testWidgets('hover paints the same wash as the ZEC activity rows', (
      tester,
    ) async {
      await _pump(tester, NyctisAssetRow(row: _nightCash(onTap: () {})));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(NyctisAssetRow)));
      await tester.pump();

      final washes = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(NyctisPressable),
              matching: find.byType(DecoratedBox),
            ),
          )
          .where(
            (box) =>
                box.decoration is BoxDecoration &&
                (box.decoration as BoxDecoration).color ==
                    AppColors.dark.state.hoverOpacity,
          );
      expect(washes, isNotEmpty);
    });

    testWidgets('grid tiles are reachable by keyboard too', (tester) async {
      var opened = false;
      await _pump(
        tester,
        SizedBox(
          width: 168,
          child: NyctisCollectionTile(
            member: _piece(1),
            onTap: () => opened = true,
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(opened, isTrue);
    });
  });

  group('U13 no overflow at u64 max or 200% text', () {
    testWidgets('a u64-max balance fits the 396px desktop card', (
      tester,
    ) async {
      await _pump(
        tester,
        NyctisAssetsFeed(
          sections: [
            NyctisAssetsSectionData(
              title: 'Supply is public',
              rows: [_nightCash(balance: _u64Max, onTap: () {})],
            ),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
      // Scaled, never clipped: the whole number is in the row.
      expect(find.text('18,446,744,073,709,551,615'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(NyctisAssetRow)).label,
        '${nyctisAssetRowTitle(_nightCash())}, '
        '18,446,744,073,709,551,615 NC, 3 notes',
      );
    });

    testWidgets('rows stack at 200% text on a 343px phone row', (
      tester,
    ) async {
      await _pump(
        tester,
        NyctisAssetsFeed(
          cardWidth: null,
          sections: [
            NyctisAssetsSectionData(
              title: 'Supply is public',
              subtitle: 'Anyone can see how many were issued.',
              rows: [
                _nightCash(
                  balance: _u64Max,
                  name: 'A name long enough to need an ellipsis at any size',
                  onTap: () {},
                ),
                _nightCash(onTap: () {}),
              ],
            ),
          ],
          collections: buildNyctisCollectionRows(
            collections: [_collection(cap: 100)],
            onCollectionTap: (_) {},
          ),
        ),
        width: 343,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('grid tiles at 200% text have room for their text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final members = _collection(count: 6).members;
      await tester.pumpWidget(
        MaterialApp(
          home: AppTheme(
            data: AppThemeData.dark,
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: CustomScrollView(
                  slivers: [
                    NyctisCollectionSliverGrid(
                      members: members,
                      tileBuilder: (context, member) => NyctisCollectionTile(
                        member: member,
                        onTap: () {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('fact rows keep their value at 200% text', (tester) async {
      await _pump(
        tester,
        NyctisFactsCard(
          title: 'Supply',
          facts: [
            NyctisAssetFactData(
              label: 'Issued supply',
              value: formatNyctisAmount(_u64Max, 0),
            ),
          ],
        ),
        width: 343,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('18,446,744,073,709,551,615'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nyctis_fact_stacked')),
        findsOneWidget,
      );
    });
  });

  group('U14 contrast', () {
    testWidgets('warning and error copy is primary text with a glyph', (
      tester,
    ) async {
      for (final theme in [AppThemeData.light, AppThemeData.dark]) {
        final colors = theme == AppThemeData.light
            ? AppColors.light
            : AppColors.dark;
        await _pump(
          tester,
          const Column(
            children: [
              NyctisMessageCard(
                text: 'Stale',
                tone: NyctisMessageTone.warning,
              ),
              NyctisMessageCard(
                text: 'Broken',
                tone: NyctisMessageTone.error,
              ),
            ],
          ),
          theme: theme,
        );
        for (final text in ['Stale', 'Broken']) {
          expect(
            tester.widget<Text>(find.text(text)).style!.color,
            colors.text.primary,
          );
        }
      }
    });

    testWidgets('the owned badge is a neutral chip with a check glyph', (
      tester,
    ) async {
      await _pump(
        tester,
        SizedBox(
          width: 168,
          child: NyctisCollectionTile(member: _piece(0, owned: true)),
        ),
        theme: AppThemeData.light,
      );
      final badge = find.byKey(const ValueKey('nyctis_owned_badge'));
      expect(badge, findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: badge,
                matching: find.text(kNyctisUniqueOwnedBadgeText),
              ),
            )
            .style!
            .color,
        AppColors.light.text.secondary,
      );
    });
  });

  group('U8 collection collisions', () {
    testWidgets('the ids are listed and accepting takes a second press', (
      tester,
    ) async {
      final collection = _collection(count: 4);
      final data = buildNyctisCollectionAcceptanceData(
        collection: collection,
        acceptance: const NyctisAssetAcceptance([
          NyctisAcceptedAsset(
            assetId:
                'aa11bb22cc33dd44ee55ff6600778899aabbccddeeff0011223344556677ff',
            name: 'Phases of One Night #0',
          ),
        ]),
      );
      expect(data.collisions.single.memberId, collection.members.first.assetId);

      var accepted = 0;
      await _pump(
        tester,
        NyctisCollectionAcceptanceCard(
          data: data,
          onAcceptAll: () => accepted++,
        ),
      );
      expect(find.text('aa11bb…5577ff', findRichText: true), findsNothing);
      expect(
        find.textContaining('aa11bb…6677ff', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('pon000…000000', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('nyctis_collection_accept_button')),
      );
      await tester.pumpAndSettle();
      expect(accepted, 0);
      await tester.tap(
        find.byKey(const ValueKey('nyctis_collection_confirm_button')),
      );
      await tester.pumpAndSettle();
      expect(accepted, 1);
    });

    testWidgets('without a collision one press accepts', (tester) async {
      var accepted = 0;
      await _pump(
        tester,
        NyctisCollectionAcceptanceCard(
          data: buildNyctisCollectionAcceptanceData(
            collection: _collection(count: 4),
            acceptance: const NyctisAssetAcceptance.empty(),
          ),
          onAcceptAll: () => accepted++,
        ),
      );
      expect(
        find.byKey(const ValueKey('nyctis_collision_panel')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('nyctis_collection_accept_button')),
      );
      await tester.pump();
      expect(accepted, 1);
    });
  });

  group('U21 warm-up progress and copy', () {
    testWidgets('running, then how many pieces it covered', (tester) async {
      NyctisCollectionAcceptanceData data(
        NyctisCollectionWarmupPhase phase, {
        bool complete = true,
      }) => buildNyctisCollectionAcceptanceData(
        collection: _collection(count: 10),
        acceptance: NyctisAssetAcceptance([
          for (final m in _collection(count: 10).members)
            NyctisAcceptedAsset(assetId: m.assetId),
        ]),
        warmupPhase: phase,
        warmupFetched: 6,
        warmupComplete: complete,
      );

      await _pump(
        tester,
        NyctisCollectionAcceptanceCard(
          data: data(NyctisCollectionWarmupPhase.running),
        ),
      );
      expect(find.text(kNyctisCollectionWarmupRunningText), findsOneWidget);

      await _pump(
        tester,
        NyctisCollectionAcceptanceCard(
          data: data(NyctisCollectionWarmupPhase.done, complete: false),
        ),
      );
      expect(
        find.textContaining('Fetched artwork for 6 of 10 pieces.'),
        findsOneWidget,
      );
      expect(find.textContaining('as you scroll'), findsOneWidget);
    });

    test('the warm-up note states its bound and the per-tile residue', () {
      final note = nyctisCollectionWarmupNote(maxBytes: 4 * 1024 * 1024);
      expect(note, contains('up to 4 MiB in total'));
      expect(note, contains('one at a time as you scroll'));
      expect(note, contains('which ones you look at'));
    });
  });

  test('a note count on a row counts unspent notes only', () {
    final asset = NyctisAssetDetailData(
      assetId: _assetId,
      balance: BigInt.one,
      decimals: 0,
      notes: [
        NyctisNoteRowData(
          position: BigInt.one,
          amount: BigInt.one,
          decimals: 0,
          createdHeight: BigInt.from(1240),
        ),
        NyctisNoteRowData(
          position: BigInt.two,
          amount: BigInt.two,
          decimals: 0,
          createdHeight: BigInt.from(1200),
          spent: true,
        ),
      ],
    );
    expect(asset.toRowData().noteCount, 1);
    expect(
      nyctisNoteLineText(0, asset.notes.first),
      'Note 1: 1, created at height 1,240',
    );
  });

  test('artwork frames are named from wallet words', () {
    expect(
      nyctisArtworkSpokenState(NyctisArtworkStatus.notAccepted),
      'artwork not shown',
    );
    expect(
      nyctisArtworkSpokenState(NyctisArtworkStatus.unpinned),
      'artwork shown, unpinned',
    );
  });
}
