@Tags(['figma-capture'])
library;

import 'package:flutter_test/flutter_test.dart' show Tags;
import 'package:zcash_wallet/src/core/layout/app_form_factor.dart';

import 'nyctis_capture_support.dart';

/// Run through `scripts/nyctis-screenshots.sh`, which passes
/// `NYCTIS_CAPTURE_DIR` (outside the repository) and `--update-goldens`.
void main() => runNyctisCaptures(AppFormFactor.desktop);
