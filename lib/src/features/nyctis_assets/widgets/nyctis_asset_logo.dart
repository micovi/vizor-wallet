/// Drawing an issuer-supplied logo, under sections 4.2 and 5 of
/// `spec/asset-metadata-v0.md`.
///
/// Two rules are enforced *above* this widget and one inside it.
///
/// Above: nothing hands [NyctisAssetLogoImage] bytes for an asset the user
/// has not explicitly accepted (section 5), and nothing hands it bytes that
/// were not sniffed as PNG, JPEG or WebP and checked against their `b2`
/// (section 4.2). By the time a byte reaches this file it has been decided
/// about; the widget's job is to draw it without becoming a new surface.
///
/// Inside: the decode is bounded. Section 4.2 requires that an image cannot be
/// made to consume unbounded memory by its *declared* dimensions — so the
/// declared `width` and `height` are never parsed at all (see
/// [NyctisAssetLogoRef]), the box is a fixed size the caller picks, and
/// `cacheWidth`/`cacheHeight` make the engine downsample during decode rather
/// than materialise a 20 000-pixel bitmap and scale it afterwards.
///
/// A logo that fails to decode falls back to the same icon an asset without
/// one gets. It is decoration; it is never the difference between a rendered
/// row and a missing one.
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import 'nyctis_artwork_data.dart';

/// Upper bound on the pixels the engine is asked to decode, whatever the
/// device pixel ratio claims. A logo is never drawn larger than this.
///
/// It is the right number for a row and for a grid tile and it is the wrong
/// number for a piece of artwork shown at 320 logical pixels: at a device
/// pixel ratio of 3 that wants 960, and 256 upscaled four times is visibly
/// soft. [kNyctisArtworkMaxDecodePixels] is the bound for that case, and it
/// is a bound rather than "the natural size" for the reason section 4.2 gives
/// — the dimensions in an image's own header are attacker-chosen and a
/// compression bomb hides an enormous one inside a file well under the size
/// limit.
const int kNyctisLogoMaxDecodePixels = 256;

/// The same bound for a single hero image.
///
/// Four times the pixels of [kNyctisLogoMaxDecodePixels], so 4 MiB of
/// bitmap rather than 256 KiB. That is affordable precisely because there is
/// one of them: a grid must not use it, and the parameter is on the widget
/// rather than on a flag so that using it is a decision made per call site.
const int kNyctisArtworkMaxDecodePixels = 1024;

/// The key on an asset's or a piece's drawn logo. One asset, one of these.
const Key kNyctisLogoImageKey = ValueKey('nyctis_logo_image');

/// The key on a *collection's* face, wherever one is drawn.
///
/// A separate key because it is a separate claim: a tile's picture is one
/// piece's artwork and a collection's face is either the collection's declared
/// `logo` or a piece's artwork standing in for it
/// (`spec/asset-collection-v0.md` section 3.5). A test that counts "how many
/// pieces drew a picture" must not count the heading, and one that asks
/// whether the collection has a face must not be satisfied by a tile.
const Key kNyctisCollectionArtworkImageKey = ValueKey(
  'nyctis_collection_artwork_image',
);

/// One asset's logo at [size], or [fallback] when there is none.
class NyctisAssetLogoImage extends StatelessWidget {
  const NyctisAssetLogoImage({
    required this.bytes,
    required this.size,
    this.fallback,
    this.borderRadius,
    this.maxDecodePixels = kNyctisLogoMaxDecodePixels,
    this.imageKey = kNyctisLogoImageKey,
    super.key,
  });

  /// Verified image bytes, or null.
  final Uint8List? bytes;

  final double size;

  /// Drawn when [bytes] is null or does not decode.
  final Widget? fallback;

  /// Corner rounding. Null keeps the circular treatment a row's leading
  /// square has always had; artwork passes a rectangle's radius, because a
  /// picture of a thing cropped to a circle is a picture of part of a thing.
  final BorderRadius? borderRadius;

  /// Ceiling on the decoded bitmap's side, in device pixels.
  final int maxDecodePixels;

  /// The key on the drawn `Image`.
  ///
  /// Overridden where a surface draws a picture that is *not* one asset's —
  /// a collection's face is the collection's, not the fifth tile's, and a
  /// count of "how many pieces have artwork" must not silently include it.
  final Key imageKey;

  @override
  Widget build(BuildContext context) {
    final bytes = this.bytes;
    final fallback =
        this.fallback ??
        SizedBox.square(
          dimension: size,
          key: const ValueKey('nyctis_logo_absent'),
        );
    if (bytes == null) return fallback;
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final decodeSize = (size * ratio).ceil().clamp(1, maxDecodePixels);
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(size / 2),
      child: SizedBox.square(
        dimension: size,
        child: Image.memory(
          bytes,
          key: imageKey,
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: decodeSize,
          cacheHeight: decodeSize,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          // Bytes that pass the sniff can still be a truncated or malformed
          // file. That costs the picture and nothing else.
          errorBuilder: (context, error, stack) => fallback,
          // The asset id is beside every logo (section 5) and the name is in
          // the row; an issuer-chosen alt string would only be a third
          // untrusted label read aloud as if it were a fact.
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}

/// The leading avatar of an asset row: the accepted logo, or a neutral glyph
/// for the kind of asset it is.
///
/// The same circle, size and background as every Vizor activity row
/// ([AppAssetSize]), so a Nyctis list reads like the rest of the wallet.
///
/// The glyph says what the asset *is* — a balance of something, or one unique
/// item — and nothing about privacy. It used to be a globe for an asset whose
/// issued supply is public and a shield for one whose supply is private, and
/// a globe beside a balance reads as "everyone can see what I hold", which is
/// false for every Nyctis asset.
class NyctisAssetLeading extends StatelessWidget {
  const NyctisAssetLeading({
    required this.logoBytes,
    this.isUniqueItem = false,
    this.size = AppAssetSize.size,
    super.key,
  });

  final Uint8List? logoBytes;
  final bool isUniqueItem;
  final double size;

  @override
  Widget build(BuildContext context) {
    return NyctisAvatar(
      size: size,
      iconName: isUniqueItem ? AppIcons.scroll : AppIcons.coins,
      bytes: logoBytes,
    );
  }
}

/// A circular [AppAssetSize] avatar holding either verified image bytes or a
/// glyph. Decorative: the row it sits in names the asset.
class NyctisAvatar extends StatelessWidget {
  const NyctisAvatar({
    required this.iconName,
    this.bytes,
    this.size = AppAssetSize.size,
    this.borderRadius,
    this.imageKey = kNyctisLogoImageKey,
    super.key,
  });

  final String iconName;
  final Uint8List? bytes;
  final double size;

  /// Null draws a circle; a collection's face passes a rounded rectangle.
  final BorderRadius? borderRadius;
  final Key imageKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final glyph = Center(
      child: AppIcon(
        iconName,
        size: AppAssetSize.icon,
        color: colors.icon.regular,
      ),
    );
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.background.neutralSubtleOpacity,
            shape: borderRadius == null ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: borderRadius,
          ),
          child: bytes == null
              ? glyph
              : NyctisAssetLogoImage(
                  bytes: bytes,
                  size: size,
                  borderRadius: borderRadius,
                  imageKey: imageKey,
                  fallback: glyph,
                ),
        ),
      ),
    );
  }
}

/// The leading square of a collection row: the collection's face, or the icon
/// that stood there before collections had one.
///
/// It is a rounded rectangle and not a circle, for the reason
/// [NyctisAssetLogoImage.borderRadius] gives: a picture of a thing cropped
/// to a circle is a picture of part of a thing, and a collection's `logo` is a
/// picture rather than a token mark.
///
/// Whether there are bytes here at all was decided upstream by
/// `nyctisCollectionArtworkProvider`, which gates on acceptance —
/// `spec/asset-collection-v0.md` section 3.5 puts a collection's picture under
/// the same rule as an asset's. This widget cannot check that and does not try.
class NyctisCollectionLeading extends StatelessWidget {
  const NyctisCollectionLeading({
    required this.artwork,
    this.size = AppAssetSize.size,
    super.key,
  });

  final NyctisCollectionArtworkData artwork;
  final double size;

  @override
  Widget build(BuildContext context) {
    return NyctisAvatar(
      size: size,
      iconName: AppIcons.book,
      bytes: artwork.artwork.bytes,
      borderRadius: BorderRadius.circular(AppRadii.small),
      imageKey: kNyctisCollectionArtworkImageKey,
    );
  }
}
