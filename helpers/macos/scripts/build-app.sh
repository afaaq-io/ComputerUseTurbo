#!/usr/bin/env bash
# Build Computer Use Turbo.app.
#
#   swift build -c release → build/Computer Use Turbo.app (Contents/MacOS + Resources incl.
#   policy) → codesign (hardened runtime) → codesign --verify --deep --strict.
#
# Signing identity: $CUT_SIGN_IDENTITY, else the first "Apple Development:" identity from
# `security find-identity -v -p codesigning`, else ad-hoc ("-") with a warning (TCC grants
# then reset on every rebuild because the code signature changes).
set -euo pipefail

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$HELPER_DIR/build"
APP="$BUILD_DIR/Computer Use Turbo.app"

cd "$HELPER_DIR"

echo "==> swift build -c release"
swift build -c release --product TurboHelper
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/TurboHelper"
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TurboHelper"
cp "$HELPER_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Shared data: the safety policy and the UI colours (one file each for every helper).
cp "$HELPER_DIR/../../shared/policy.json" "$HELPER_DIR/../../shared/design-tokens.json" "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Pick a signing identity.
IDENTITY="${CUT_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # Use the SHA-1 hash of the first Apple Development identity (unambiguous even if
  # several certificates share a name).
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development:/ { print $2; exit }')"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "warning: no 'Apple Development:' signing identity found; signing ad-hoc." >&2
  echo "warning: TCC grants (Accessibility / Screen Recording) will reset on every rebuild." >&2
elif [[ "$IDENTITY" == "-" ]]; then
  echo "warning: ad-hoc signing requested; TCC grants will reset on every rebuild." >&2
fi

echo "==> codesign (identity: ${IDENTITY})"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"

echo "==> verify"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|TeamIdentifier|Runtime Version)=' || true
"$APP/Contents/MacOS/TurboHelper" --version

echo "==> built $APP"
