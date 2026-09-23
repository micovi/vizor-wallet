// ignore_for_file: depend_on_referenced_packages
// widgetbook is dev-only; see `widgetbook.dart` for the boundary.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../src/core/layout/app_desktop_shell.dart';
import '../src/core/layout/app_pane_scroll_scaffold.dart';
import '../src/core/theme/app_theme.dart';
import '../src/core/widgets/app_back_link.dart';
import '../src/core/widgets/app_button.dart';
import '../src/core/widgets/app_icon.dart';
import '../src/features/activity/activity_feed_sections.dart';
import '../src/features/activity/models/activity_row_data.dart';
import '../src/features/activity/gift_card_activity_index.dart';
import '../src/features/activity/nyctis_activity_row_mapper.dart';
import '../src/features/activity/widgets/activity_feed.dart';
import '../src/features/activity/widgets/gift_card_activity_detail_view.dart';
import '../src/features/payment_links/widgets/payment_link_gift_card.dart';

Widget buildActivityPageUseCase(BuildContext context) {
  return SizedBox(
    width: 1080,
    height: 720,
    child: AppDesktopShell(
      sidebar: const _ActivityUseCaseSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: ColoredBox(
          key: const ValueKey('activity_page_pane_background'),
          color: context.colors.macosUtility.window,
          child: Stack(
            children: [
              const Positioned(
                left: 0,
                top: 0,
                right: 0,
                height: 48,
                child: AppPaneToolbar(
                  leading: AppBackLink(
                    key: ValueKey('activity_page_back_button'),
                    label: 'Home',
                    minWidth: 60,
                    onTap: _noop,
                  ),
                  padding: EdgeInsets.only(
                    left: AppSpacing.sm,
                    top: AppSpacing.xs,
                    bottom: AppSpacing.xs,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 48,
                right: 0,
                bottom: 0,
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  child: SingleChildScrollView(
                    key: const ValueKey('activity_page_scroll_view'),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        width: 420,
                        child: Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.sm),
                          child: ActivityFeed(
                            sections: _activitySections(context),
                            rowKeyPrefix: 'activity_page',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Nyctis messages beside ZEC transactions, through the real mapper.
///
/// Four cases the copy has to survive, all in one feed: the send this feature
/// exists for (1 000 in, 988 back as change, so the row is the 12 that left
/// and the change is not a row at all), a receipt of a named asset, a receipt
/// of an asset the issuer never named (truncated id, no ticker), and a message
/// whose block the indexer could not date — which sorts last and groups under
/// "Earlier" rather than being given a time it has not got.
Widget buildNyctisActivityUseCase(BuildContext context) {
  final now = DateTime.now();
  final items = [
    NyctisActivityItem(
      msgId: '2f1d4c6b8a097e53',
      assetId:
          'a3f1c0d29b8e47a5f6031d8c2b7e4906aa11bb22cc33dd44ee55ff6600778899',
      name: 'Devnet Mint',
      symbol: 'DMT',
      kind: NyctisActivityKind.sent,
      delta: BigInt.from(-1200),
      moved: BigInt.from(100000),
      decimals: 2,
      height: BigInt.from(7257),
      ownedInputs: 1,
      totalInputs: 1,
      ownedOutputs: 1,
      totalOutputs: 2,
      timestamp: now.subtract(const Duration(hours: 2)),
    ),
    NyctisActivityItem(
      msgId: '9c8b7a6f5e4d3c2b',
      assetId:
          'a3f1c0d29b8e47a5f6031d8c2b7e4906aa11bb22cc33dd44ee55ff6600778899',
      name: 'Devnet Mint',
      symbol: 'DMT',
      kind: NyctisActivityKind.received,
      delta: BigInt.from(100),
      moved: BigInt.zero,
      decimals: 2,
      height: BigInt.from(7164),
      ownedOutputs: 1,
      totalOutputs: 1,
      timestamp: now.subtract(const Duration(hours: 3)),
    ),
    NyctisActivityItem(
      msgId: '00112233445566aa',
      assetId:
          '00ff11ee22dd33cc44bb55aa6699778800112233445566778899aabbccddeeff',
      kind: NyctisActivityKind.received,
      delta: BigInt.from(5),
      moved: BigInt.zero,
      decimals: 0,
      height: BigInt.from(7030),
      ownedOutputs: 1,
      totalOutputs: 1,
      timestamp: now.subtract(const Duration(days: 40)),
    ),
    NyctisActivityItem(
      msgId: 'bbccddee00112233',
      assetId:
          'a3f1c0d29b8e47a5f6031d8c2b7e4906aa11bb22cc33dd44ee55ff6600778899',
      name: 'Devnet Mint',
      symbol: 'DMT',
      kind: NyctisActivityKind.received,
      delta: BigInt.from(2550),
      moved: BigInt.zero,
      decimals: 2,
      height: BigInt.from(2201),
      ownedOutputs: 1,
      totalOutputs: 1,
    ),
  ];

  final entries = <ActivityEntry>[
    ActivityEntry(
      timestamp: now.subtract(const Duration(hours: 1)),
      row: _activityRow(
        context,
        title: 'Received ZEC',
        iconName: AppIcons.arrowDownCircle,
        subtitle: 'Ironwood',
        subtitleIconName: AppIcons.shieldKeyholeOutline,
        amountText: '+1.25 ZEC',
        amountColor: context.colors.text.positiveStrong,
      ),
    ),
    ...buildNyctisActivityEntries(context: context, items: items),
  ];

  return SizedBox(
    width: 480,
    height: 720,
    child: ColoredBox(
      color: context.colors.macosUtility.window,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: ActivityFeed(
          sections: buildActivityFeedSections(entries),
          rowKeyPrefix: 'nyctis_activity',
        ),
      ),
    ),
  );
}

/// The same feed, once the user has accepted one of the two assets.
///
/// This is the pair the row's logo support exists for, and the pair worth
/// looking at together:
///
/// * **Accepted** — `Devnet Mint` draws the issuer's picture in the circle the
///   generic shield used to occupy, *and* its truncated `asset_id` on the
///   supporting line. `spec/asset-metadata-v0.md` section 5: a name and a
///   picture are the impersonation, so the id goes wherever the logo goes.
/// * **Not accepted** — the unnamed asset has no bytes in the logo map,
///   because `nyctisAssetLogosProvider` is built from the accepted set. It
///   falls back to the icon with nothing else changed, and its truncated id
///   is on the supporting line either way, where the asset is named.
///
/// Both rows are messages rather than notes: a receipt and a send, the send
/// showing the difference that left rather than the change that came back.
Widget buildNyctisActivityLogoUseCase(BuildContext context) {
  final now = DateTime.now();
  final items = [
    NyctisActivityItem(
      msgId: 'a1b2c3d4e5f60718',
      assetId: _acceptedAssetId,
      name: 'Devnet Mint',
      symbol: 'DMT',
      kind: NyctisActivityKind.sent,
      // 1 000 in, 988 back as change: the row is the 12 that left, and the
      // change is not a row at all.
      delta: BigInt.from(-1200),
      moved: BigInt.from(100000),
      decimals: 2,
      height: BigInt.from(7257),
      ownedInputs: 1,
      totalInputs: 1,
      ownedOutputs: 1,
      totalOutputs: 2,
      timestamp: now.subtract(const Duration(hours: 3)),
    ),
    NyctisActivityItem(
      msgId: 'f0e1d2c3b4a59687',
      assetId: _unacceptedAssetId,
      kind: NyctisActivityKind.received,
      delta: BigInt.from(5),
      moved: BigInt.zero,
      decimals: 0,
      height: BigInt.from(7030),
      ownedOutputs: 1,
      totalOutputs: 1,
      timestamp: now.subtract(const Duration(hours: 5)),
    ),
  ];

  // What `nyctisAssetLogosProvider` would answer with one asset accepted.
  final logos = <String, Uint8List>{_acceptedAssetId: _sampleLogoPng};

  final entries = <ActivityEntry>[
    for (final item in items)
      nyctisActivityEntry(context: context, item: item, logos: logos),
  ];

  return SizedBox(
    width: 480,
    height: 420,
    child: ColoredBox(
      color: context.colors.macosUtility.window,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: ActivityFeed(
          sections: buildActivityFeedSections(entries),
          rowKeyPrefix: 'nyctis_activity_logo',
        ),
      ),
    ),
  );
}

const _acceptedAssetId =
    'a3f1c0d29b8e47a5f6031d8c2b7e4906aa11bb22cc33dd44ee55ff6600778899';
const _unacceptedAssetId =
    '00ff11ee22dd33cc44bb55aa6699778800112233445566778899aabbccddeeff';

/// A 64x64 PNG standing in for an issuer's logo. Real bytes, so the row's
/// bounded decode is exercised rather than mocked.
final Uint8List _sampleLogoPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAABAklEQVR42u2bwRGD'
  'MAwEKSOTV0pJ1+ksX9ICKLqTZC8zfDG7NjNY1h0HV+31/bzPLSCj95bQY2UooEfI'
  'cIK3E1EJXyoh6+Ufz9c8ERHI6N1Oggv8HxHl8JngUREl8ErwiAgbvBP8roil4eUS'
  'JsBLJUyBvyJhefhUCVPh0yRsLcANr3xuSIJSgPM3Ol2AE149pnX2s7bMllXQEV71'
  'DnIBisqPVEDn2besgu6zL18FWQM6iqAIQAACEJAqYBI8EvgEEIAABLAXaC5g5G5w'
  '+3oAFSFqglSFORfgZIizQQTQH0CHCD1CdInRJ0inKL3CdIuTFyAxQmaI1Bi5QZKj'
  'ZIfXT4//AMqxRvxNdz9DAAAAAElFTkSuQmCC',
);

Widget buildCreatedGiftCardActivityDetailUseCase(BuildContext context) {
  return _buildGiftCardActivityDetailUseCase(
    context,
    kind: GiftCardActivityKind.created,
    artwork: PaymentLinkCardArtwork.ruby,
  );
}

Widget buildRedeemedGiftCardActivityDetailUseCase(BuildContext context) {
  return _buildGiftCardActivityDetailUseCase(
    context,
    kind: GiftCardActivityKind.redeemed,
    artwork: PaymentLinkCardArtwork.crystal,
  );
}

Widget _buildGiftCardActivityDetailUseCase(
  BuildContext context, {
  required GiftCardActivityKind kind,
  required PaymentLinkCardArtwork artwork,
}) {
  return SizedBox(
    width: 1080,
    height: 720,
    child: AppDesktopShell(
      sidebar: const _ActivityUseCaseSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: AppPaneScrollScaffold(
          toolbar: AppPaneToolbar(
            leading: AppBackLink(label: 'Activity', minWidth: 60, onTap: _noop),
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: GiftCardActivityDetailView(
            kind: kind,
            artwork: artwork,
            amountText: '4.45',
            supportingText: r'$142.23',
            statusText: 'Completed',
            statusIconName: AppIcons.checkCircle,
            statusColor: context.colors.text.positiveStrong,
            message: 'Hope this makes your day a little brighter!',
            timestampText: '25 May, 13:30',
            txIdText: 'f154...8143',
            feeText: kind == GiftCardActivityKind.created
                ? '0.0002 ZEC'
                : '0.0001 ZEC',
            onTxIdPressed: _noop,
            onToggleMessage: _noop,
          ),
        ),
      ),
    ),
  );
}

void _noop() {}

List<ActivityFeedSectionData> _activitySections(BuildContext context) {
  return [
    ActivityFeedSectionData(
      title: 'This week',
      rows: [
        _activityRow(
          context,
          title: 'Redeemed a gift card',
          iconName: AppIcons.giftCard,
          subtitle: 'Shielded',
          subtitleIconName: AppIcons.shieldKeyholeOutline,
          amountText: '+31.10 ZEC',
          amountColor: context.colors.text.positiveStrong,
          onTap: _noop,
        ),
        _activityRow(
          context,
          title: 'Created a gift card',
          iconName: AppIcons.giftCard,
          subtitle: 'Shielded',
          subtitleIconName: AppIcons.shieldKeyholeOutline,
          amountText: '-31.10 ZEC',
          onTap: _noop,
        ),
        // Unconfirmed receive: loader glyph + progressive title, per the
        // Content Line pending variant.
        _activityRow(
          context,
          title: 'Receiving ...',
          iconName: AppIcons.loader,
          subtitle: 'Shielded',
          subtitleIconName: AppIcons.shieldKeyholeOutline,
          amountText: '+5.40 ZEC',
          amountColor: context.colors.text.positiveStrong,
          statusText: 'In progress',
        ),
        // Completed external->ZEC swap. The settled receive leg renders as the
        // group's single result child (the in-flight 'Receiving ZEC...' child
        // and the duplicate standalone 'Received ZEC' row are gone under the
        // new results-only / receive-absorption policy).
        _activityRow(
          context,
          title: 'Swapped',
          iconName: AppIcons.swapArrows,
          subtitle: 'USDC on Optimism',
          amountText: '-26.60 USDC',
          childRows: [
            _activityRow(
              context,
              title: 'Received ZEC',
              iconName: AppIcons.swapArrows,
              amountText: '+12.13 ZEC',
              amountColor: context.colors.text.primary,
              statusText: '',
            ),
          ],
        ),
        _activityRow(
          context,
          title: 'Sent ZEC',
          iconName: AppIcons.plane,
          subtitle: 'Shielded',
          subtitleIconName: AppIcons.shieldKeyholeOutline,
          amountText: '-4.12 ZEC',
        ),
      ],
    ),
    ActivityFeedSectionData(
      title: 'April 2026',
      rows: [
        _activityRow(
          context,
          title: 'Send failed',
          iconName: AppIcons.plane,
          subtitle: 'Transparent',
          amountText: '1.11 ZEC',
          amountIconName: AppIcons.arrowBack,
          amountSubtitle: 'Refunded',
          statusText: 'Failed',
          statusIconName: AppIcons.skull,
          statusColor: context.colors.text.destructive,
        ),
        _activityRow(
          context,
          title: 'Shielded',
          iconName: AppIcons.shieldKeyholeOutline,
          amountText: '0.30 ZEC',
        ),
      ],
    ),
  ];
}

ActivityRowData _activityRow(
  BuildContext context, {
  required String title,
  required String amountText,
  String iconName = AppIcons.sync,
  String? subtitle,
  String? subtitleIconName,
  String? amountIconName,
  String? amountSubtitle,
  String statusText = 'Completed',
  String? statusIconName,
  Color? statusColor,
  Color? amountColor,
  double? progress,
  List<ActivityRowData> childRows = const [],
  VoidCallback? onTap,
}) {
  final colors = context.colors;
  return ActivityRowData(
    title: title,
    leadingIconName: iconName,
    leadingBackgroundColor: colors.background.neutralSubtleOpacity,
    leadingIconColor: colors.icon.regular,
    leadingProgressValue: progress,
    subtitle: subtitle,
    subtitleIconName: subtitleIconName,
    amountText: amountText,
    amountIconName: amountIconName,
    amountIconColor: amountIconName == null ? null : colors.icon.regular,
    amountColor: amountColor ?? colors.text.primary,
    amountSubtitle: amountSubtitle,
    statusText: statusText,
    statusIconName: statusIconName,
    statusColor: statusColor ?? colors.text.secondary,
    timestampText: 'Today, 13:11',
    childRows: childRows,
    onTap: onTap,
  );
}

class _ActivityUseCaseSidebar extends StatelessWidget {
  const _ActivityUseCaseSidebar();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AppDesktopSidebarSurface(
      glass: true,
      clipBehavior: Clip.none,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 40),
            const AppSidebarItem(
              label: 'Username',
              iconName: AppIcons.user,
              leadingGap: AppSpacing.xs,
            ),
            const SizedBox(height: AppSpacing.md),
            AppSidebarItem(
              label: 'Home',
              iconName: AppIcons.home,
              onTap: () {},
            ),
            const SizedBox(height: AppSpacing.xs),
            AppSidebarItem(
              label: 'Swap',
              iconName: AppIcons.swapArrows,
              onTap: () {},
            ),
            const SizedBox(height: AppSpacing.xs),
            AppSidebarItem(label: 'Pay', iconName: AppIcons.paid, onTap: () {}),
            const SizedBox(height: AppSpacing.xs),
            AppSidebarItem(
              label: 'Vote',
              iconName: AppIcons.vote,
              onTap: () {},
            ),
            const SizedBox(height: AppSpacing.xs),
            const AppSidebarItem(
              label: 'Activity',
              iconName: AppIcons.history,
              active: true,
            ),
            const Spacer(),
            AppSidebarItem(
              label: 'Settings',
              iconName: AppIcons.cog,
              onTap: () {},
            ),
            const SizedBox(height: AppSpacing.xs),
            AppSidebarItem(
              label: 'Sign out',
              iconName: AppIcons.logOut,
              onTap: () {},
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              height: 34,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: -AppSpacing.sm,
                    top: 1,
                    bottom: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.sync.lightSuccess,
                        borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(AppRadii.full),
                        ),
                      ),
                      child: const SizedBox(width: 5),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '34% Syncing...',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.labelLarge.copyWith(
                        color: colors.sync.textSyncing,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}

/// Demonstrates the receive-absorption transition: tapping 'Absorb receive'
/// removes the standalone on-chain 'Received ZEC' row and grows the completed
/// swap group's tappable receive child, letting the AnimatedSize / entrance
/// animation play.
Widget buildSwapReceiveAbsorbUseCase(BuildContext context) {
  return const Center(
    child: SizedBox(width: 420, child: _SwapReceiveAbsorbUseCase()),
  );
}

class _SwapReceiveAbsorbUseCase extends StatefulWidget {
  const _SwapReceiveAbsorbUseCase();

  @override
  State<_SwapReceiveAbsorbUseCase> createState() =>
      _SwapReceiveAbsorbUseCaseState();
}

class _SwapReceiveAbsorbUseCaseState extends State<_SwapReceiveAbsorbUseCase> {
  bool _absorbed = false;

  void _toggle() {
    setState(() => _absorbed = !_absorbed);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final swapRow = _activityRow(
      context,
      title: 'Swapped',
      iconName: AppIcons.swapArrows,
      subtitle: 'USDC on Ethereum',
      amountText: '-101.23 USDC',
      childRows: _absorbed
          ? [
              _activityRow(
                context,
                title: 'Received ZEC',
                iconName: AppIcons.swapArrows,
                amountText: '+12.13 ZEC',
                amountColor: colors.text.primary,
                statusText: '',
                onTap: () {},
              ),
            ]
          : const [],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s,
        vertical: AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppButton(
            key: const ValueKey('swap_receive_absorb_toggle'),
            onPressed: _toggle,
            variant: AppButtonVariant.secondary,
            child: Text(_absorbed ? 'Reset' : 'Absorb receive'),
          ),
          const SizedBox(height: AppSpacing.md),
          ActivityFeed(
            rowKeyPrefix: 'swap_receive_absorb',
            sections: [
              ActivityFeedSectionData(
                title: 'This week',
                rows: [
                  swapRow,
                  if (!_absorbed)
                    _activityRow(
                      context,
                      title: 'Received ZEC',
                      iconName: AppIcons.arrowDownCircle,
                      subtitle: 'Shielded',
                      subtitleIconName: AppIcons.shieldKeyholeOutline,
                      amountText: '+12.13 ZEC',
                      amountColor: colors.text.positiveStrong,
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
