/// The artwork frame, the member tile, and the lazy grid they live in.
///
/// Three constraints shape everything here, and two of them are the reason
/// this is a grid of *slivers* rather than a `Column` of tiles.
///
/// * **Nothing is fetched to fill it.** A tile for a piece the user has not
///   accepted draws an empty frame and says so. `spec/asset-metadata-v0.md`
///   section 3.1 forbids fetching because a wallet holds something, and
///   "the grid looked patchy" is the most tempting reason there is to break
///   that rule.
/// * **Only visible tiles are built.** A hundred-piece collection is a hundred
///   `NjAsset` entries, and if every one of them were an `Image.memory` in a
///   `Column` inside a `SingleChildScrollView`, opening the screen would
///   decode a hundred bitmaps at once. [NightjarCollectionSliverGrid] is a
///   `SliverGrid.builder`, so the count is bounded by the viewport.
/// * **The decode is bounded per tile.** [NightjarAssetLogoImage] clamps at
///   [kNightjarLogoMaxDecodePixels], which at tile scale is the binding limit
///   rather than a formality: a 512×512 PNG drawn in a 150-pixel tile on a
///   3× phone would otherwise ask for 450 and, from a hostile file, for
///   whatever the header claims.
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/app_tappable.dart';
import 'nightjar_artwork_data.dart';
import 'nightjar_asset_logo.dart';
import 'nightjar_asset_row_data.dart';
import 'nightjar_collection_mapper.dart';

/// Widest a member tile is allowed to get. The grid fits as many columns of
/// at most this width as the pane allows, so one delegate serves a 396-pixel
/// desktop pane and a 390-pixel phone without a form-factor branch.
const double kNightjarCollectionTileMaxExtent = 168;

/// Tile width divided by tile height. The artwork is square and takes the
/// full width; the remainder carries the name and the asset id.
const double kNightjarCollectionTileAspectRatio = 0.72;

/// A square frame holding one asset's artwork, or saying why it is empty.
///
/// The frame is drawn whether or not there are bytes, on purpose. A piece
/// with no accepted artwork is still a piece, and a grid that collapses its
/// unaccepted tiles would make accepting look like the way to make the
/// collection appear.
class NightjarArtwork extends StatelessWidget {
  const NightjarArtwork({
    required this.bytes,
    required this.size,
    this.emptyText,
    this.maxDecodePixels = kNightjarLogoMaxDecodePixels,
    this.imageKey = kNightjarLogoImageKey,
    super.key,
  });

  /// Verified bytes for an asset the user has **accepted**, or null.
  ///
  /// Null is the normal state. Whoever fills this in has already checked
  /// acceptance; this widget cannot, and does not try.
  final Uint8List? bytes;

  final double size;

  /// Shown inside the empty frame. Null draws the icon alone, which is what a
  /// tile too small for a sentence gets.
  final String? emptyText;

  /// Ceiling on the decoded bitmap's side. Tiles keep the default; a single
  /// hero image passes [kNightjarArtworkMaxDecodePixels].
  final int maxDecodePixels;

  /// Key on the drawn image. A collection's face passes
  /// [kNightjarCollectionArtworkImageKey]; see there for why it is not a tile.
  final Key imageKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(AppRadii.medium);
    final emptyText = this.emptyText;

    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background.base,
        borderRadius: radius,
        border: Border.all(color: colors.border.subtle),
      ),
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: emptyText == null
              ? AppIcon(
                  AppIcons.scroll,
                  size: AppIconSize.large,
                  color: colors.icon.muted,
                )
              : Padding(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(
                        AppIcons.scroll,
                        size: AppIconSize.large,
                        color: colors.icon.muted,
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        emptyText,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.labelSmall.copyWith(
                          color: colors.text.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );

    return NightjarAssetLogoImage(
      key: const ValueKey('nightjar_artwork'),
      bytes: bytes,
      size: size,
      borderRadius: radius,
      maxDecodePixels: maxDecodePixels,
      imageKey: imageKey,
      fallback: placeholder,
    );
  }
}

/// One member of a collection, as a grid tile.
///
/// Presentational: it takes the member's plain record and whatever bytes the
/// caller decided it may draw, so a test renders a hundred of these without a
/// provider, a fetcher, or a network.
class NightjarCollectionTile extends StatelessWidget {
  const NightjarCollectionTile({
    required this.member,
    this.artwork = const NightjarArtworkData.notAccepted(),
    this.onTap,
    super.key,
  });

  final NightjarAssetDetailData member;

  /// The piece's artwork and the state it is in.
  ///
  /// It is the whole [NightjarArtworkData] rather than bytes-or-null because
  /// the states that carry no bytes are not interchangeable: "not accepted",
  /// "fetching" and "refused" all used to draw the one string "Not fetched",
  /// and a digest mismatch reading as a slow network is how a missing
  /// implementation looked like a missing picture. Defaults to not-accepted,
  /// which is the state a fixture and an unaccepted piece share and the only
  /// safe default for a value that decides whether an issuer's picture is
  /// drawn.
  final NightjarArtworkData artwork;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final title = nightjarCollectionMemberTitle(member);
    final subtitle = nightjarCollectionMemberSubtitle(member);
    final owned = member.ownsUniqueItem;

    final content = LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                NightjarArtwork(
                  bytes: artwork.bytes,
                  size: side,
                  emptyText: nightjarArtworkTileText(artwork.status),
                ),
                // Holding is the one thing about a piece that is this
                // wallet's alone, so it is the one badge worth the corner.
                if (owned)
                  Positioned(
                    top: AppSpacing.xxs,
                    right: AppSpacing.xxs,
                    child: _OwnedBadge(),
                  ),
                // `spec/asset-collection-v0.md` section 3.3: a piece whose
                // image nothing pins is **unpinned, not invalid**, and a
                // wallet SHOULD say so. On a tile there is room for one word,
                // and this is the word — without it a pinned and an unpinned
                // picture are the same picture, and publishing `digests`
                // bought the user nothing.
                if (artwork.status == NightjarArtworkStatus.unpinned)
                  const Positioned(
                    bottom: AppSpacing.xxs,
                    left: AppSpacing.xxs,
                    child: NightjarArtworkBadge(
                      key: ValueKey('nightjar_artwork_unpinned_badge'),
                      text: kNightjarArtworkUnpinnedBadgeText,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.labelLarge.copyWith(
                color: colors.text.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              subtitle,
              key: const ValueKey('nightjar_collection_tile_asset_id'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.labelSmall.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
        );
      },
    );

    if (onTap == null) return content;
    return AppTappable(
      onTap: onTap,
      semanticsLabel: '$title, $subtitle',
      child: content,
    );
  }
}

class _OwnedBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background.utilitySuccessStrong,
        borderRadius: BorderRadius.circular(AppRadii.small),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xxs,
          vertical: 1,
        ),
        child: Text(
          kNightjarUniqueOwnedBadgeText,
          style: AppTypography.labelSmall.copyWith(color: colors.text.inverse),
        ),
      ),
    );
  }
}

/// One word about a picture that is drawn, beside or on top of it.
///
/// Deliberately quiet — a neutral chip, not a warning colour — and shared by
/// the two claims a wallet has to make about artwork it is showing:
///
/// * **Unpinned** (`spec/asset-collection-v0.md` section 3.3). The publisher
///   shipped no digest for these bytes, which is the ordinary state of a
///   collection that grew after publication (section 6, T3) and is explicitly
///   *not invalid*. Painting it as an alarm would teach users to ignore it,
///   and the one case that *is* an alarm — a digest that did not match — never
///   reaches here, because those bytes were discarded.
/// * **Derived** (section 3.5.1). The collection published no picture of its
///   own, so what is on screen is one member's artwork standing in. A wallet
///   **MUST** say so rather than let an inference of its own pass for a
///   statement by the issuer.
///
/// One widget for both because the discipline is one discipline: a distinction
/// the user cannot see is not a distinction, and two chips drawn by two
/// slightly different private classes is how one of them ends up looking like
/// an error and the other like a decoration.
class NightjarArtworkBadge extends StatelessWidget {
  const NightjarArtworkBadge({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background.base,
        borderRadius: BorderRadius.circular(AppRadii.small),
        border: Border.all(color: colors.border.subtle),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xxs,
          vertical: 1,
        ),
        child: Text(
          text,
          style: AppTypography.labelSmall.copyWith(
            color: colors.text.secondary,
          ),
        ),
      ),
    );
  }
}

/// The word in the corner of a tile the wallet holds.
const String kNightjarUniqueOwnedBadgeText = 'Yours';

/// The members of a collection, lazily.
///
/// A sliver rather than a widget so that it is the *only* lazy thing between
/// the tiles and the scroll view. Wrapping a `GridView` with `shrinkWrap:
/// true` inside a `SingleChildScrollView` — which is what both of this
/// feature's existing scaffolds hand out — lays out every child on the first
/// frame, and for a hundred accepted pieces that is a hundred decodes before
/// anything is painted. This form builds what the viewport needs and nothing
/// else, which is the whole answer to the hundred-image problem at the widget
/// layer.
class NightjarCollectionSliverGrid extends StatelessWidget {
  const NightjarCollectionSliverGrid({
    required this.members,
    required this.tileBuilder,
    super.key,
  });

  final List<NightjarAssetDetailData> members;

  /// Builds one tile. The screens pass a builder that reads this piece's own
  /// logo provider, so only a tile that exists subscribes to one — and only a
  /// tile that exists can cause a fetch.
  final Widget Function(BuildContext context, NightjarAssetDetailData member)
  tileBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverGrid.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: kNightjarCollectionTileMaxExtent,
        mainAxisSpacing: AppSpacing.sm,
        crossAxisSpacing: AppSpacing.xs,
        childAspectRatio: kNightjarCollectionTileAspectRatio,
      ),
      itemCount: members.length,
      itemBuilder: (context, index) => tileBuilder(context, members[index]),
    );
  }
}
