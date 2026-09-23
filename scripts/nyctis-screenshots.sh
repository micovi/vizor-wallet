#!/usr/bin/env bash
# Renders every `nyctis-*` Figma-comparison scenario to PNG.
#
# Each scenario is captured in the dark and light themes, on the desktop
# (1080x720 @1x) and mobile (393x852 @3x) widget-test viewports, and copied to
#
#   <out-dir>/<scenario>__<desktop|mobile>__<dark|light>.png
#
# A second, tall capture of every state goes to <out-dir>/full/ under the same
# names (desktop 1080x1700, mobile 393x1900), so a reviewer sees the whole
# screen and not only what fits above the fold. `*-large-text` scenarios are
# mobile only and render at 1.8x text. A layout overflow is captured rather
# than fatal (the striped marker is the finding) and listed in
# <out-dir>/layout-warnings.txt.
#
# The scenarios live in lib/figma_compare/nyctis_use_cases.dart and use
# fixtures only: no Rust, storage or network. The work is two `flutter test`
# runs (one per form factor, the define decides the token set), so the compile
# dominates and a full run takes well under two minutes.
#
# Usage:
#   scripts/nyctis-screenshots.sh <out-dir> [--filter <substring>]
#                                   [--no-full] [--desktop-only | --mobile-only]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fail() {
  echo "fail: $*" >&2
  exit 2
}

OUT_DIR=""
FILTER=""
FULL="true"
RUN_DESKTOP="true"
RUN_MOBILE="true"

while (($# > 0)); do
  case "$1" in
    --filter)
      [[ -n "${2:-}" ]] || fail "missing value for --filter"
      FILTER="$2"
      shift 2
      ;;
    --no-full) FULL="false"; shift ;;
    --desktop-only) RUN_MOBILE="false"; shift ;;
    --mobile-only) RUN_DESKTOP="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) fail "unknown option $1" ;;
    *)
      [[ -z "$OUT_DIR" ]] || fail "unexpected argument $1"
      OUT_DIR="$1"
      shift
      ;;
  esac
done

[[ -n "$OUT_DIR" ]] || { usage >&2; exit 2; }
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
case "$OUT_DIR/" in
  "$ROOT_DIR"/*) fail "write captures outside the repository, not into $OUT_DIR" ;;
esac

# Only this script's own files are cleared, so a scenario that was renamed or
# removed does not leave a stale image behind.
find "$OUT_DIR" -maxdepth 2 -type f -name 'nyctis-*__*__*.png' -delete
: > "$OUT_DIR/layout-warnings.txt"

DEFINES=(
  "--dart-define=NYCTIS_CAPTURE_DIR=$OUT_DIR"
  "--dart-define=NYCTIS_CAPTURE_FULL=$FULL"
)
[[ -z "$FILTER" ]] || DEFINES+=("--dart-define=NYCTIS_CAPTURE_FILTER=$FILTER")

cd "$ROOT_DIR"
START=$SECONDS
STATUS=0

if [[ "$RUN_DESKTOP" == "true" ]]; then
  echo "== desktop captures"
  fvm flutter test --no-pub --update-goldens \
    --tags figma-capture --run-skipped \
    "${DEFINES[@]}" \
    test/figma_compare/nyctis_capture_desktop_test.dart || STATUS=$?
fi

if [[ "$RUN_MOBILE" == "true" ]]; then
  echo "== mobile captures"
  fvm flutter test --no-pub --update-goldens \
    --tags figma-capture --run-skipped \
    --dart-define=VIZOR_FORM_FACTOR=mobile \
    "${DEFINES[@]}" \
    test/figma_compare/nyctis_capture_mobile_test.dart || STATUS=$?
fi

COUNT=$(find "$OUT_DIR" -maxdepth 1 -type f -name 'nyctis-*__*__*.png' | wc -l | tr -d ' ')
FULL_COUNT=0
if [[ -d "$OUT_DIR/full" ]]; then
  FULL_COUNT=$(find "$OUT_DIR/full" -maxdepth 1 -type f -name 'nyctis-*__*__*.png' | wc -l | tr -d ' ')
fi
if [[ -s "$OUT_DIR/layout-warnings.txt" ]]; then
  echo "warning: layout overflows were captured (see layout-warnings.txt):"
  sort -u "$OUT_DIR/layout-warnings.txt" | sed 's/^/  /'
else
  rm -f "$OUT_DIR/layout-warnings.txt"
fi
echo "ok: $COUNT viewport + $FULL_COUNT full-height PNGs in $OUT_DIR ($((SECONDS - START))s)"
if [[ "$STATUS" != "0" ]]; then
  echo "fail: at least one capture failed; see the test output above" >&2
fi
exit "$STATUS"
