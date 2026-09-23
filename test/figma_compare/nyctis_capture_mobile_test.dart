@Tags(['mobile', 'figma-capture'])
library;

import 'package:flutter_test/flutter_test.dart' show Tags;
import 'package:zcash_wallet/src/core/layout/app_form_factor.dart';

import 'nyctis_capture_support.dart';

/// Run through `scripts/nyctis-screenshots.sh`, which passes
/// `NYCTIS_CAPTURE_DIR` (outside the repository), `--update-goldens` and
/// the mobile form-factor define.
void main() => runNyctisCaptures(AppFormFactor.mobile);
