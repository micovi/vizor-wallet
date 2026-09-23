import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/src/core/config/nyctis_config.dart';
import 'package:zcash_wallet/src/core/navigation/mobile_routes.dart';
import 'package:zcash_wallet/src/features/activity/screens/nyctis_activity_detail_screen.dart';
import 'package:zcash_wallet/src/providers/nyctis_config_provider.dart';

/// Every route path in [routes], nested ones included.
Iterable<String> _paths(List<RouteBase> routes) sync* {
  for (final route in routes) {
    if (route is GoRoute) yield route.path;
    yield* _paths(route.routes);
  }
}

bool _isNyctisPath(String path) =>
    path == '/nyctis' ||
    path.startsWith('/nyctis/') ||
    path == '/settings/nyctis' ||
    path == nyctisActivityDetailRoutePattern;

void main() {
  // These follow whatever the lane was compiled with, so they hold in a plain
  // `fvm flutter test` (the define absent, the upstream shape) and in a run
  // that passes `--dart-define=VIZOR_NYCTIS_ENABLED=true`.
  test('VIZOR_NYCTIS_ENABLED is off unless a build turns it on', () {
    expect(kNyctisFeatureEnabledEnvKey, 'VIZOR_NYCTIS_ENABLED');
    expect(
      kNyctisFeatureAvailable,
      const bool.fromEnvironment('VIZOR_NYCTIS_ENABLED'),
    );
  });

  test('the feature provider reports the build-time switch', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(nyctisFeatureEnabledProvider),
      kNyctisFeatureAvailable,
    );
  });

  test('Nyctis routes are registered only when the switch is on', () {
    final nyctisPaths = _paths(
      buildMobileRoutes(entryRoutes: const []),
    ).where(_isNyctisPath).toSet();

    if (kNyctisFeatureAvailable) {
      expect(
        nyctisPaths,
        containsAll({
          '/nyctis',
          '/settings/nyctis',
          nyctisActivityDetailRoutePattern,
        }),
      );
    } else {
      expect(nyctisPaths, isEmpty);
    }
  });
}
