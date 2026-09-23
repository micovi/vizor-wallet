import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/figma_compare/figma_compare_scenarios.dart';
import 'package:zcash_wallet/figma_compare/nyctis_use_cases.dart';

void main() {
  final ids = nyctisFigmaCompareScenarios.map((s) => s.id).toList();

  test('every Nyctis scenario is registered and namespaced', () {
    expect(ids, isNotEmpty);
    expect(ids.toSet(), hasLength(ids.length));
    for (final id in ids) {
      expect(id, startsWith('nyctis-'));
      expect(findFigmaCompareScenario(id), isNotNull, reason: id);
    }
    // Nothing outside the Nyctis file claims the prefix, so the screenshot
    // script's glob and this registry cannot disagree.
    expect(
      figmaCompareScenarios
          .where((s) => s.id.startsWith('nyctis-'))
          .map((s) => s.id),
      unorderedEquals(ids),
    );
  });

  test('the screens a review needs are all covered', () {
    expect(
      ids,
      containsAll(<String>[
        'nyctis-assets',
        'nyctis-assets-empty',
        'nyctis-assets-loading',
        'nyctis-assets-unreachable',
        'nyctis-asset-public',
        'nyctis-asset-public-accepted',
        'nyctis-asset-private',
        'nyctis-collection-capped',
        'nyctis-collection-uncapped',
        'nyctis-collection-not-accepted',
        'nyctis-collection-artwork-pending',
        'nyctis-collection-artwork-failed',
        'nyctis-collection-item',
        'nyctis-receive',
        'nyctis-send-empty',
        'nyctis-send-filled',
        'nyctis-send-over-balance',
        'nyctis-send-review',
        'nyctis-send-status-sending',
        'nyctis-send-status-sent',
        'nyctis-send-status-failed',
        'nyctis-activity',
        'nyctis-activity-detail-sent',
        'nyctis-activity-detail-received',
        'nyctis-settings',
      ]),
    );
  });

  test('large-text scenarios are mobile only; the rest render on both', () {
    for (final scenario in nyctisFigmaCompareScenarios) {
      if (scenario.id.endsWith('-large-text')) {
        expect(scenario.desktop, isFalse, reason: scenario.id);
        expect(scenario.mobile, isTrue, reason: scenario.id);
      } else {
        expect(scenario.desktop, isTrue, reason: scenario.id);
        expect(scenario.mobile, isTrue, reason: scenario.id);
      }
    }
  });
}
