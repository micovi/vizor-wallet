/// Mobile `/nyctis/receive` — the wallet's own Nyctis address.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../providers/nyctis_assets_view_provider.dart';
import '../nyctis_receive_screen.dart';
import 'mobile_nyctis_scaffold.dart';

class MobileNyctisReceiveScreen extends ConsumerWidget {
  const MobileNyctisReceiveScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = resolveNyctisView(ref.watch(nyctisAssetsViewProvider));

    return MobileNyctisScaffold(
      // Short enough for the centred nav title on a 375px phone; the body
      // says what the address is for.
      topNav: MobileTopNav.back(
        title: kNyctisMobileReceiveTitle,
        onBack: () => context.pop(),
      ),
      body: ListView(
        padding: kNyctisMobileListPadding,
        children: [
          NyctisReceiveBody(
            key: const ValueKey('mobile_nyctis_receive'),
            view: view,
            showTitle: false,
          ),
        ],
      ),
    );
  }
}

/// The phone's top-nav title for the receive screen.
const String kNyctisMobileReceiveTitle = 'Receive Nyctis';
