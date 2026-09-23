/// Mobile `/activity/nyctis/:messageId` — the receipt a Nyctis activity
/// row opens.
///
/// Chrome only. The receipt, and every statement about what a Nyctis message
/// can and cannot tell the user, is [NyctisActivityDetailBody] in
/// `../nyctis_activity_detail_screen.dart`; the two form factors show the
/// same fields because they share it, and the rows underneath already branch
/// on `kAppFormFactor` inside `NyctisFactsCard`.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../providers/privacy_mode_provider.dart';
import '../../../nyctis_assets/screens/nyctis_send_chrome.dart';
import '../nyctis_activity_detail_screen.dart';

class MobileNyctisActivityDetailScreen extends ConsumerWidget {
  const MobileNyctisActivityDetailScreen({required this.args, super.key});

  /// Null when the route was reached without a message.
  final NyctisActivityDetailArgs? args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = this.args;
    return NyctisMobilePage(
      // The asset is what the user tapped; what happened is the hero's
      // headline right under it.
      title: args == null ? kNyctisActivityDetailTitle : args.assetTitle,
      onBack: () => context.pop(),
      child: NyctisActivityDetailBody(
        key: const ValueKey('mobile_nyctis_activity_detail'),
        args: args,
        privacyModeEnabled: ref.watch(privacyModeProvider),
      ),
    );
  }
}
