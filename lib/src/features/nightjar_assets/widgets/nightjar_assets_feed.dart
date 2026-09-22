/// The presentational Nightjar assets list.
///
/// Mirrors `activity_feed.dart`: a dumb widget that takes ready-made
/// sections plus `isLoading` / `errorText` / `emptyText`, and renders one
/// grouped card per section. It reads no provider and performs no work; the
/// screens decide what the three empty-ish states say.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/formatting/number_format.dart';
import '../../../core/layout/app_form_factor.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import 'nightjar_artwork_data.dart';
import 'nightjar_asset_logo.dart';
import 'nightjar_asset_row_data.dart';
import 'nightjar_collection_data.dart';
import 'nightjar_collection_grid.dart';
import 'nightjar_collection_mapper.dart';

const _nightjarRowActivationShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
};

/// Supporting line under an asset title (symbol / unnamed marker / pending
/// gap). Mobile bumps to the larger label token, like the activity feed.
const nightjarRowSupportingStyle = kAppFormFactor == AppFormFactor.mobile
    ? AppTypography.labelLarge
    : AppTypography.labelSmall;

/// Default width of a Nightjar card on the desktop pane; matches the
/// activity feed so the two panes line up.
const double kNightjarCardWidth = 396;

/// How a [NightjarMessageCard] is tinted.
enum NightjarMessageTone {
  /// Plain explanatory copy — the empty and not-configured states.
  neutral,

  /// Something is degraded but nothing is lost — a stale indexer, or notes
  /// waiting out the finality depth.
  warning,

  /// The wallet could not read the channel at all.
  error,
}

/// One grouped card of asset rows.
class NightjarAssetsSectionData {
  const NightjarAssetsSectionData({required this.title, required this.rows});

  final String title;
  final List<NightjarAssetRowData> rows;
}

/// The assets list itself.
class NightjarAssetsFeed extends StatelessWidget {
  const NightjarAssetsFeed({
    required this.sections,
    this.collections = const [],
    this.collectionsTitle = 'Collections',
    this.isLoading = false,
    this.errorText,
    this.errorDetail,
    this.emptyText = 'No Nightjar assets yet',
    this.errorTone = NightjarMessageTone.error,
    this.rowKeyPrefix,
    this.cardWidth = kNightjarCardWidth,
    super.key,
  });

  final List<NightjarAssetsSectionData> sections;

  /// Collections, drawn in their own card above the asset sections.
  ///
  /// They are first because a collection is an entry the list would otherwise
  /// be made of: fold a hundred unique items into one row and put it below
  /// two token balances, and the screen implies the hundred are a footnote to
  /// the two.
  final List<NightjarCollectionRowData> collections;

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
  final NightjarMessageTone errorTone;

  final String? rowKeyPrefix;

  /// Fixed card width. The desktop pane passes the 396px default; mobile
  /// passes null so cards stretch to the parent width.
  final double? cardWidth;

  @override
  Widget build(BuildContext context) {
    final message =
        errorText ?? (isLoading ? 'Loading Nightjar assets...' : null);
    final isEmpty = sections.isEmpty && collections.isEmpty;
    if (message != null && isEmpty) {
      return NightjarMessageCard(
        text: message,
        detail: errorText != null ? errorDetail : null,
        width: cardWidth,
        tone: errorText != null ? errorTone : NightjarMessageTone.neutral,
      );
    }
    if (isEmpty) {
      return NightjarMessageCard(text: emptyText, width: cardWidth);
    }

    var rowIndex = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (collections.isNotEmpty)
          _NightjarCollectionsCard(
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
          _NightjarAssetsCard(
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

/// A single card carrying one sentence. Used for every Nightjar state that
/// has no list to show, and for the finality-gap notice above one that does.
class NightjarMessageCard extends StatelessWidget {
  const NightjarMessageCard({
    required this.text,
    this.detail,
    this.width,
    this.tone = NightjarMessageTone.neutral,
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
  final NightjarMessageTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final textColor = switch (tone) {
      NightjarMessageTone.neutral => colors.text.secondary,
      NightjarMessageTone.warning => colors.text.warning,
      NightjarMessageTone.error => colors.text.destructive,
    };
    return SizedBox(
      width: width,
      child: _NightjarCardShell(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
    );
  }
}

class _NightjarCardShell extends StatelessWidget {
  const _NightjarCardShell({required this.child});

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

class _NightjarAssetsCard extends StatelessWidget {
  const _NightjarAssetsCard({
    required this.section,
    required this.width,
    this.rowKeyBuilder,
  });

  final NightjarAssetsSectionData section;
  final double? width;
  final ValueKey<String> Function()? rowKeyBuilder;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: width,
      child: _NightjarCardShell(
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
                child: Text(
                  section.title,
                  style: AppTypography.labelLarge.copyWith(
                    color: colors.text.secondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (var i = 0; i < section.rows.length; i++) ...[
                SizedBox(height: i == 0 ? AppSpacing.s : AppSpacing.sm),
                NightjarAssetRow(
                  key: rowKeyBuilder?.call(),
                  row: section.rows[i],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NightjarCollectionsCard extends StatelessWidget {
  const _NightjarCollectionsCard({
    required this.title,
    required this.rows,
    required this.width,
    super.key,
  });

  final String title;
  final List<NightjarCollectionRowData> rows;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: width,
      child: _NightjarCardShell(
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
                child: Text(
                  title,
                  style: AppTypography.labelLarge.copyWith(
                    color: colors.text.secondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (var i = 0; i < rows.length; i++) ...[
                SizedBox(height: i == 0 ? AppSpacing.s : AppSpacing.sm),
                NightjarCollectionRow(
                  key: ValueKey('nightjar_collection_${rows[i].collectionId}'),
                  row: rows[i],
                ),
              ],
            ],
          ),
        ),
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
class NightjarCollectionRow extends StatelessWidget {
  const NightjarCollectionRow({required this.row, super.key});

  final NightjarCollectionRowData row;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final onTap = row.onTap;

    final artwork = row.artwork;
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        NightjarCollectionLeading(artwork: artwork),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
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
                  // The two claims the wallet owes the user about a picture it
                  // is drawing, in the one place this row draws one. They sit
                  // beside the derived title rather than under the id because
                  // the supporting line is already `id · count` at one line,
                  // and a marker that ellipsizes away is not a marker.
                  if (artwork.isDerived) ...[
                    const SizedBox(width: AppSpacing.xxs),
                    const NightjarArtworkBadge(
                      key: ValueKey('nightjar_collection_derived_badge'),
                      text: kNightjarCollectionDerivedBadgeText,
                    ),
                  ],
                  if (artwork.artwork.status ==
                      NightjarArtworkStatus.unpinned) ...[
                    const SizedBox(width: AppSpacing.xxs),
                    const NightjarArtworkBadge(
                      key: ValueKey('nightjar_collection_unpinned_badge'),
                      text: kNightjarArtworkUnpinnedBadgeText,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                '${row.subtitle} · ${row.countText}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: nightjarRowSupportingStyle.copyWith(
                  color: colors.text.secondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              row.ownedText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodyMediumStrong.copyWith(
                color: colors.text.primary,
              ),
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              row.ownedLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: nightjarRowSupportingStyle.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
        ),
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

    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: row.title,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        shortcuts: _nightjarRowActivationShortcuts,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: content,
        ),
      ),
    );
  }
}

/// One asset: its name (or truncated id when unnamed), the wallet's own
/// balance, and how many notes make it up.
class NightjarAssetRow extends StatelessWidget {
  const NightjarAssetRow({required this.row, super.key});

  final NightjarAssetRowData row;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final onTap = row.onTap;
    final title = nightjarAssetRowTitle(row);
    final subtitle = nightjarAssetRowSubtitle(row);
    final balanceText = nightjarAssetRowBalanceText(row);
    final noteCountText = nightjarAssetRowNoteCountText(row);

    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        NightjarAssetLeading(isPublic: row.isPublic, logoBytes: row.logoBytes),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodyMediumStrong.copyWith(
                  color: colors.text.accent,
                ),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: nightjarRowSupportingStyle.copyWith(
                  color: colors.text.secondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              balanceText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodyMediumStrong.copyWith(
                color: colors.text.primary,
              ),
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              noteCountText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: nightjarRowSupportingStyle.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
        ),
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

    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: title,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        shortcuts: _nightjarRowActivationShortcuts,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: content,
        ),
      ),
    );
  }
}

/// The row's headline: the declared name, or the truncated asset id when the
/// issuer never published one.
String nightjarAssetRowTitle(NightjarAssetRowData row) {
  return row.hasName ? row.name!.trim() : truncateNightjarAssetId(row.assetId);
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
String nightjarAssetRowSubtitle(NightjarAssetRowData row) {
  final symbol = row.symbol?.trim();
  final hasSymbol = symbol != null && symbol.isNotEmpty;
  if (row.hasLogo) {
    final assetId = truncateNightjarAssetId(row.assetId);
    return hasSymbol ? '$symbol · $assetId' : assetId;
  }
  if (hasSymbol) return symbol;
  if (!row.hasName) return 'Unnamed asset';
  return truncateNightjarAssetId(row.assetId);
}

/// What the right-hand column of a unique item's row says instead of a
/// quantity.
const String kNightjarUniqueOwnedText = 'Owned';
const String kNightjarUniqueNotOwnedText = 'Not owned';

/// The supporting line under it. Says what kind of thing this is, since the
/// line above it no longer implies one.
const String kNightjarUniqueItemLabel = 'Unique item';

/// The wallet's own balance, formatted. Never a supply figure — a Nightjar
/// balance is private and this is the only one the wallet can see.
///
/// A unique item does not get a number here, and that is the whole point of
/// recognizing one. `max_supply = 1` at `decimals = 0` is hashed into
/// `asset_id`: the asset is one indivisible thing, and "1" in a column whose
/// every other entry is a quantity reads as a quantity — of what unit, next to
/// which other 1, summable with what. A hundred-piece collection rendered that
/// way is a hundred rows each claiming a balance of one. The wallet holds the
/// thing or it does not, so the column says which.
String nightjarAssetRowBalanceText(NightjarAssetRowData row) {
  if (row.isUniqueItem) {
    return row.balance > BigInt.zero
        ? kNightjarUniqueOwnedText
        : kNightjarUniqueNotOwnedText;
  }
  return formatNightjarAmount(row.balance, row.decimals);
}

/// `3 notes` — every note the wallet holds of this asset.
///
/// There is no "· 1 pending" half: the replay closes the view below the
/// finality depth, so a note the wallet can see is a note that already
/// counts. What is still in flight is counted per channel, not per asset,
/// by [NightjarViewData.pendingMessageCount].
String nightjarAssetRowNoteCountText(NightjarAssetRowData row) {
  // A unique item is carried by exactly one note when it is held and none
  // when it is not, so the count restates the line above it. Naming the kind
  // of asset is the line that earns its place.
  if (row.isUniqueItem) return kNightjarUniqueItemLabel;
  return row.noteCount == 1
      ? '1 note'
      : '${formatGroupedInteger(row.noteCount)} notes';
}
