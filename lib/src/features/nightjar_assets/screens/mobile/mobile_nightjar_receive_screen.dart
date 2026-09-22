/// Mobile `/nightjar/receive` — the wallet's own Nightjar address.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/app_mobile_tab_bar.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../providers/nightjar_assets_view_provider.dart';
import '../nightjar_receive_screen.dart';

class MobileNightjarReceiveScreen extends ConsumerWidget {
  const MobileNightjarReceiveScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = resolveNightjarView(ref.watch(nightjarAssetsViewProvider));

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          MobileTopNav.back(
            title: 'Receive Nightjar assets',
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
                  NightjarReceiveBody(
                    key: const ValueKey('mobile_nightjar_receive'),
                    view: view,
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
