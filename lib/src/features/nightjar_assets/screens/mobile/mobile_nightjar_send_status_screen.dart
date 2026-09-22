/// Mobile `/nightjar/send/status` — the broadcast leg and its receipt.
///
/// Chrome only. The broadcast, the proposal lifecycle and the receipt copy are
/// [NightjarSendStatusBody] in `../nightjar_send_status_screen.dart`.
///
/// The back arrow is withheld while the send is in flight, which is what the
/// desktop pane gets from the body's own `PopScope`: a live send owns a
/// proposal and this wallet's ZEC inputs, and leaving mid-broadcast throws
/// away the only receipt there will be.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/app_mobile_tab_bar.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../services/nightjar_send_flow.dart';
import '../nightjar_send_status_screen.dart';

/// Neutral chrome title: the body owns the one that changes with the outcome.
const String kMobileNightjarStatusNavTitle = 'Nightjar payment';

class MobileNightjarSendStatusScreen extends StatefulWidget {
  const MobileNightjarSendStatusScreen({
    required this.args,
    this.broadcastRunner,
    super.key,
  });

  /// Null when the route was reached without a plan.
  final NightjarSendReviewArgs? args;

  @visibleForTesting
  final NightjarSendBroadcastRunner? broadcastRunner;

  @override
  State<MobileNightjarSendStatusScreen> createState() =>
      _MobileNightjarSendStatusScreenState();
}

class _MobileNightjarSendStatusScreenState
    extends State<MobileNightjarSendStatusScreen> {
  bool _isSending = false;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          MobileTopNav.back(
            title: kMobileNightjarStatusNavTitle,
            onBack: _isSending ? null : () => context.go('/nightjar'),
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
                  NightjarSendStatusBody(
                    key: const ValueKey('mobile_nightjar_send_status'),
                    args: widget.args,
                    broadcastRunner: widget.broadcastRunner,
                    onSendingChanged: (isSending) {
                      if (!mounted) return;
                      setState(() => _isSending = isSending);
                    },
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
