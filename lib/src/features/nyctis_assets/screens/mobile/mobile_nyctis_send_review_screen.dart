/// Mobile `/nyctis/send/review` — the last screen before any ZEC moves.
///
/// Chrome only. The review, the ZEC-cost statement and the anchor-age refusal
/// are [NyctisSendReviewBody] in `../nyctis_send_review_screen.dart`.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../services/nyctis_send_flow.dart';
import '../nyctis_send_chrome.dart';
import '../nyctis_send_review_screen.dart';

class MobileNyctisSendReviewScreen extends StatefulWidget {
  const MobileNyctisSendReviewScreen({required this.args, super.key});

  /// Null when the route was reached without a plan.
  final NyctisSendReviewArgs? args;

  @override
  State<MobileNyctisSendReviewScreen> createState() =>
      _MobileNyctisSendReviewScreenState();
}

class _MobileNyctisSendReviewScreenState
    extends State<MobileNyctisSendReviewScreen> {
  /// True while a rebuild is proving. Back is withheld until it ends.
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: !_busy,
      child: NyctisMobilePage(
        title: kNyctisReviewTitle,
        onBack: _busy ? null : () => context.pop(),
        child: NyctisSendReviewBody(
          key: const ValueKey('mobile_nyctis_send_review'),
          args: widget.args,
          showTitle: false,
          onBusyChanged: (busy) {
            if (!mounted || busy == _busy) return;
            setState(() => _busy = busy);
          },
        ),
      ),
    );
  }
}
