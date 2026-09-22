/// Mobile `/nightjar/send/review` — the last screen before any ZEC moves.
///
/// Chrome only. The review, the ZEC-cost statement and the anchor-age refusal
/// are [NightjarSendReviewBody] in `../nightjar_send_review_screen.dart`.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/app_mobile_tab_bar.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../services/nightjar_send_flow.dart';
import '../nightjar_send_review_screen.dart';

class MobileNightjarSendReviewScreen extends StatelessWidget {
  const MobileNightjarSendReviewScreen({required this.args, super.key});

  /// Null when the route was reached without a plan.
  final NightjarSendReviewArgs? args;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          MobileTopNav.back(
            title: kNightjarReviewTitle,
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
                  NightjarSendReviewBody(
                    key: const ValueKey('mobile_nightjar_send_review'),
                    args: args,
                    showTitle: false,
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
