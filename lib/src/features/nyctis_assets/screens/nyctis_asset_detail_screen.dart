/// Desktop `/nyctis/:assetId` — one asset's identity, declared metadata,
/// supply, and this wallet's own notes of it.
///
/// The screen watches the provider and passes plain values down; every fact
/// row is built by the pure mapper and rendered by the shared
/// [ReviewListRow] through [NyctisFactsCard].
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/app_form_factor.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../core/widgets/review_wrap_card.dart';
import '../providers/nyctis_assets_view_provider.dart';
import '../providers/nyctis_proving_key_provider.dart';
import '../widgets/nyctis_asset_metadata_section.dart';
import '../widgets/nyctis_collection_sections.dart';
import '../widgets/nyctis_asset_row_data.dart';
import '../widgets/nyctis_asset_row_mapper.dart';
import '../widgets/nyctis_assets_feed.dart';
import '../widgets/nyctis_facts_card.dart';
import '../widgets/nyctis_interactive.dart';
import 'nyctis_send_screen.dart';

/// Where the asset detail screen sends from.
String nyctisSendRouteFor(String assetId) => '/nyctis/$assetId/send';

/// The wallet's own Nyctis address.
const String kNyctisReceiveRoute = '/nyctis/receive';

class NyctisAssetDetailScreen extends StatelessWidget {
  const NyctisAssetDetailScreen({required this.assetId, super.key});

  final String assetId;

  @override
  Widget build(BuildContext context) {
    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NyctisAssetDetailPane(assetId: assetId),
      ),
    );
  }
}

/// The pane body without the sidebar, so it renders on its own in tests and
/// in Widgetbook.
class NyctisAssetDetailPane extends ConsumerWidget {
  const NyctisAssetDetailPane({required this.assetId, super.key});

  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = resolveNyctisView(ref.watch(nyctisAssetsViewProvider));
    final asset = view?.assetById(assetId);

    return AppPaneScrollScaffold(
      toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: kNyctisCardWidth,
          child: NyctisAssetDetailBody(
            assetId: assetId,
            view: view,
            asset: asset,
            heroSection: NyctisUniqueItemSection(asset: asset),
            metadataSection: NyctisAssetMetadataSection(asset: asset),
            onSend: () => context.push(nyctisSendRouteFor(assetId)),
            onReceive: () => context.push(kNyctisReceiveRoute),
            sendDisabledReason: nyctisSendUnavailableReason(
              ref.watch(nyctisProvingKeyProvider),
            ),
          ),
        ),
      ),
    );
  }
}

/// Presentational body shared by the desktop pane and the mobile screen.
///
/// Balance and actions first, the way every Vizor balance screen reads; then
/// what is public about the asset; then its identity and the issuer's
/// metadata; then the notes, grouped into one card whose list is built only
/// when opened.
class NyctisAssetDetailBody extends StatelessWidget {
  const NyctisAssetDetailBody({
    required this.assetId,
    required this.view,
    required this.asset,
    this.heroSection,
    this.metadataSection,
    this.showTitle = true,
    this.onSend,
    this.onReceive,
    this.sendDisabledReason,
    super.key,
  });

  final String assetId;

  /// Null while the first load is in flight.
  final NyctisViewData? view;

  /// Null when the view does not hold this asset.
  final NyctisAssetDetailData? asset;

  /// The unique-item header — artwork, name, index, `asset_id` — when the
  /// caller has a wallet behind it.
  ///
  /// Injected for the same reason [metadataSection] is: it draws an
  /// issuer-supplied picture, so the only thing that can put one on screen is
  /// a screen that deliberately passed one in. It renders nothing for an
  /// asset that is not a unique item, so both detail screens pass it
  /// unconditionally. When it is drawn it carries the name, and this body
  /// drops its own title so the page does not say it twice.
  final Widget? heroSection;

  /// The issuer-metadata card, when the caller has a wallet behind it.
  ///
  /// Injected rather than built here so this widget stays presentational and
  /// so the only thing that can trigger a metadata fetch is a screen that
  /// deliberately passed one in. A Widgetbook fixture or a read-only test
  /// passes null and gets exactly the screen that existed before metadata did.
  final Widget? metadataSection;

  /// Desktop draws its own title; the mobile top nav already carries one.
  final bool showTitle;

  /// Opens the composer. Null leaves the screen exactly as it was before
  /// sending existed — which is what a caller that has no send route (a
  /// Widgetbook fixture, a read-only test) should get.
  final VoidCallback? onSend;

  /// Opens the receive screen. Null hides the button.
  final VoidCallback? onReceive;

  /// Why sending is unavailable, when it is. Rendered beside a disabled
  /// button rather than hiding it: a Send that is simply absent reads as a
  /// feature this wallet does not have, and the actual reason — no proving
  /// key, or the wrong one — is fixable in settings in a minute.
  final String? sendDisabledReason;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final view = this.view;
    final asset = this.asset;

    if (view == null) {
      return const NyctisMessageCard(
        key: ValueKey('nyctis_asset_detail_loading'),
        text: kNyctisAssetLoadingText,
        width: kNyctisCardWidth,
        loading: true,
        liveRegion: true,
      );
    }
    if (asset == null) {
      final listError = nyctisListErrorText(view);
      return NyctisMessageCard(
        key: const ValueKey('nyctis_asset_detail_missing'),
        text: listError ?? nyctisUnknownAssetText(assetId),
        width: kNyctisCardWidth,
        tone: listError == null
            ? NyctisMessageTone.neutral
            : nyctisListErrorTone(view),
      );
    }

    final supplyFacts = buildNyctisAssetSupplyFacts(asset);
    // Unspent only: this screen lists what the wallet *holds*. A spent note is
    // history and belongs to the activity feed, which now shows it as the
    // payment it funded rather than as a holding.
    final notes = asset.notes.where((note) => !note.spent).toList();
    // The same caveats the list carries, because they are equally true two
    // taps in: a borrowed chain tip and messages above the finality cut-off
    // both change what the balance below means. They are facts about the
    // channel, not about this asset, and the copy says so.
    final notice = nyctisNoticeText(view);
    final heroShowsName = heroSection != null && asset.isUniqueItem;
    // Nothing to send is not a reason to explain why sending is off: an empty
    // holding has its own, shorter, story below.
    final canOfferSend = onSend != null && asset.balance > BigInt.zero;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Above the title: for a unique item the picture *is* the heading,
        // and the facts below explain it rather than the other way round.
        ?heroSection,
        if (showTitle && !heroShowsName) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
            child: Semantics(
              header: true,
              child: Text(
                nyctisAssetDetailTitle(asset),
                key: const ValueKey('nyctis_asset_detail_title'),
                textAlign: TextAlign.center,
                style: AppTypography.headlineLarge.copyWith(
                  color: colors.text.accent,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (!asset.isUniqueItem) ...[
          NyctisBalanceHero(asset: asset),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (canOfferSend || onReceive != null) ...[
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              if (canOfferSend)
                AppButton(
                  key: const ValueKey('nyctis_asset_detail_send_button'),
                  size: AppButtonSize.medium,
                  // Long labels wrap at large text instead of overflowing.
                  growWithContent: true,
                  constrainContent: true,
                  leading: const AppIcon(
                    AppIcons.arrowUpward,
                    size: AppIconSize.medium,
                  ),
                  onPressed: sendDisabledReason == null ? onSend : null,
                  child: const Text(kNyctisSendTitle),
                ),
              if (onReceive != null)
                AppButton(
                  key: const ValueKey('nyctis_asset_detail_receive_button'),
                  size: AppButtonSize.medium,
                  // Long labels wrap at large text instead of overflowing.
                  growWithContent: true,
                  constrainContent: true,
                  variant: AppButtonVariant.secondary,
                  leading: const AppIcon(
                    AppIcons.arrowDownward,
                    size: AppIconSize.medium,
                  ),
                  onPressed: onReceive,
                  child: const Text(kNyctisReceiveAction),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (canOfferSend && sendDisabledReason != null) ...[
          NyctisMessageCard(
            key: const ValueKey('nyctis_asset_detail_send_unavailable'),
            text: sendDisabledReason!,
            width: kNyctisCardWidth,
            tone: NyctisMessageTone.warning,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (notice != null) ...[
          NyctisMessageCard(
            key: const ValueKey('nyctis_asset_detail_notice'),
            text: notice,
            width: kNyctisCardWidth,
            tone: kNyctisNoticeTone,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        // The supply card is the only place a figure about the asset as a
        // whole appears, and there is one only for a public asset. The
        // footnote follows the asset: it says what is public here, which for
        // a private asset is nothing, rather than asserting a disclosure the
        // row directly above it denies.
        NyctisFactsCard(
          key: const ValueKey('nyctis_asset_detail_supply'),
          title: 'Supply',
          facts: supplyFacts.isEmpty
              ? const [
                  NyctisAssetFactData(
                    label: 'Issued supply',
                    value: 'Private',
                  ),
                ]
              : supplyFacts,
          footnote: nyctisSupplyFootnote(asset),
        ),
        const SizedBox(height: AppSpacing.md),
        NyctisFactsCard(
          key: const ValueKey('nyctis_asset_detail_identity'),
          title: 'Identity',
          facts: buildNyctisAssetIdentityFacts(asset),
        ),
        ?metadataSection,
        if (asset.declaredMetadata.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          NyctisFactsCard(
            key: const ValueKey('nyctis_asset_detail_metadata'),
            title: 'Declared metadata',
            facts: asset.declaredMetadata,
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        if (notes.isEmpty)
          const NyctisMessageCard(
            key: ValueKey('nyctis_asset_detail_no_notes'),
            text: 'This wallet holds no spendable notes of this asset.',
            width: kNyctisCardWidth,
          )
        else
          NyctisNotesCard(
            key: const ValueKey('nyctis_asset_detail_notes'),
            notes: notes,
          ),
        const SizedBox(height: AppSpacing.base),
      ],
    );
  }
}

/// Shown while the first read of the channel is in flight.
const String kNyctisAssetLoadingText = 'Loading Nyctis asset…';

/// The receive action beside Send.
const String kNyctisReceiveAction = 'Receive';

/// "Your balance", large, with the symbol — the first thing on the page.
///
/// A u64 balance is up to 26 characters grouped, wider than a phone at this
/// size, so it scales down to fit rather than wrapping or clipping; the
/// accessible name carries it whole.
class NyctisBalanceHero extends StatelessWidget {
  const NyctisBalanceHero({required this.asset, super.key});

  final NyctisAssetDetailData asset;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final amount = formatNyctisAmount(asset.balance, asset.decimals);
    final symbol = asset.symbol?.trim();
    final hasSymbol = symbol != null && symbol.isNotEmpty;
    return Semantics(
      key: const ValueKey('nyctis_asset_detail_balance'),
      container: true,
      label:
          '$kNyctisYourBalanceLabel, $amount${hasSymbol ? ' $symbol' : ''}',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            kNyctisYourBalanceLabel,
            textAlign: TextAlign.center,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xxs),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: amount,
                    style: AppTypography.displayMedium.copyWith(
                      color: colors.text.accent,
                    ),
                  ),
                  if (hasSymbol)
                    TextSpan(
                      text: ' $symbol',
                      style: AppTypography.headlineSmall.copyWith(
                        color: colors.text.secondary,
                      ),
                    ),
                ],
              ),
              key: const ValueKey('nyctis_asset_detail_balance_amount'),
              maxLines: 1,
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }
}

/// Label above the balance.
const String kNyctisYourBalanceLabel = 'Your balance';

/// The wallet's notes of one asset, as one card: how many there are, and the
/// list itself behind "Show notes".
///
/// One card, not one per note: an asset held as two hundred notes used to be
/// two hundred cards of position, height and policy. The rows are built only
/// once the disclosure is opened.
class NyctisNotesCard extends StatelessWidget {
  const NyctisNotesCard({required this.notes, super.key});

  final List<NyctisNoteRowData> notes;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final children = <Widget>[
      Semantics(
        header: true,
        child: Text(
          nyctisNotesSummaryText(notes.length),
          key: const ValueKey('nyctis_asset_detail_notes_summary'),
          style: AppTypography.labelLarge.copyWith(
            color: colors.text.secondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      NyctisDisclosure(
        toggleKey: const ValueKey('nyctis_asset_detail_notes_toggle'),
        title: kNyctisShowNotesTitle,
        builder: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < notes.length; i++) ...[
              if (i > 0) const SizedBox(height: AppSpacing.xxs),
              Text(
                nyctisNoteLineText(i, notes[i]),
                key: ValueKey('nyctis_asset_detail_note_$i'),
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    ];
    if (kAppFormFactor == AppFormFactor.mobile) {
      return MobileSurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            children[0],
            const SizedBox(height: AppSpacing.xs),
            children[1],
          ],
        ),
      );
    }
    return ReviewWrapCard(mainAxisSize: MainAxisSize.min, children: children);
  }
}
