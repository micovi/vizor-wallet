/// Desktop `/nyctis/collection/:collectionId` — the pieces of one
/// collection.
///
/// It is a route of its own rather than an expanding row on the assets screen,
/// and that is a memory decision before it is a navigation one. Both of this
/// feature's existing scaffolds hand out a `SingleChildScrollView`; a grid
/// nested in one lays out every child on the first frame, so a hundred
/// accepted pieces would be a hundred decoded bitmaps before anything painted.
/// On its own route the grid *is* the scrollable, so it builds the tiles the
/// viewport needs and no others.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/nyctis_assets_view_provider.dart';
import '../providers/nyctis_collection_artwork_provider.dart';
import '../providers/nyctis_collections_provider.dart';
import '../widgets/nyctis_asset_logo.dart';
import '../widgets/nyctis_asset_row_data.dart';
import '../widgets/nyctis_asset_row_mapper.dart';
import '../widgets/nyctis_assets_feed.dart';
import '../widgets/nyctis_collection_data.dart';
import '../widgets/nyctis_collection_grid.dart';
import '../widgets/nyctis_collection_mapper.dart';
import '../widgets/nyctis_collection_sections.dart';
import '../widgets/nyctis_facts_card.dart';

/// Where a collection row on the assets screen goes.
String nyctisCollectionRouteFor(String collectionId) =>
    '/nyctis/collection/$collectionId';

class NyctisCollectionScreen extends StatelessWidget {
  const NyctisCollectionScreen({required this.collectionId, super.key});

  final String collectionId;

  @override
  Widget build(BuildContext context) {
    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NyctisCollectionPane(collectionId: collectionId),
      ),
    );
  }
}

/// The pane body without the sidebar, so it renders on its own in tests and
/// in Widgetbook.
class NyctisCollectionPane extends ConsumerWidget {
  const NyctisCollectionPane({required this.collectionId, super.key});

  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(nyctisCollectionProvider(collectionId));
    final view = resolveNyctisView(ref.watch(nyctisAssetsViewProvider));

    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.max(
          0.0,
          (constraints.maxWidth - kNyctisCardWidth) / 2,
        );
        return AppPaneSliverScrollScaffold(
          toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
          padding: EdgeInsets.only(
            top: AppSpacing.sm,
            left: side,
            right: side,
            bottom: AppSpacing.base,
          ),
          slivers: buildNyctisCollectionSlivers(
            collectionId: collectionId,
            collection: collection,
            view: view,
            showTitle: true,
            onMemberTap: (assetId) => context.push('/nyctis/$assetId'),
          ),
        );
      },
    );
  }
}

/// The slivers both form factors render, in order: title, the collection's
/// own facts, the acceptance card, then the lazy grid.
///
/// The acceptance card sits **above** the grid deliberately. It is the thing
/// that decides whether the grid has pictures in it, and putting it below
/// would leave a screen of empty frames with no visible explanation until the
/// user scrolled past them.
///
/// [view] is the resolved channel view, or null while the first read is in
/// flight. A missing [collection] means "loading" until the view resolves:
/// a deep link or a restored route used to open on "this wallet has read no
/// pieces of this collection" for as long as the indexer took to answer.
List<Widget> buildNyctisCollectionSlivers({
  required String collectionId,
  required NyctisCollectionData? collection,
  required void Function(String assetId) onMemberTap,
  NyctisViewData? view,
  bool showTitle = true,
  double horizontalPadding = 0,
}) {
  final pad = EdgeInsets.symmetric(horizontal: horizontalPadding);
  if (collection == null) {
    final listError = view == null ? null : nyctisListErrorText(view);
    final NyctisMessageCard card;
    if (view == null) {
      card = const NyctisMessageCard(
        key: ValueKey('nyctis_collection_loading'),
        text: kNyctisCollectionLoadingText,
        width: null,
        loading: true,
        liveRegion: true,
      );
    } else if (listError != null) {
      card = NyctisMessageCard(
        key: const ValueKey('nyctis_collection_error'),
        text: listError,
        detail: nyctisListErrorDetail(view),
        width: null,
        tone: nyctisListErrorTone(view),
      );
    } else {
      card = NyctisMessageCard(
        key: const ValueKey('nyctis_collection_missing'),
        text: nyctisUnknownCollectionText(collectionId),
        width: null,
      );
    }
    return [
      SliverPadding(
        padding: pad,
        sliver: SliverToBoxAdapter(child: card),
      ),
    ];
  }

  return [
    SliverPadding(
      padding: pad,
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drawn whether or not the title is, because it is not the title:
            // on the phone the top nav carries the name and the collection
            // would otherwise be the one surface with a `logo` and nowhere to
            // put it.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
              child: NyctisCollectionHeader(
                collection: collection,
                showTitle: showTitle,
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            NyctisCollectionFactsSection(collection: collection),
            NyctisCollectionAcceptanceSection(collection: collection),
            // Draws nothing; it is where accepting turns into requests. See
            // the widget's own comment for why the set it asks for is the
            // whole collection rather than the accepted subset.
            NyctisCollectionArtworkWarmup(collectionId: collectionId),
            const SizedBox(height: AppSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
              child: _PrivacyNote(),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    ),
    SliverPadding(
      padding: pad,
      sliver: NyctisCollectionSliverGrid(
        key: const ValueKey('nyctis_collection_grid'),
        members: collection.members,
        tileBuilder: (context, member) => NyctisCollectionMemberTile(
          key: ValueKey('nyctis_collection_tile_${member.assetId}'),
          member: member,
          onTap: () => onMemberTap(member.assetId),
        ),
      ),
    ),
  ];
}

/// The collection's facts, its footnote, and the one sentence that is owed
/// only when the document and the chain disagree.
///
/// A widget of its own because the disagreement is the one thing on this card
/// that needs a provider: `asset-collection-v0.md` section 3.1 says a wallet
/// **MUST** compare the document's `max_supply` against the on-chain cap and
/// **SHOULD** say so where it shows a count, and the document's number arrives
/// through the acceptance-gated fetch rather than through the replay. Keeping
/// it here leaves [buildNyctisCollectionSlivers] a pure function of the
/// collection, which is what lets both form factors call it and the tests
/// render it without a container.
class NyctisCollectionFactsSection extends ConsumerWidget {
  const NyctisCollectionFactsSection({required this.collection, super.key});

  final NyctisCollectionData collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final documentMaxSupply = ref.watch(
      nyctisCollectionDocumentMaxSupplyProvider(collection.collectionId),
    );
    final disagreement = nyctisCollectionCapDisagreementText(
      collection: collection,
      documentMaxSupply: documentMaxSupply,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        NyctisFactsCard(
          key: const ValueKey('nyctis_collection_facts'),
          title: 'Collection',
          facts: buildNyctisCollectionFacts(collection),
          // Two footnotes, chosen rather than merged: a capped collection and
          // an uncapped one owe the user different sentences, and the old one
          // — "nothing in a collection id says how many there should be" —
          // became false for the capped half at `transition-v0.md` revision 11.
          footnote: nyctisCollectionCountNote(collection),
        ),
        if (disagreement != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
            child: Text(
              disagreement,
              key: const ValueKey('nyctis_collection_cap_disagreement'),
              style: AppTypography.bodySmall.copyWith(
                color: context.colors.text.secondary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The collection's face, its name, its `collection_id` and its counts.
///
/// **The id line is not optional and used to be missing.** Section 5 requires
/// `collection_id`, or an unambiguous abbreviation of it, wherever a
/// collection's name is shown — two collections may share a `name`, only one
/// can share an id — and section 3.5 sharpens that for a picture, because a
/// name and a symbol are a weak imitation and a name with the right picture is
/// a convincing one (`asset-metadata-v0.md` section 1.1). A previous revision
/// of this header carried a comment saying "this line is what identifies the
/// collection" above a line that renders the *counts*; the id was on the
/// screen only because the facts card below happens to list it. It is now
/// beside the name, where the rule asks for it.
class NyctisCollectionHeader extends ConsumerWidget {
  const NyctisCollectionHeader({
    required this.collection,
    this.showTitle = true,
    super.key,
  });

  final NyctisCollectionData collection;

  /// False on the phone, where the top nav already carries the name. The
  /// picture, the id and the provenance are drawn either way.
  final bool showTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final artwork = ref.watch(
      nyctisCollectionArtworkProvider(collection.collectionId),
    );
    // Sections 3.5 and 3.3, in one sentence and in this place on purpose: both
    // put the declared/derived and the pinned/unpinned statements "where it
    // says where the picture came from", and this screen is where that is.
    final provenance = nyctisCollectionArtworkProvenanceText(artwork);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NyctisArtwork(
          key: const ValueKey('nyctis_collection_artwork'),
          bytes: artwork.artwork.bytes,
          size: kNyctisCollectionHeaderArtworkSize,
          semanticLabel:
              'Artwork for ${nyctisCollectionTitle(collection)}, '
              '${nyctisArtworkSpokenState(artwork.artwork.status)}',
          // No sentence in the frame, deliberately. A tile has to explain
          // itself because nothing near it does; this frame sits directly
          // above the acceptance card, which already says that artwork is
          // fetched only after the user accepts a piece. Repeating it here
          // would be the same sentence twice in 72 pixels.
          //
          // Not a tile: see [kNyctisCollectionArtworkImageKey].
          imageKey: kNyctisCollectionArtworkImageKey,
        ),
        const SizedBox(width: AppSpacing.s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showTitle) ...[
                Semantics(
                  header: true,
                  child: Text(
                    nyctisCollectionTitle(collection),
                    key: const ValueKey('nyctis_collection_title'),
                    style: AppTypography.headlineLarge.copyWith(
                      color: colors.text.accent,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xxs),
              ],
              Text(
                nyctisCollectionSubtitle(collection),
                key: const ValueKey('nyctis_collection_header_id'),
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.secondary,
                ),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                nyctisCollectionCountText(collection),
                key: const ValueKey('nyctis_collection_count'),
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.primary,
                ),
              ),
              if (provenance != null) ...[
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  provenance,
                  key: const ValueKey('nyctis_collection_provenance'),
                  style: AppTypography.bodySmall.copyWith(
                    color: colors.text.secondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Side of the collection's face on its own screen.
///
/// Smaller than a piece's [kNyctisUniqueArtworkSize]: the collection's
/// picture is a heading, and the pieces below it are the point of the screen.
const double kNyctisCollectionHeaderArtworkSize = 72;

class _PrivacyNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Text(
      kNyctisCollectionPrivacyNote,
      style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
    );
  }
}
