/// The chrome every mobile Nyctis screen shares: the window-coloured
/// scaffold, the top nav, and a bottom inset that matches what is actually
/// below the content.
///
/// These routes are pushed over the tab shell, so the tab bar is hidden and
/// there is nothing to reserve room for; the bottom gap is the same token the
/// side gutters use. A bare `SafeArea` with no scaffold behind it let the
/// shell's colours show through, and the dark title vanished against them.
library;

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';

import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/theme/app_theme.dart';

/// Side gutter of a pushed mobile screen, as sibling screens use.
const double kNyctisMobileSidePadding = AppSpacing.sm;

/// Space under the last element, above the home indicator.
const double kNyctisMobileBottomPadding = AppSpacing.md;

/// The content padding a mobile Nyctis list uses.
const EdgeInsets kNyctisMobileListPadding = EdgeInsets.fromLTRB(
  kNyctisMobileSidePadding,
  AppSpacing.s,
  kNyctisMobileSidePadding,
  kNyctisMobileBottomPadding,
);

class MobileNyctisScaffold extends StatelessWidget {
  const MobileNyctisScaffold({
    required this.topNav,
    required this.body,
    super.key,
  });

  final Widget topNav;

  /// The scrollable content. It is given the bottom safe area already.
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background.window,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            topNav,
            Expanded(
              child: MobileBottomSafeArea(
                bottomPadding: kNyctisMobileBottomPadding,
                child: body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
