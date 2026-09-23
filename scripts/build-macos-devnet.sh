#!/usr/bin/env bash
# Build the Nyctis devnet wallet for local macOS, with a signing configuration
# that does not change between builds.
#
# WHY THIS SCRIPT EXISTS. macOS ties a keychain item to the identity of the app
# that wrote it. Every one of these knobs is part of that identity, and changing
# any of them between builds makes the wallet's own password verifier
# unreadable — which surfaces as a correct password being rejected, with no
# mention of the keychain anywhere. That happened twice, once from ad-hoc
# signing (whose signature is derived from the binary, so it changes on every
# build) and once from adding `--options=runtime` to one build and not the next.
#
# So: do not edit these flags to fix something else. If they must change, expect
# to recreate the devnet wallet, and say so before doing it.
#
# Prerequisites: the Nyctis devnet running (infra/README.md), including the
# lightwalletd on 19067 the wallet syncs through, the indexer on 8787, and a
# signing identity in the login keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=${VIZOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}
[ -n "$IDENTITY" ] || { echo "no Apple Development identity in the login keychain" >&2; exit 1; }
echo "signing as: $IDENTITY"

ENTITLEMENTS="$PWD/macos/Runner/LocalDev.entitlements"
DERIVED=${VIZOR_DERIVED_DATA:-$PWD/build/macos-adhoc}

# The Nyctis channel the build is pointed at. A channel is born from a wallet's `uivk`, so every
# devnet rebuild makes a new one — and `channel_id` feeds `collection_id` and so `asset_id`, so the
# assets change with it. Read it from the live devnet wallet when it is there, and otherwise leave
# the defines empty so the compiled-in defaults stand.
# The Nyctis repository sits beside this one (../nyctis relative to the
# wallet root); set NYCTIS_REPO to point elsewhere.
NY_REPO=${NYCTIS_REPO:-$PWD/../nyctis}
NY_BIN="$NY_REPO/target/release/nyctis"
#
# An *empty* define is not the same as an absent one — it would override the compiled-in default
# with the empty string and leave the wallet with no channel at all, so the pair is only added
# when both values are actually there.
CH_UIVK=${NYCTIS_CHANNEL_UIVK:-}
CH_ADDR=${NYCTIS_CHANNEL_ADDRESS:-}
if [ -z "$CH_UIVK" ] && [ -x "$NY_BIN" ] && [ -d "$NY_REPO/.devnet/channel" ]; then
  CH_UIVK=$("$NY_BIN" wallet --dir "$NY_REPO/.devnet/channel" uivk 2>/dev/null | tail -1)
  CH_ADDR=$("$NY_BIN" wallet --dir "$NY_REPO/.devnet/channel" address 2>/dev/null | tail -1)
fi
CHANNEL_DEFINES=()
if [ -n "$CH_UIVK" ] && [ -n "$CH_ADDR" ]; then
  CHANNEL_DEFINES=(
    "--dart-define=NYCTIS_REGTEST_CHANNEL_UIVK=$CH_UIVK"
    "--dart-define=NYCTIS_REGTEST_CHANNEL_ADDRESS=$CH_ADDR"
  )
  echo "nyctis channel: ${CH_UIVK:0:28}..."
else
  echo "nyctis channel: using the compiled-in default (no live devnet found)"
fi

# The verifying-key pin: the hash every proof's key must have, whatever the indexer says. A new
# `zk-setup` makes a new key, so it is read from the live devnet's key manifest (`vk_hash=` on the
# one line of `interpreter-v0.circuit`) the same way the channel is — and, like the channel, only
# passed when there is a value, so an absent devnet leaves the compiled-in default standing.
VK_PIN=${NYCTIS_VK_PIN:-}
NY_CIRCUIT="$NY_REPO/.devnet/keys/interpreter-v0.circuit"
if [ -z "$VK_PIN" ] && [ -f "$NY_CIRCUIT" ]; then
  VK_PIN=$(sed -n 's/.*vk_hash=\([0-9a-fA-F]\{64\}\).*/\1/p' "$NY_CIRCUIT" | head -1)
fi
if [ -n "$VK_PIN" ]; then
  CHANNEL_DEFINES+=("--dart-define=NYCTIS_REGTEST_VK_PIN=$VK_PIN")
  echo "nyctis vk pin: $VK_PIN"
else
  echo "nyctis vk pin: using the compiled-in default (no devnet key manifest found)"
fi

# `ZCASH_E2E_LIGHTWALLETD_URL` below MUST be lightwalletd (19067), not Zaino (28137).
# The devnet runs both against the same Zebra. Zaino 0.6.0's `ShieldedProtocol` enum stops at
# Orchard, so `GetSubtreeRoots` for Ironwood answers `invalid_argument` and a fresh wallet's sync
# dies at about 5 % — reported as a bare "syncing failed" that names no protocol and no server, so
# it reads like a wallet bug. This default was 28137 and cost two diagnoses. Override with
# VIZOR_DEVNET_LWD if you need a different reader.
fvm flutter build macos --config-only --debug \
  --dart-define=ZCASH_DEFAULT_NETWORK=regtest \
  --dart-define=ZCASH_REGTEST_IRONWOOD_ACTIVATION_HEIGHT=2 \
  --dart-define=VIZOR_FORM_FACTOR=desktop \
  --dart-define=VIZOR_NYCTIS_ENABLED=true \
  --dart-define=VIZOR_LOCAL_UNSIGNED_MACOS_KEYCHAIN=true \
  --dart-define=ZCASH_E2E_LIGHTWALLETD_URL=${VIZOR_DEVNET_LWD:-http://127.0.0.1:19067} \
  "${CHANNEL_DEFINES[@]}"

cd macos
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  build

APP="$DERIVED/Build/Products/Debug/Vizor.app"
echo
echo "built $APP"
# Print the two things that must stay the same across builds, so a change is
# visible here rather than as a rejected password an hour later.
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Identifier=|TeamIdentifier=|flags='
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /designated: /p'
