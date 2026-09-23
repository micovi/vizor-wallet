import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// An image an activity row draws in place of [ActivityRowData
/// .leadingIconName] — today, an issuer-published asset logo the wallet has
/// already fetched and verified.
///
/// **[identityLabel] is required, and that is the whole design.**
/// `spec/asset-metadata-v0.md` section 5 says a wallet MUST show `asset_id`,
/// or an unambiguous abbreviation of it, *wherever* it shows a logo — because
/// the signed `name` a row uses as its title is not identifying, and a name
/// plus the right picture is the convincing impersonation section 1.1
/// describes. An activity row is a small surface and dropping the id there is
/// the tempting shortcut, so the type makes it impossible: there is no way to
/// hand a row bytes without also handing it the id, and the row widget draws
/// the label on its supporting line whenever it draws the image.
///
/// Acceptance (section 5 again) is *not* enforced here and must not be.
/// `nyctisAssetLogosProvider` is the only source of these bytes and it
/// yields entries for accepted assets only; an unaccepted asset therefore has
/// no bytes, [ActivityRowData.leadingImage] stays null, and the row falls back
/// to its icon. A second way to get bytes into a row would be a second way to
/// bypass that gate.
@immutable
class ActivityRowLeadingImage {
  const ActivityRowLeadingImage({
    required this.bytes,
    required this.identityLabel,
  }) : assert(
         identityLabel != '',
         'A row that draws a logo must also show the asset id '
         '(asset-metadata-v0 section 5).',
       );

  /// Encoded image bytes, already sniffed as PNG/JPEG/WebP and checked against
  /// their digest by the metadata layer. The row decodes them to a bounded
  /// target; it never decodes at natural size.
  final Uint8List bytes;

  /// `asset_id`, or an unambiguous abbreviation of it. Rendered next to the
  /// image, never elided in favour of the descriptive subtitle.
  final String identityLabel;
}

class ActivityRowData {
  const ActivityRowData({
    this.stableId,
    required this.title,
    required this.leadingIconName,
    this.leadingImage,
    required this.leadingBackgroundColor,
    required this.leadingIconColor,
    this.leadingProgressValue,
    this.subtitle,
    this.subtitleIconName,
    required this.amountText,
    this.amountIconName,
    this.amountIconColor,
    this.amountColor,
    this.amountSubtitle,
    this.amountSubtitleIconName,
    this.amountSubtitleIconColor,
    required this.statusText,
    required this.timestampText,
    this.statusIconName,
    this.statusColor,
    this.backgroundColor,
    this.selected = false,
    this.childRows = const [],
    this.onTap,
  });

  final String? stableId;
  final String title;
  final String leadingIconName;

  /// Drawn instead of [leadingIconName], in the same circular frame at the
  /// same size. Null on every row that has no verified image to show, which
  /// is every row that existed before this field did.
  ///
  /// [leadingProgressValue] still wins: a row reporting progress keeps the
  /// ring and its glyph. Nothing sets both today.
  final ActivityRowLeadingImage? leadingImage;

  final Color leadingBackgroundColor;
  final Color leadingIconColor;
  final double? leadingProgressValue;
  final String? subtitle;
  final String? subtitleIconName;
  final String amountText;
  final String? amountIconName;
  final Color? amountIconColor;
  final Color? amountColor;
  final String? amountSubtitle;
  final String? amountSubtitleIconName;
  final Color? amountSubtitleIconColor;
  final String statusText;
  final String timestampText;
  final String? statusIconName;
  final Color? statusColor;
  final Color? backgroundColor;
  final bool selected;
  final List<ActivityRowData> childRows;
  final VoidCallback? onTap;

  /// This row with [leadingImage] replaced and everything else kept.
  ///
  /// Deliberately narrower than a general `copyWith`: a row's mapper owns
  /// every other field, and the only thing a caller downstream of a mapper
  /// legitimately learns later is whether the wallet holds a verified logo for
  /// the asset the row is about.
  ActivityRowData withLeadingImage(ActivityRowLeadingImage? image) {
    return ActivityRowData(
      stableId: stableId,
      title: title,
      leadingIconName: leadingIconName,
      leadingImage: image,
      leadingBackgroundColor: leadingBackgroundColor,
      leadingIconColor: leadingIconColor,
      leadingProgressValue: leadingProgressValue,
      subtitle: subtitle,
      subtitleIconName: subtitleIconName,
      amountText: amountText,
      amountIconName: amountIconName,
      amountIconColor: amountIconColor,
      amountColor: amountColor,
      amountSubtitle: amountSubtitle,
      amountSubtitleIconName: amountSubtitleIconName,
      amountSubtitleIconColor: amountSubtitleIconColor,
      statusText: statusText,
      timestampText: timestampText,
      statusIconName: statusIconName,
      statusColor: statusColor,
      backgroundColor: backgroundColor,
      selected: selected,
      childRows: childRows,
      onTap: onTap,
    );
  }
}
