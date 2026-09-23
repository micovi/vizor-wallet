import 'dart:io';

import 'package:flutter/material.dart';
import 'package:zcash_wallet/figma_compare/figma_compare_configuration.dart';
import 'package:zcash_wallet/figma_compare/nyctis_use_cases.dart';
import 'package:zcash_wallet/src/core/layout/app_form_factor.dart';

import 'figma_compare_capture_support.dart';

/// Captures every `nyctis-*` scenario the compiled form factor supports, in
/// both themes, as `<id>__<form factor>__<theme>.png` under
/// `NYCTIS_CAPTURE_DIR`.
///
/// One `flutter test` run per form factor rather than one per image: the
/// compile is most of the cost of a capture, and there are a hundred-odd.
/// `NYCTIS_CAPTURE_FILTER` narrows the run to ids containing it.
///
/// With `NYCTIS_CAPTURE_FULL=true` each state is also captured on a tall
/// viewport into `full/`, so a reviewer sees the whole screen and not only
/// what fits above the fold. Screens shorter than it end in empty space.
///
/// A layout overflow does not stop the image from being written: the striped
/// overflow marker in the PNG is exactly what a reviewer needs to see. It is
/// logged, and appended to `layout-warnings.txt` beside the images, instead of
/// failing the capture. Any other exception still fails it.
void runNyctisCaptures(AppFormFactor formFactor) {
  const output = String.fromEnvironment('NYCTIS_CAPTURE_DIR');
  const filter = String.fromEnvironment('NYCTIS_CAPTURE_FILTER');
  const full = bool.fromEnvironment('NYCTIS_CAPTURE_FULL');
  if (output.isEmpty) return;

  final mobile = formFactor == AppFormFactor.mobile;
  final pixelRatio = mobile ? 3.0 : 1.0;
  final sizes = <String, Size>{
    '': mobile ? const Size(393, 852) : const Size(1080, 720),
    if (full) 'full/': mobile ? const Size(393, 1900) : const Size(1080, 1700),
  };

  for (final scenario in nyctisFigmaCompareScenarios) {
    if (mobile ? !scenario.mobile : !scenario.desktop) continue;
    if (filter.isNotEmpty && !scenario.id.contains(filter)) continue;
    for (final MapEntry(key: folder, value: size) in sizes.entries) {
      for (final theme in const [ThemeMode.dark, ThemeMode.light]) {
        runFigmaCompareCaptureTest(
          expectedFormFactor: formFactor,
          defaultLogicalSize: size,
          defaultPixelRatio: pixelRatio,
          overrideConfiguration: FigmaCompareConfiguration(
            scenarioId: scenario.id,
            themeMode: theme,
            outputPath:
                '$output/$folder'
                '${scenario.id}__${formFactor.name}__${theme.name}.png',
            logicalSize: size,
            pixelRatio: pixelRatio,
          ),
          beforeCapture: (tester) async {
            final error = tester.takeException();
            if (error == null) return;
            final text = '$error';
            // Several overflowing tiles arrive as one "Multiple exceptions"
            // summary; each is printed in full to the console above it.
            if (!text.contains('overflowed') &&
                !text.contains('Multiple exceptions')) {
              throw error;
            }
            final line =
                '$folder${scenario.id} ${formFactor.name} ${theme.name}: '
                '${text.split('\n').first}';
            debugPrint('NYCTIS LAYOUT WARNING $line');
            File(
              '$output/layout-warnings.txt',
            ).writeAsStringSync('$line\n', mode: FileMode.append);
          },
        );
      }
    }
  }
}
