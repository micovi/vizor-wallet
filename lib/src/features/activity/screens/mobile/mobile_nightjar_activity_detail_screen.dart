/// Mobile `/activity/nightjar/:messageId` — the receipt a Nightjar activity
/// row opens.
///
/// Chrome only. The receipt, and every statement about what a Nightjar message
/// can and cannot tell the user, is [NightjarActivityDetailBody] in
/// `../nightjar_activity_detail_screen.dart`; the two form factors show the
/// same fields because they share it, and the rows underneath already branch
/// on `kAppFormFactor` inside `NightjarFactsCard`.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/app_mobile_tab_bar.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../nightjar_activity_detail_screen.dart';

class MobileNightjarActivityDetailScreen extends ConsumerWidget {
  const MobileNightjarActivityDetailScreen({required this.args, super.key});

  /// Null when the route was reached without a message.
  final NightjarActivityDetailArgs? args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = this.args;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          MobileTopNav.back(
            // The asset is what the user tapped; the screen's job is named by
            // the card headings below it, not by a second line of chrome.
            title: args == null
                ? kNightjarActivityDetailTitle
                : args.assetTitle,
            onBack: () => context.pop(),
          ),
          Expanded(
            child: MobileBottomSafeArea(
              bottomPadding: kMobileTabBarHeight + AppSpacing.lg,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s,
                  AppSpacing.s,
                  AppSpacing.s,
                  kMobileTabBarHeight + AppSpacing.lg,
                ),
                children: [
                  NightjarActivityDetailBody(
                    key: const ValueKey('mobile_nightjar_activity_detail'),
                    args: args,
                    showTitle: false,
                    privacyModeEnabled: ref.watch(privacyModeProvider),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
