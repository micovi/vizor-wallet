/// The presentational Nyctis assets list.
///
/// Mirrors `activity_feed.dart`: a dumb widget that takes ready-made
/// sections plus `isLoading` / `errorText` / `emptyText`, and renders one
/// grouped card per section. It reads no provider and performs no work; the
/// screens decide what the three empty-ish states say.
library;

import 'package:flutter/widgets.dart';

import '../../../core/formatting/number_format.dart';
import '../../../core/layout/app_form_factor.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import 'nyctis_artwork_data.dart';
import 'nyctis_asset_logo.dart';
import 'nyctis_asset_row_data.dart';
import 'nyctis_collection_data.dart';
import 'nyctis_collection_grid.dart';
import 'nyctis_collection_mapper.dart';
import 'nyctis_interactive.dart';

/// Supporting line under an asset title (symbol / unnamed marker / pending
/// gap). Mobile bumps to the larger label token, like the activity feed.
const nyctisRowSupportingStyle = kAppFormFactor == AppFormFactor.mobile
    ? AppTypography.labelLarge
    : AppTypography.labelSmall;

/// Default width of a Nyctis card on the desktop pane; matches the
/// activity feed so the two panes line up.
const double kNyctisCardWidth = 396;

/// How a [NyctisMessageCard] is tinted.
enum NyctisMessageTone {
  /// Plain explanatory copy — the empty and not-configured states.
  neutral,

  /// Something is degraded but nothing is lost — a stale indexer, or notes
  /// waiting out the finality depth.
  warning,

  /// The wallet could not read the channel at all.
  error,
}

/// Text scale above which a row stops putting the balance beside the title
/// and puts it underneath. At 130% the side-by-side row still fits a phone;
/// at 200% the title and a long balance cannot share one line.
const double kNyctisRowStackTextScale = 1.3;

/// Widest share of a row the balance column may take before it scales down.
const double kNyctisRowAmountMaxFraction = 0.45;

/// One grouped card of asset rows.
class NyctisAssetsSectionData {
  const NyctisAssetsSectionData({
    required this.title,
    required this.rows,
    this.subtitle,
  });

  final String title;

  /// One line under [title] saying what the grouping means.
  final String? subtitle;

  final List<NyctisAssetRowData> rows;
}

/// Shown while the first read of the channel is in flight.
const String kNyctisAssetsLoadingText = 'Loading Nyctis assets…';

/// The assets list itself.
class NyctisAssetsFeed extends StatelessWidget {
  const NyctisAssetsFeed({
    required this.sections,
    this.collections = const [],
    this.collectionsTitle = 'Collections',
    this.isLoading = false,
    this.errorText,
    this.errorDetail,
    this.emptyText = 'No Nyctis assets yet',
    this.errorTone = NyctisMessageTone.error,
    this.rowKeyPrefix,
    this.cardWidth = kNyctisCardWidth,
    super.key,
  });

  final List<NyctisAssetsSectionData> sections;

  /// Collections, drawn in their own card above the asset sections.
  ///
  /// They are first because a collection is an entry the list would otherwise
  /// be made of: fold a hundred unique items into one row and put it below
  /// two token balances, and the screen implies the hundred are a footnote to
  /// the two.
  final List<NyctisCollectionRowData> collections;

  final String collectionsTitle;

  final bool isLoading;

  /// Replaces the list when there is nothing to show: the not-configured,
  /// unreachable, and stale states all arrive through here.
  final String? errorText;

  /// The loader's concrete second line for [errorText], when there is one.
  final String? errorDetail;

  /// Shown when the wallet is configured, reachable, and simply holds
  /// nothing.
  final String emptyText;

  /// Tint for [errorText]. The not-configured state is neutral copy, not a
  /// failure, so the screen can soften it.
  final NyctisMessageTone errorTone;

  final String? rowKeyPrefix;

  /// Fixed card width. The desktop pane passes the 396px default; mobile
  /// passes null so cards stretch to the parent width.
  final double? cardWidth;

  @override
  Widget build(BuildContext context) {
    final message = errorText ?? (isLoading ? kNyctisAssetsLoadingText : null);
    final isEmpty = sections.isEmpty && collections.isEmpty;
    if (message != null && isEmpty) {
      return NyctisMessageCard(
        key: errorText == null ? const ValueKey('nyctis_assets_loading') : null,
        text: message,
        detail: errorText != null ? errorDetail : null,
        width: cardWidth,
        loading: errorText == null,
        liveRegion: true,
        tone: errorText != null ? errorTone : NyctisMessageTone.neutral,
      );
    }
    if (isEmpty) {
      return NyctisMessageCard(text: emptyText, width: cardWidth);
    }

    var rowIndex = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (collections.isNotEmpty)
          _NyctisCollectionsCard(
            key: rowKeyPrefix == null
                ? null
                : ValueKey('${rowKeyPrefix}_collections'),
            title: collectionsTitle,
            rows: collections,
            width: cardWidth,
          ),
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0 || collections.isNotEmpty)
            const SizedBox(height: AppSpacing.md),
          _NyctisAssetsCard(
            section: sections[i],
            width: cardWidth,
            rowKeyBuilder: rowKeyPrefix == null
                ? null
                : () => ValueKey('${rowKeyPrefix}_row_${rowIndex++}'),
          ),
        ],
      ],
    );
  }
}

/// A single card carrying one sentence. Used for every Nyctis state that
/// has no list to show, and for the finality-gap notice above one that does.
///
/// Warning and error copy is drawn in `text.primary` with a glyph beside it
/// rather than in the utility colours: the light warning gold is 3.35:1 on
/// white and the dark destructive plum 4.25:1 on the card, both under WCAG AA
/// for this size, and a colour on its own is not a signal (WCAG 1.4.1).
class NyctisMessageCard extends StatelessWidget {
  const NyctisMessageCard({
    required this.text,
    this.detail,
    this.width,
    this.tone = NyctisMessageTone.neutral,
    this.loading = false,
    this.liveRegion = false,
    super.key,
  });

  final String text;

  /// The loader's own second line: the concrete values behind [text].
  ///
  /// [text] says *that* something disagrees; this says *what*, and for the
  /// checks that compare the wallet's replay against the indexer it carries
  /// both roots and the height. It went unrendered until a real mismatch turned
  /// up on the devnet and the screen could only say "not showing the whole
  /// channel" — the one line that would have identified it in a glance was
  /// being computed and thrown away. Rendered small and secondary because it is
  /// diagnostic: the sentence above is for the person, this is for whoever has
  /// to fix it.
  final String? detail;
  final double? width;
  final NyctisMessageTone tone;

  /// Draws the shared loader above [text]. It honours reduced motion.
  final bool loading;

  /// Announces [text] when it changes, for progress and failure notices.
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final textColor = switch (tone) {
      NyctisMessageTone.neutral => colors.text.secondary,
      NyctisMessageTone.warning ||
      NyctisMessageTone.error => colors.text.primary,
    };
    final String? glyph = switch (tone) {
      NyctisMessageTone.neutral => null,
      NyctisMessageTone.warning => AppIcons.warning,
      NyctisMessageTone.error => AppIcons.warningCircle,
    };
    return SizedBox(
      width: width,
      child: _NyctisCardShell(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.md,
          ),
          child: Semantics(
            liveRegion: liveRegion,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading || glyph != null) ...[
                  ExcludeSemantics(
                    child: AppIcon(
                      loading ? AppIcons.loader : glyph!,
                      key: loading
                          ? const ValueKey('nyctis_message_loader')
                          : null,
                      size: AppIconSize.medium,
                      color: tone == NyctisMessageTone.error
                          ? colors.icon.destructive
                          : colors.icon.regular,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                ],
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: AppTypography.labelLarge.copyWith(
                    color: textColor,
                    letterSpacing: 0,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    detail!,
                    textAlign: TextAlign.center,
                    style: AppTypography.bodySmall.copyWith(
                      color: colors.text.secondary,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NyctisCardShell extends StatelessWidget {
  const _NyctisCardShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background.ground,
        borderRadius: BorderRadius.circular(AppRadii.large),
        boxShadow: appSurfaceShadow(colors),
      ),
      child: child,
    );
  }
}

class _NyctisAssetsCard extends StatelessWidget {
  const _NyctisAssetsCard({
    required this.section,
    required this.width,
    this.rowKeyBuilder,
  });

  final NyctisAssetsSectionData section;
  final double? width;
  final ValueKey<String> Function()? rowKeyBuilder;

  @override
  Widget build(BuildContext context) {
    return _NyctisListCard(
      width: width,
      title: section.title,
      subtitle: section.subtitle,
      children: [
        for (final row in section.rows)
          NyctisAssetRow(key: rowKeyBuilder?.call(), row: row),
      ],
    );
  }
}

class _NyctisCollectionsCard extends StatelessWidget {
  const _NyctisCollectionsCard({
    required this.title,
    required this.rows,
    required this.width,
    super.key,
  });

  final String title;
  final List<NyctisCollectionRowData> rows;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return _NyctisListCard(
      width: width,
      title: title,
      children: [
        for (final row in rows)
          NyctisCollectionRow(
            key: ValueKey('nyctis_collection_${row.collectionId}'),
            row: row,
          ),
      ],
    );
  }
}

/// The card shell, heading and row rhythm both list cards share.
class _NyctisListCard extends StatelessWidget {
  const _NyctisListCard({
    required this.width,
    required this.title,
    required this.children,
    this.subtitle,
  });

  final double? width;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final subtitle = this.subtitle;
    return SizedBox(
      width: width,
      child: _NyctisCardShell(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xxs),
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: AppTypography.labelLarge.copyWith(
                      color: colors.text.secondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xxs,
                  ),
                  child: Text(
                    subtitle,
                    style: AppTypography.bodySmall.copyWith(
                      color: colors.text.secondary,
                    ),
                  ),
                ),
              for (var i = 0; i < children.length; i++) ...[
                SizedBox(height: i == 0 ? AppSpacing.xs : AppSpacing.xxs),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Whether rows should stack their amount under the title at the current
/// text scale.
bool nyctisRowShouldStack(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(100) / 100 >
    kNyctisRowStackTextScale;

/// The shared shape of an asset row and a collection row: a leading avatar,
/// a title and supporting line, an amount column that shrinks rather than
/// overflowing, and a chevron when it opens something.
///
/// The amount is never ellipsized: a clipped balance is a different number.
/// It scales down to fit instead, and the row's accessible name carries it in
/// full. Above [kNyctisRowStackTextScale] the amount moves under the title,
/// where it has the whole row width.
class _NyctisListRow extends StatelessWidget {
  const _NyctisListRow({
    required this.leading,
    required this.titleLine,
    required this.subtitle,
    required this.amount,
    required this.amountCaption,
    required this.onTap,
    required this.semanticsLabel,
    required this.semanticsHint,
  });

  final Widget leading;
  final Widget titleLine;
  final String subtitle;
  final String amount;
  final String amountCaption;
  final VoidCallback? onTap;
  final String semanticsLabel;
  final String semanticsHint;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final stacked = nyctisRowShouldStack(context);
    final supportingStyle = nyctisRowSupportingStyle.copyWith(
      color: colors.text.secondary,
    );
    final amountStyle = AppTypography.bodyMediumStrong.copyWith(
      color: colors.text.primary,
    );

    Widget amountText(Alignment alignment) => FittedBox(
      key: const ValueKey('nyctis_row_amount'),
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Text(amount, maxLines: 1, softWrap: false, style: amountStyle),
    );
    Widget caption(TextAlign align) => Text(
      amountCaption,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: supportingStyle,
    );
    final subtitleText = Text(
      subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: supportingStyle,
    );

    final Widget body;
    if (stacked) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          titleLine,
          const SizedBox(height: AppSpacing.xxs),
          subtitleText,
          const SizedBox(height: AppSpacing.xxs),
          amountText(Alignment.centerLeft),
          caption(TextAlign.start),
        ],
      );
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  titleLine,
                  const SizedBox(height: AppSpacing.xxs),
                  subtitleText,
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * kNyctisRowAmountMaxFraction,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  amountText(Alignment.centerRight),
                  const SizedBox(height: AppSpacing.xxs),
                  caption(TextAlign.end),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final content = Row(
      crossAxisAlignment: stacked
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        leading,
        const SizedBox(width: AppSpacing.xs),
        Expanded(child: body),
        if (onTap != null) ...[
          const SizedBox(width: AppSpacing.xxs),
          AppIcon(
            AppIcons.chevronForward,
            size: AppIconSize.medium,
            color: colors.icon.muted,
          ),
        ],
      ],
    );

    return NyctisPressable(
      onPressed: onTap,
      semanticsLabel: semanticsLabel,
      semanticsHint: onTap == null ? null : semanticsHint,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxs,
        vertical: AppSpacing.xxs,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppAssetSize.size),
        child: content,
      ),
    );
  }
}

/// One collection: its face, what its members' names have in common, its
/// truncated `collection_id`, how many pieces the wallet has read and how many
/// of them it holds.
///
/// **One picture, never a mosaic.** A mosaic of member logos would have to
/// pick which members to show, which for a partly accepted collection means
/// either an incomplete mosaic or drawing a piece the user did not accept —
/// and it would cost three or four decodes per collection in a list. One
/// picture is the collection's own `logo` (`spec/asset-collection-v0.md`
/// section 3.5) or, failing that, the lowest-indexed member the user accepted,
/// marked as derived (section 3.5.1). Failing both, the icon this row has
/// always drawn: a collection with nothing accepted is not a collection with
/// nothing in it, and the count is still the honest summary.
///
/// The owned count is said once, in the right-hand column; the supporting line
/// is the id and the public count only.
class NyctisCollectionRow extends StatelessWidget {
  const NyctisCollectionRow({required this.row, super.key});

  final NyctisCollectionRowData row;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final artwork = row.artwork;
    final titleLine = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            row.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.bodyMediumStrong.copyWith(
              color: colors.text.accent,
            ),
          ),
        ),
        // The two claims the wallet owes the user about a picture it is
        // drawing, in the one place this row draws one. They sit beside the
        // derived title rather than under the id because the supporting line
        // is already `id · count` at one line, and a marker that ellipsizes
        // away is not a marker.
        if (artwork.isDerived) ...[
          const SizedBox(width: AppSpacing.xxs),
          const NyctisArtworkBadge(
            key: ValueKey('nyctis_collection_derived_badge'),
            text: kNyctisCollectionDerivedBadgeText,
          ),
        ],
        if (artwork.artwork.status == NyctisArtworkStatus.unpinned) ...[
          const SizedBox(width: AppSpacing.xxs),
          const NyctisArtworkBadge(
            key: ValueKey('nyctis_collection_unpinned_badge'),
            text: kNyctisArtworkUnpinnedBadgeText,
          ),
        ],
      ],
    );

    return _NyctisListRow(
      leading: NyctisCollectionLeading(artwork: artwork),
      titleLine: titleLine,
      subtitle: '${row.subtitle} · ${row.countText}',
      amount: row.ownedText,
      amountCaption: row.ownedLabel,
      onTap: row.onTap,
      semanticsLabel:
          row.semanticsLabel ?? nyctisCollectionRowFallbackLabel(row),
      semanticsHint: kNyctisOpenCollectionHint,
    );
  }
}

/// The spoken hint on a collection row.
const String kNyctisOpenCollectionHint = 'Opens collection';

/// The spoken hint on an asset row.
const String kNyctisOpenAssetHint = 'Opens asset';

/// A collection row's accessible name when the mapper did not supply one.
String nyctisCollectionRowFallbackLabel(NyctisCollectionRowData row) =>
    '${row.title}, ${row.countText}, ${row.ownedText} ${row.ownedLabel}, '
    'collection id ${row.subtitle}';

/// One asset: its name (or truncated id when unnamed), the wallet's own
/// balance, and how many notes make it up.
class NyctisAssetRow extends StatelessWidget {
  const NyctisAssetRow({required this.row, super.key});

  final NyctisAssetRowData row;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final title = nyctisAssetRowTitle(row);
    return _NyctisListRow(
      leading: NyctisAssetLeading(
        logoBytes: row.logoBytes,
        isUniqueItem: row.isUniqueItem,
      ),
      titleLine: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTypography.bodyMediumStrong.copyWith(
          color: colors.text.accent,
        ),
      ),
      subtitle: nyctisAssetRowSubtitle(row),
      amount: nyctisAssetRowBalanceText(row),
      amountCaption: nyctisAssetRowNoteCountText(row),
      onTap: row.onTap,
      semanticsLabel: nyctisAssetRowSemanticsLabel(row),
      semanticsHint: kNyctisOpenAssetHint,
    );
  }
}

/// The row's headline: the declared name, or the truncated asset id when the
/// issuer never published one.
String nyctisAssetRowTitle(NyctisAssetRowData row) {
  return row.hasName ? row.name!.trim() : truncateNyctisAssetId(row.assetId);
}

/// The one sentence a screen reader hears for an asset row, e.g.
/// `NightCash, 988 NC, 3 notes`.
///
/// The balance carries its symbol here even though the row draws the symbol
/// on the line under the name: read aloud, "988" on its own is a number with
/// no unit. An unnamed asset says so before its id rather than reading a hash
/// as if it were a name.
String nyctisAssetRowSemanticsLabel(NyctisAssetRowData row) {
  final symbol = row.symbol?.trim();
  final title = row.hasName
      ? row.name!.trim()
      : 'Unnamed asset ${truncateNyctisAssetId(row.assetId)}';
  final balance = nyctisAssetRowBalanceText(row);
  final amount = row.isUniqueItem || symbol == null || symbol.isEmpty
      ? balance
      : '$balance $symbol';
  final caption = nyctisAssetRowNoteCountText(row);
  return '$title, $amount, '
      '${row.isUniqueItem ? caption.toLowerCase() : caption}';
}

/// The row's supporting line. An unnamed asset says so plainly rather than
/// leaving a blank where a name would be.
///
/// A row that draws a logo always carries the asset id, whatever else it has
/// to say. `spec/asset-metadata-v0.md` section 5: a wallet **MUST** show
/// `asset_id`, or an unambiguous abbreviation of it, wherever it shows a logo
/// — the signed name and symbol are not identifying, and a name, a symbol and
/// the right picture are a convincing imitation of another asset. The id is
/// the only thing in that row an impersonator cannot copy.
String nyctisAssetRowSubtitle(NyctisAssetRowData row) {
  final symbol = row.symbol?.trim();
  final hasSymbol = symbol != null && symbol.isNotEmpty;
  if (row.hasLogo) {
    final assetId = truncateNyctisAssetId(row.assetId);
    return hasSymbol ? '$symbol · $assetId' : assetId;
  }
  if (hasSymbol) return symbol;
  if (!row.hasName) return 'Unnamed asset';
  return truncateNyctisAssetId(row.assetId);
}

/// What the right-hand column of a unique item's row says instead of a
/// quantity.
const String kNyctisUniqueOwnedText = 'Owned';
const String kNyctisUniqueNotOwnedText = 'Not owned';

/// The supporting line under it. Says what kind of thing this is, since the
/// line above it no longer implies one.
const String kNyctisUniqueItemLabel = 'Unique item';

/// The wallet's own balance, formatted. Never a supply figure — a Nyctis
/// balance is private and this is the only one the wallet can see.
///
/// A unique item does not get a number here, and that is the whole point of
/// recognizing one. `max_supply = 1` at `decimals = 0` is hashed into
/// `asset_id`: the asset is one indivisible thing, and "1" in a column whose
/// every other entry is a quantity reads as a quantity — of what unit, next to
/// which other 1, summable with what. A hundred-piece collection rendered that
/// way is a hundred rows each claiming a balance of one. The wallet holds the
/// thing or it does not, so the column says which.
String nyctisAssetRowBalanceText(NyctisAssetRowData row) {
  if (row.isUniqueItem) {
    return row.balance > BigInt.zero
        ? kNyctisUniqueOwnedText
        : kNyctisUniqueNotOwnedText;
  }
  return formatNyctisAmount(row.balance, row.decimals);
}

/// `3 notes` — every note the wallet holds of this asset.
///
/// There is no "· 1 pending" half: the replay closes the view below the
/// finality depth, so a note the wallet can see is a note that already
/// counts. What is still in flight is counted per channel, not per asset,
/// by [NyctisViewData.pendingMessageCount].
String nyctisAssetRowNoteCountText(NyctisAssetRowData row) {
  // A unique item is carried by exactly one note when it is held and none
  // when it is not, so the count restates the line above it. Naming the kind
  // of asset is the line that earns its place.
  if (row.isUniqueItem) return kNyctisUniqueItemLabel;
  return row.noteCount == 1
      ? '1 note'
      : '${formatGroupedInteger(row.noteCount)} notes';
}
