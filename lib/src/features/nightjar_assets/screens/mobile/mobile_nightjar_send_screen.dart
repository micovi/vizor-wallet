/// Mobile `/nightjar/:assetId/send` — compose a Nightjar payment.
///
/// Chrome only. The composer, its validation and its copy are
/// [NightjarSendBody] in `../nightjar_send_screen.dart`, so the two form
/// factors cannot disagree about what a Nightjar payment costs or when the
/// button is allowed to work.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/app_mobile_tab_bar.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../nightjar_send_screen.dart';

class MobileNightjarSendScreen extends StatelessWidget {
  const MobileNightjarSendScreen({required this.assetId, super.key});

  final String assetId;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          MobileTopNav.back(
            title: kNightjarSendTitle,
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
                  NightjarSendBody(
                    key: const ValueKey('mobile_nightjar_send'),
                    assetId: assetId,
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
