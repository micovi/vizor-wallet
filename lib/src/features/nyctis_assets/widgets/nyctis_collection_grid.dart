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
///   `NyAsset` entries, and if every one of them were an `Image.memory` in a
///   `Column` inside a `SingleChildScrollView`, opening the screen would
///   decode a hundred bitmaps at once. [NyctisCollectionSliverGrid] is a
///   `SliverGrid.builder`, so the count is bounded by the viewport.
/// * **The decode is bounded per tile.** [NyctisAssetLogoImage] clamps at
///   [kNyctisLogoMaxDecodePixels], which at tile scale is the binding limit
///   rather than a formality: a 512×512 PNG drawn in a 150-pixel tile on a
///   3× phone would otherwise ask for 450 and, from a hostile file, for
///   whatever the header claims.
library;

import 'dart:typed_data';

import 'dart:math' as math;

import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:flutter/widgets.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import 'nyctis_artwork_data.dart';
import 'nyctis_asset_logo.dart';
import 'nyctis_asset_row_data.dart';
import 'nyctis_collection_mapper.dart';
import 'nyctis_interactive.dart';

/// Widest a member tile is allowed to get. The grid fits as many columns of
/// at most this width as the pane allows, so one delegate serves a 396-pixel
/// desktop pane and a 390-pixel phone without a form-factor branch.
const double kNyctisCollectionTileMaxExtent = 168;

/// Gap between tiles across a row, and between rows.
const double kNyctisCollectionTileCrossSpacing = AppSpacing.xs;
const double kNyctisCollectionTileMainSpacing = AppSpacing.sm;

/// Height of a tile whose square artwork is [tileWidth] wide: the artwork,
/// then the two text lines at the current text scale.
///
/// Measured rather than fixed. A fixed aspect ratio left room for two lines at
/// 100% text and overflowed every tile at 200%.
double nyctisCollectionTileExtent(BuildContext context, double tileWidth) {
  final scaler = MediaQuery.textScalerOf(context);
  final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
  double lineHeight(TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: 'Ag#·', style: style),
      textScaler: scaler,
      textDirection: direction,
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  return tileWidth +
      AppSpacing.xxs +
      lineHeight(_tileTitleStyle) * kNyctisCollectionTileTitleLines +
      lineHeight(_tileSubtitleStyle) +
      // Rounding headroom: layout rounds each line up to the pixel grid.
      2;
}

/// Lines a tile's name may take. Two, so a name like "Phases of One Night
/// #12" is not cut to "PHASE…" at large text sizes.
const int kNyctisCollectionTileTitleLines = 2;

final TextStyle _tileTitleStyle = AppTypography.labelLarge.copyWith(
  fontWeight: FontWeight.w600,
);
const TextStyle _tileSubtitleStyle = AppTypography.labelSmall;

/// A square frame holding one asset's artwork, or saying why it is empty.
///
/// The frame is drawn whether or not there are bytes, on purpose. A piece
/// with no accepted artwork is still a piece, and a grid that collapses its
/// unaccepted tiles would make accepting look like the way to make the
/// collection appear.
class NyctisArtwork extends StatelessWidget {
  const NyctisArtwork({
    required this.bytes,
    required this.size,
    this.emptyText,
    this.maxDecodePixels = kNyctisLogoMaxDecodePixels,
    this.imageKey = kNyctisLogoImageKey,
    this.semanticLabel,
    this.footer,
    super.key,
  });

  /// Wallet-authored accessible name for the frame, e.g. `Artwork for #3,
  /// artwork not shown`. Null leaves the frame out of the semantics tree —
  /// right where the surrounding control already names it.
  final String? semanticLabel;

  /// Drawn inside the empty frame under [emptyText], e.g. the "Show artwork"
  /// button on a piece's own page.
  final Widget? footer;

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
  /// hero image passes [kNyctisArtworkMaxDecodePixels].
  final int maxDecodePixels;

  /// Key on the drawn image. A collection's face passes
  /// [kNyctisCollectionArtworkImageKey]; see there for why it is not a tile.
  final Key imageKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(AppRadii.medium);
    final emptyText = this.emptyText;

    final glyph = ExcludeSemantics(
      child: AppIcon(
        AppIcons.scroll,
        size: AppIconSize.large,
        color: colors.icon.muted,
      ),
    );
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
              ? glyph
              : Padding(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  // Scales down rather than overflowing the square when the
                  // user's text size makes three lines taller than the frame.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: size - AppSpacing.xs * 2 > 0
                          ? size - AppSpacing.xs * 2
                          : size,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          glyph,
                          const SizedBox(height: AppSpacing.xxs),
                          ExcludeSemantics(
                            child: Text(
                              emptyText,
                              textAlign: TextAlign.center,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.labelSmall.copyWith(
                                color: colors.text.secondary,
                              ),
                            ),
                          ),
                          if (footer != null) ...[
                            const SizedBox(height: AppSpacing.xs),
                            footer!,
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );

    final frame = NyctisAssetLogoImage(
      key: const ValueKey('nyctis_artwork'),
      bytes: bytes,
      size: size,
      borderRadius: radius,
      maxDecodePixels: maxDecodePixels,
      imageKey: imageKey,
      fallback: placeholder,
    );
    final label = semanticLabel;
    if (label == null) return ExcludeSemantics(child: frame);
    // The frame is one image with a wallet-authored name; the empty-frame
    // sentence and the glyph are excluded above. A footer button stays its
    // own node inside it, so it can still be reached and pressed.
    return Semantics(
      container: true,
      image: true,
      label: label,
      child: footer == null ? ExcludeSemantics(child: frame) : frame,
    );
  }
}

/// One member of a collection, as a grid tile.
///
/// Presentational: it takes the member's plain record and whatever bytes the
/// caller decided it may draw, so a test renders a hundred of these without a
/// provider, a fetcher, or a network.
class NyctisCollectionTile extends StatelessWidget {
  const NyctisCollectionTile({
    required this.member,
    this.artwork = const NyctisArtworkData.notAccepted(),
    this.onTap,
    super.key,
  });

  final NyctisAssetDetailData member;

  /// The piece's artwork and the state it is in.
  ///
  /// It is the whole [NyctisArtworkData] rather than bytes-or-null because
  /// the states that carry no bytes are not interchangeable: "not accepted",
  /// "fetching" and "refused" all used to draw the one string "Not fetched",
  /// and a digest mismatch reading as a slow network is how a missing
  /// implementation looked like a missing picture. Defaults to not-accepted,
  /// which is the state a fixture and an unaccepted piece share and the only
  /// safe default for a value that decides whether an issuer's picture is
  /// drawn.
  final NyctisArtworkData artwork;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final title = nyctisCollectionMemberTitle(member);
    final subtitle = nyctisCollectionMemberSubtitle(member);
    final owned = member.ownsUniqueItem;
    final semanticsLabel = nyctisCollectionTileSemanticsLabel(
      member: member,
      status: artwork.status,
    );

    final content = LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                NyctisArtwork(
                  bytes: artwork.bytes,
                  size: side,
                  emptyText: nyctisArtworkTileText(artwork.status),
                ),
                // Holding is the one thing about a piece that is this
                // wallet's alone, so it is the one badge worth the corner.
                if (owned)
                  const Positioned(
                    top: AppSpacing.xxs,
                    right: AppSpacing.xxs,
                    child: NyctisArtworkBadge(
                      key: ValueKey('nyctis_owned_badge'),
                      text: kNyctisUniqueOwnedBadgeText,
                      iconName: AppIcons.check,
                    ),
                  ),
                // `spec/asset-collection-v0.md` section 3.3: a piece whose
                // image nothing pins is **unpinned, not invalid**, and a
                // wallet SHOULD say so. On a tile there is room for one word,
                // and this is the word — without it a pinned and an unpinned
                // picture are the same picture, and publishing `digests`
                // bought the user nothing.
                if (artwork.status == NyctisArtworkStatus.unpinned)
                  const Positioned(
                    bottom: AppSpacing.xxs,
                    left: AppSpacing.xxs,
                    child: NyctisArtworkBadge(
                      key: ValueKey('nyctis_artwork_unpinned_badge'),
                      text: kNyctisArtworkUnpinnedBadgeText,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              title,
              maxLines: kNyctisCollectionTileTitleLines,
              overflow: TextOverflow.ellipsis,
              style: _tileTitleStyle.copyWith(color: colors.text.accent),
            ),
            Text(
              subtitle,
              key: const ValueKey('nyctis_collection_tile_asset_id'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _tileSubtitleStyle.copyWith(color: colors.text.secondary),
            ),
          ],
        );
      },
    );

    if (onTap == null) {
      return Semantics(
        container: true,
        label: semanticsLabel,
        excludeSemantics: true,
        child: content,
      );
    }
    return NyctisPressable(
      onPressed: onTap,
      semanticsLabel: semanticsLabel,
      semanticsHint: kNyctisOpenPieceHint,
      borderRadius: AppRadii.medium,
      child: content,
    );
  }
}

/// Spoken after a tile's label.
const String kNyctisOpenPieceHint = 'Opens piece';

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
class NyctisArtworkBadge extends StatelessWidget {
  const NyctisArtworkBadge({required this.text, this.iconName, super.key});

  final String text;

  /// A glyph before [text], so the badge is not told apart by colour alone.
  final String? iconName;

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
          vertical: AppSpacing.xxs / 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (iconName != null) ...[
              AppIcon(
                iconName!,
                // The glyph sits on the text's own line height.
                size: AppTypography.labelSmall.fontSize ?? AppIconSize.medium,
                color: colors.icon.regular,
              ),
              const SizedBox(width: AppSpacing.xxs / 2),
            ],
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.labelSmall.copyWith(
                  color: colors.text.secondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The word in the corner of a tile the wallet holds.
const String kNyctisUniqueOwnedBadgeText = 'Yours';

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
class NyctisCollectionSliverGrid extends StatelessWidget {
  const NyctisCollectionSliverGrid({
    required this.members,
    required this.tileBuilder,
    super.key,
  });

  final List<NyctisAssetDetailData> members;

  /// Builds one tile. The screens pass a builder that reads this piece's own
  /// logo provider, so only a tile that exists subscribes to one — and only a
  /// tile that exists can cause a fetch.
  final Widget Function(BuildContext context, NyctisAssetDetailData member)
  tileBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, SliverConstraints constraints) {
        final width = constraints.crossAxisExtent;
        // The same column count `SliverGridDelegateWithMaxCrossAxisExtent`
        // would pick, so no tile is wider than the max extent.
        final columns = math.max(
          1,
          (width /
                  (kNyctisCollectionTileMaxExtent +
                      kNyctisCollectionTileCrossSpacing))
              .ceil(),
        );
        final tileWidth =
            (width - kNyctisCollectionTileCrossSpacing * (columns - 1)) /
            columns;
        return SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: kNyctisCollectionTileMainSpacing,
            crossAxisSpacing: kNyctisCollectionTileCrossSpacing,
            mainAxisExtent: nyctisCollectionTileExtent(context, tileWidth),
          ),
          itemCount: members.length,
          itemBuilder: (context, index) => tileBuilder(context, members[index]),
        );
      },
    );
  }
}
