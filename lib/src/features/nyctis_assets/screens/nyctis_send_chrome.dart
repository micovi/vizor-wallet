/// The frame the three Nyctis send screens share: the desktop pane with its
/// back toolbar, and the mobile page with its top nav.
///
/// Both withhold their back control while the body is busy — proving on the
/// composer and the review, broadcasting on the status screen — and the
/// desktop one adds a `PopScope` so the system back gesture agrees. The
/// toolbar's back link pops through the router, which does not consult
/// `PopScope`, so hiding it is the only way to keep it from abandoning a proof
/// or a broadcast halfway.
library;

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';

import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../widgets/nyctis_assets_feed.dart';

/// Minimum width of a primary send-flow button, matching
/// `ReviewButtonsStack`.
const double kNyctisSendButtonMinWidth = 196;

/// Desktop pane chrome for a send screen.
class NyctisSendPaneFrame extends StatelessWidget {
  const NyctisSendPaneFrame({
    required this.busy,
    required this.child,
    this.popScope = true,
    super.key,
  });

  /// True while the body owns work that leaving would abandon.
  final bool busy;

  /// Whether this frame adds its own `PopScope`. The status body owns a
  /// stricter one and turns this off.
  final bool popScope;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scaffold = AppPaneScrollScaffold(
      toolbar: AppPaneToolbar(
        backLinkMinWidth: 60,
        leading: busy
            ? const SizedBox.shrink(key: ValueKey('nyctis_send_back_hidden'))
            : null,
      ),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(width: kNyctisCardWidth, child: child),
      ),
    );
    if (!popScope) return scaffold;
    return PopScope<void>(canPop: !busy, child: scaffold);
  }
}

/// Mobile page chrome for a pushed Nyctis screen: an opaque window-coloured
/// page (a bare `SafeArea` would show whatever route is underneath), a toast
/// host for the copy actions, and the top nav with its back control withheld
/// while [onBack] is null, over a scrolling body.
///
/// These routes are pushed over the tab shell, which hides the tab bar, so
/// the bottom padding is the ordinary content inset rather than room for a
/// bar that is not there.
class NyctisMobilePage extends StatelessWidget {
  const NyctisMobilePage({
    required this.title,
    required this.onBack,
    required this.child,
    super.key,
  });

  final String title;

  /// Null hides the back control.
  final VoidCallback? onBack;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background.window,
      body: AppToastHost(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              MobileTopNav.back(title: title, onBack: onBack),
              Expanded(
                child: MobileBottomSafeArea(
                  bottomPadding: AppSpacing.md,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      AppSpacing.s,
                      AppSpacing.sm,
                      AppSpacing.md,
                    ),
                    children: [child],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
