/// Mobile `/nyctis/:assetId/send` — compose a Nyctis payment.
///
/// Chrome only. The composer, its validation and its copy are
/// [NyctisSendBody] in `../nyctis_send_screen.dart`, so the two form
/// factors cannot disagree about what a Nyctis payment costs or when the
/// button is allowed to work.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../nyctis_send_chrome.dart';
import '../nyctis_send_screen.dart';

class MobileNyctisSendScreen extends StatefulWidget {
  const MobileNyctisSendScreen({required this.assetId, super.key});

  final String assetId;

  @override
  State<MobileNyctisSendScreen> createState() => _MobileNyctisSendScreenState();
}

class _MobileNyctisSendScreenState extends State<MobileNyctisSendScreen> {
  /// True while a proof is running. The back control is withheld and system
  /// back refused until it ends: leaving would throw the plan away.
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: !_busy,
      child: NyctisMobilePage(
        title: kNyctisSendTitle,
        onBack: _busy ? null : () => context.pop(),
        child: NyctisSendBody(
          key: const ValueKey('mobile_nyctis_send'),
          assetId: widget.assetId,
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
