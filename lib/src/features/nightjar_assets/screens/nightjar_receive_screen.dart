/// Desktop `/nightjar/receive` — the wallet's own Nightjar address.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/nightjar_assets_view_provider.dart';
import '../widgets/nightjar_asset_row_data.dart';
import '../widgets/nightjar_asset_row_mapper.dart';
import '../widgets/nightjar_assets_feed.dart';
import '../widgets/nightjar_receive_panel.dart';

class NightjarReceiveScreen extends StatelessWidget {
  const NightjarReceiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppDesktopShell(
      sidebar: AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: NightjarReceivePane(),
      ),
    );
  }
}

/// The pane body without the sidebar, so it renders on its own in tests and
/// in Widgetbook.
class NightjarReceivePane extends ConsumerWidget {
  const NightjarReceivePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = resolveNightjarView(ref.watch(nightjarAssetsViewProvider));

    return AppPaneScrollScaffold(
      toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: kNightjarCardWidth,
          child: NightjarReceiveBody(view: view),
        ),
      ),
    );
  }
}

/// Presentational body shared by the desktop pane and the mobile screen.
class NightjarReceiveBody extends StatelessWidget {
  const NightjarReceiveBody({
    required this.view,
    this.showTitle = true,
    super.key,
  });

  /// Null while the first load is in flight.
  final NightjarViewData? view;

  /// Desktop draws its own title; the mobile top nav already carries one.
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final view = this.view;

    final Widget body;
    if (view == null) {
      body = const NightjarMessageCard(
        key: ValueKey('nightjar_receive_loading'),
        text: 'Loading your Nightjar address...',
        width: kNightjarCardWidth,
      );
    } else if (!view.isConfigured) {
      // An address the wallet cannot yet read a channel for would be a
      // dead end, so the unconfigured state says so instead.
      body = const NightjarMessageCard(
        key: ValueKey('nightjar_receive_not_configured'),
        text: kNightjarNotConfiguredText,
        width: kNightjarCardWidth,
      );
    } else {
      body = NightjarReceivePanel(
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
            child: Text(
              'Receive Nightjar assets',
              key: const ValueKey('nightjar_receive_title'),
              style: AppTypography.headlineSmall.copyWith(
                color: colors.text.accent,
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
