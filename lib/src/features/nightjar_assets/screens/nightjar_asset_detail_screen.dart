/// Desktop `/nightjar/:assetId` — one asset's identity, declared metadata,
/// supply, and this wallet's own notes of it.
///
/// The screen watches the provider and passes plain values down; every fact
/// row is built by the pure mapper and rendered by the shared
/// [ReviewListRow] through [NightjarFactsCard].
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../providers/nightjar_assets_view_provider.dart';
import '../providers/nightjar_proving_key_provider.dart';
import '../widgets/nightjar_asset_metadata_section.dart';
import '../widgets/nightjar_collection_sections.dart';
import '../widgets/nightjar_asset_row_data.dart';
import '../widgets/nightjar_asset_row_mapper.dart';
import '../widgets/nightjar_assets_feed.dart';
import '../widgets/nightjar_facts_card.dart';
import 'nightjar_send_screen.dart';

/// Where the asset detail screen sends from.
String nightjarSendRouteFor(String assetId) => '/nightjar/$assetId/send';

class NightjarAssetDetailScreen extends StatelessWidget {
  const NightjarAssetDetailScreen({required this.assetId, super.key});

  final String assetId;

  @override
  Widget build(BuildContext context) {
    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NightjarAssetDetailPane(assetId: assetId),
      ),
    );
  }
}

/// The pane body without the sidebar, so it renders on its own in tests and
/// in Widgetbook.
class NightjarAssetDetailPane extends ConsumerWidget {
  const NightjarAssetDetailPane({required this.assetId, super.key});

  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = resolveNightjarView(ref.watch(nightjarAssetsViewProvider));
    final asset = view?.assetById(assetId);

    return AppPaneScrollScaffold(
      toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: kNightjarCardWidth,
          child: NightjarAssetDetailBody(
            assetId: assetId,
            view: view,
            asset: asset,
            heroSection: NightjarUniqueItemSection(asset: asset),
            metadataSection: NightjarAssetMetadataSection(asset: asset),
            onSend: () => context.push(nightjarSendRouteFor(assetId)),
            sendDisabledReason: nightjarSendUnavailableReason(
              ref.watch(nightjarProvingKeyProvider),
            ),
          ),
        ),
      ),
    );
  }
}

/// Presentational body shared by the desktop pane and the mobile screen.
class NightjarAssetDetailBody extends StatelessWidget {
  const NightjarAssetDetailBody({
    required this.assetId,
    required this.view,
    required this.asset,
    this.heroSection,
    this.metadataSection,
    this.showTitle = true,
    this.onSend,
    this.sendDisabledReason,
    super.key,
  });

  final String assetId;

  /// Null while the first load is in flight.
  final NightjarViewData? view;

  /// Null when the view does not hold this asset.
  final NightjarAssetDetailData? asset;

  /// The unique-item header — artwork, name, index, `asset_id` — when the
  /// caller has a wallet behind it.
  ///
  /// Injected for the same reason [metadataSection] is: it draws an
  /// issuer-supplied picture, so the only thing that can put one on screen is
  /// a screen that deliberately passed one in. It renders nothing for an
  /// asset that is not a unique item, so both detail screens pass it
  /// unconditionally.
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
      return const NightjarMessageCard(
        key: ValueKey('nightjar_asset_detail_loading'),
        text: 'Loading Nightjar asset...',
        width: kNightjarCardWidth,
      );
    }
    if (asset == null) {
      final listError = nightjarListErrorText(view);
      return NightjarMessageCard(
        key: const ValueKey('nightjar_asset_detail_missing'),
        text: listError ?? nightjarUnknownAssetText(assetId),
        width: kNightjarCardWidth,
        tone: listError == null
            ? NightjarMessageTone.neutral
            : nightjarListErrorTone(view),
      );
    }

    final supplyFacts = buildNightjarAssetSupplyFacts(asset);
    // Unspent only: this screen lists what the wallet *holds*. A spent note is
    // history and belongs to the activity feed, which now shows it as the
    // payment it funded rather than as a holding.
    final notes = asset.notes.where((note) => !note.spent).toList();
    // The same caveats the list carries, because they are equally true two
    // taps in: a borrowed chain tip and messages above the finality cut-off
    // both change what the balance below means. They are facts about the
    // channel, not about this asset, and the copy says so.
    final notice = nightjarNoticeText(view);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Above the title: for a unique item the picture *is* the heading,
        // and the facts below explain it rather than the other way round.
        ?heroSection,
        if (showTitle) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
            child: Text(
              nightjarAssetDetailTitle(asset),
              key: const ValueKey('nightjar_asset_detail_title'),
              style: AppTypography.headlineSmall.copyWith(
                color: colors.text.accent,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.base),
        ],
        if (notice != null) ...[
          NightjarMessageCard(
            key: const ValueKey('nightjar_asset_detail_notice'),
            text: notice,
            width: kNightjarCardWidth,
            tone: kNightjarNoticeTone,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        NightjarFactsCard(
          key: const ValueKey('nightjar_asset_detail_identity'),
          title: 'Identity',
          facts: buildNightjarAssetIdentityFacts(asset),
        ),
        ?metadataSection,
        if (asset.declaredMetadata.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          NightjarFactsCard(
            key: const ValueKey('nightjar_asset_detail_metadata'),
            title: 'Declared metadata',
            facts: asset.declaredMetadata,
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        // The supply card is the only place a figure about the asset as a
        // whole appears, and there is one only for a public asset. The
        // footnote follows the asset: it says what is public here, which for
        // a private asset is nothing, rather than asserting a disclosure the
        // row directly above it denies.
        NightjarFactsCard(
          key: const ValueKey('nightjar_asset_detail_supply'),
          title: 'Supply',
          facts: supplyFacts.isEmpty
              ? const [
                  NightjarAssetFactData(
                    label: 'Issued supply',
                    value: 'Private',
                  ),
                ]
              : supplyFacts,
          footnote: nightjarSupplyFootnote(asset),
        ),
        const SizedBox(height: AppSpacing.md),
        NightjarFactsCard(
          key: const ValueKey('nightjar_asset_detail_holding'),
          title: 'Your holding',
          facts: buildNightjarWalletHoldingFacts(asset),
        ),
        const SizedBox(height: AppSpacing.md),
        // Nothing to send is not a reason to explain why sending is off: an
        // empty holding has its own, shorter, story below.
        if (onSend != null && asset.balance > BigInt.zero) ...[
          if (sendDisabledReason != null) ...[
            NightjarMessageCard(
              key: const ValueKey('nightjar_asset_detail_send_unavailable'),
              text: sendDisabledReason!,
              width: kNightjarCardWidth,
              tone: NightjarMessageTone.warning,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          Center(
            child: AppButton(
              key: const ValueKey('nightjar_asset_detail_send_button'),
              minWidth: 196,
              onPressed: sendDisabledReason == null ? onSend : null,
              child: const Text(kNightjarSendTitle),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (notes.isEmpty)
          const NightjarMessageCard(
            key: ValueKey('nightjar_asset_detail_no_notes'),
            text: 'This wallet holds no spendable notes of this asset.',
            width: kNightjarCardWidth,
          )
        else
          for (var i = 0; i < notes.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.md),
            NightjarFactsCard(
              key: ValueKey('nightjar_asset_detail_note_$i'),
              title: nightjarNoteCardTitle(i),
              facts: buildNightjarNoteFacts(notes[i]),
            ),
          ],
        const SizedBox(height: AppSpacing.base),
      ],
    );
  }
}
