/// Mobile `/nyctis/send/status` — the broadcast leg and its receipt.
///
/// Chrome only. The broadcast, the proposal lifecycle and the receipt copy are
/// [NyctisSendStatusBody] in `../nyctis_send_status_screen.dart`.
///
/// The back arrow is withheld while the send is in flight: a live send owns a
/// proposal and this wallet's ZEC inputs, and leaving mid-broadcast throws
/// away the only receipt there will be. Afterwards it leaves for the assets
/// list, never back to the review — that plan has been broadcast. System back
/// is handled the same way by the body's own `PopScope`.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../services/nyctis_send_flow.dart';
import '../nyctis_send_chrome.dart';
import '../nyctis_send_status_screen.dart';

/// Neutral chrome title: the body owns the one that changes with the outcome.
const String kMobileNyctisStatusNavTitle = 'Nyctis payment';

class MobileNyctisSendStatusScreen extends StatefulWidget {
  const MobileNyctisSendStatusScreen({
    required this.args,
    this.broadcastRunner,
    super.key,
  });

  /// Null when the route was reached without a plan.
  final NyctisSendReviewArgs? args;

  @visibleForTesting
  final NyctisSendBroadcastRunner? broadcastRunner;

  @override
  State<MobileNyctisSendStatusScreen> createState() =>
      _MobileNyctisSendStatusScreenState();
}

class _MobileNyctisSendStatusScreenState
    extends State<MobileNyctisSendStatusScreen> {
  bool _isSending = false;

  @override
  Widget build(BuildContext context) {
    return NyctisMobilePage(
      title: kMobileNyctisStatusNavTitle,
      onBack: _isSending ? null : () => context.go(kNyctisStatusExitRoute),
      child: NyctisSendStatusBody(
        key: const ValueKey('mobile_nyctis_send_status'),
        args: widget.args,
        broadcastRunner: widget.broadcastRunner,
        onSendingChanged: (isSending) {
          if (!mounted) return;
          setState(() => _isSending = isSending);
        },
      ),
    );
  }
}
