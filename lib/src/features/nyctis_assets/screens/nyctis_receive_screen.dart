/// Desktop `/nyctis/receive` — the wallet's own Nyctis address.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/nyctis_assets_view_provider.dart';
import '../widgets/nyctis_asset_row_data.dart';
import '../widgets/nyctis_asset_row_mapper.dart';
import '../widgets/nyctis_assets_feed.dart';
import '../widgets/nyctis_receive_panel.dart';

class NyctisReceiveScreen extends StatelessWidget {
  const NyctisReceiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppDesktopShell(
      sidebar: AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NyctisReceivePane(),
      ),
    );
  }
}

/// The pane body without the sidebar, so it renders on its own in tests and
/// in Widgetbook.
class NyctisReceivePane extends ConsumerWidget {
  const NyctisReceivePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = resolveNyctisView(ref.watch(nyctisAssetsViewProvider));

    return AppPaneScrollScaffold(
      toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: kNyctisCardWidth,
          child: NyctisReceiveBody(view: view),
        ),
      ),
    );
  }
}

/// Presentational body shared by the desktop pane and the mobile screen.
class NyctisReceiveBody extends StatelessWidget {
  const NyctisReceiveBody({
    required this.view,
    this.showTitle = true,
    super.key,
  });

  /// Null while the first load is in flight.
  final NyctisViewData? view;

  /// Desktop draws its own title; the mobile top nav already carries one.
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final view = this.view;

    final Widget body;
    if (view == null) {
      body = const NyctisMessageCard(
        key: ValueKey('nyctis_receive_loading'),
        text: 'Loading your Nyctis address…',
        width: kNyctisCardWidth,
        loading: true,
        liveRegion: true,
      );
    } else if (!view.isConfigured) {
      // An address the wallet cannot yet read a channel for would be a
      // dead end, so the unconfigured state says so instead.
      body = const NyctisMessageCard(
        key: ValueKey('nyctis_receive_not_configured'),
        text: kNyctisNotConfiguredText,
        width: kNyctisCardWidth,
      );
    } else {
      body = NyctisReceivePanel(
        address: view.identity?.address,
        networkLabel: view.identity?.networkLabel,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTitle) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
            child: Semantics(
              header: true,
              child: Text(
                'Receive Nyctis assets',
                key: const ValueKey('nyctis_receive_title'),
                textAlign: TextAlign.center,
                style: AppTypography.headlineLarge.copyWith(
                  color: colors.text.accent,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.base),
        ],
        Align(alignment: Alignment.topCenter, child: body),
        const SizedBox(height: AppSpacing.base),
      ],
    );
  }
}
