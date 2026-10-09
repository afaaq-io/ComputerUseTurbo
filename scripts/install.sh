#!/usr/bin/env bash
#
# install.sh — install the helper at its stable per-user location.
#
#   macOS: helpers/macos/build/Computer Use Turbo.app  →  ~/Applications/Computer Use Turbo.app
#   Linux: helpers/windows-linux/target/release/computer-use-turbo-helper  →  ~/.local/bin/
#   (Windows: scripts/install.ps1)
#
# * Quits a running helper first (SIGTERM, then SIGKILL after 5 s).
# * Copies with `ditto --noqtn` so the bundle carries no quarantine attribute.
# * Verifies the code signature and explains how to grant Accessibility and
#   Screen Recording. macOS ties those grants to the app's signature, which is why
#   the helper lives at one stable path and should always be signed with the same
#   identity (see README "Troubleshooting").
#
# This script never touches System Settings, TCC or sudo: granting permissions is
# always done by you, in System Settings.
#
# Usage: scripts/install.sh [--dry-run] [--help]
#   --dry-run   print what would happen without changing anything
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/helpers/macos/build/Computer Use Turbo.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/Computer Use Turbo.app"
HELPER_BUNDLE_ID="dev.cuturbo.helper"
# Matches only the helper's main executable, not shells/editors mentioning the name.
HELPER_PROC_PATTERN="Computer Use Turbo.app/Contents/MacOS/TurboHelper"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown argument: %s (try --help)\n' "$arg" >&2; exit 64 ;;
  esac
done

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; BLUE=$'\033[1;34m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; RESET=$'\033[0m'
else
  BOLD=""; BLUE=""; YELLOW=""; RED=""; GREEN=""; RESET=""
fi
log()  { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
run()  {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# 1. Check the build
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" == "Linux" ]]; then
  # Linux: one binary in ~/.local/bin, with the policy file next to it.
  LSRC="$ROOT/helpers/windows-linux/target/release/computer-use-turbo-helper"
  [[ -x "$LSRC" ]] || die "No helper build at $LSRC — run scripts/build.sh first."
  # By path, not -x: Linux matches -x against the first 15 characters of the name only.
  run pkill -TERM -f '(^|/)computer-use-turbo-helper( |$)' || true
  run mkdir -p "$HOME/.local/bin"
  run install -m 0755 "$LSRC" "$HOME/.local/bin/computer-use-turbo-helper"
  run install -m 0644 "$ROOT/shared/policy.json" "$HOME/.local/bin/policy.json"
  printf '\n%sInstalled%s %s\n\n' "$GREEN" "$RESET" "$HOME/.local/bin/computer-use-turbo-helper"
  # Wayland: the desktop asks once to share the screen. Ask now, during setup, so no task
  # is ever interrupted by the prompt (the approval is remembered).
  if [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    printf '%sScreen sharing (once)%s\n' "$BOLD" "$RESET"
    "$HOME/.local/bin/computer-use-turbo-helper" --share-screen || warn "Screen sharing is not set up; run again: ~/.local/bin/computer-use-turbo-helper --share-screen"
    printf '\n'
  fi
  printf '%sNext steps%s\n\n' "$BOLD" "$RESET"
  printf '1. Accessibility must be on for your desktop session (GNOME: Settings > Accessibility, or\n'
  printf '   gsettings set org.gnome.desktop.interface toolkit-accessibility true). The helper reads\n'
  printf '   apps through AT-SPI and types and captures through X11 or, on Wayland, the screen share\n'
  printf '   approved above.\n\n'
  printf '2. Add the MCP server to your agent:\n       scripts/mcp-config.sh\n'
  exit 0
fi
[[ "$(uname -s)" == "Darwin" ]] || die "Unsupported system; on Windows use scripts\\install.ps1."
[[ -d "$SRC" ]] || die "No helper build at $SRC — run scripts/build.sh first."
[[ -x "$SRC/Contents/MacOS/TurboHelper" ]] || die "$SRC is incomplete (no Contents/MacOS/TurboHelper)."
src_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist" 2>/dev/null || true)"
[[ "$src_id" == "$HELPER_BUNDLE_ID" ]] || die "unexpected bundle id '$src_id' in $SRC (expected $HELPER_BUNDLE_ID)."
codesign --verify --strict "$SRC" 2>/dev/null || die "$SRC has an invalid code signature — rebuild it with scripts/build.sh."

# ---------------------------------------------------------------------------
# 2. Quit a running helper
# ---------------------------------------------------------------------------
if pgrep -f "$HELPER_PROC_PATTERN" >/dev/null 2>&1; then
  log "Quitting the running helper (pid $(pgrep -f "$HELPER_PROC_PATTERN" | tr '\n' ' '))"
  run pkill -TERM -f "$HELPER_PROC_PATTERN" || true
  if [[ $DRY_RUN -eq 0 ]]; then
    for _ in $(seq 1 50); do
      pgrep -f "$HELPER_PROC_PATTERN" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if pgrep -f "$HELPER_PROC_PATTERN" >/dev/null 2>&1; then
      warn "helper did not exit after 5 s; sending SIGKILL"
      pkill -KILL -f "$HELPER_PROC_PATTERN" || true
      sleep 0.5
    fi
  fi
else
  log "No running helper"
fi

# ---------------------------------------------------------------------------
# 3. Copy
# ---------------------------------------------------------------------------
log "Installing $DEST"
run mkdir -p "$DEST_DIR"
if [[ -e "$DEST" ]]; then
  run rm -rf "$DEST"
fi
run ditto --noqtn "$SRC" "$DEST"

# ---------------------------------------------------------------------------
# 4. Verify the installed copy
# ---------------------------------------------------------------------------
signed_by="unknown"
check_path="$DEST"
[[ $DRY_RUN -eq 1 ]] && check_path="$SRC"
if codesign --verify --strict "$check_path" 2>/dev/null; then
  details="$(codesign -dv --verbose=2 "$check_path" 2>&1 || true)"
  if grep -q 'Signature=adhoc' <<<"$details"; then
    signed_by="ad-hoc"
    warn "The helper is ad-hoc signed. macOS will forget its Accessibility / Screen Recording"
    warn "grants every time you rebuild. Install an 'Apple Development' certificate (Xcode ▸"
    warn "Settings ▸ Accounts) or set CUT_SIGN_IDENTITY, then rebuild, to keep grants stable."
  else
    signed_by="$(grep -m1 '^Authority=' <<<"$details" | cut -d= -f2-)"
  fi
else
  [[ $DRY_RUN -eq 1 ]] || die "installed copy at $DEST failed signature verification."
fi
if [[ $DRY_RUN -eq 0 ]]; then
  xattr -p com.apple.quarantine "$DEST" >/dev/null 2>&1 && warn "$DEST still carries a quarantine attribute."
fi

if [[ $DRY_RUN -eq 1 ]]; then
  printf '\n%sDry run complete%s — nothing was changed.\n' "$GREEN" "$RESET"
  exit 0
fi

printf '\n%sInstalled%s %s\n  signed by: %s\n' "$GREEN" "$RESET" "$DEST" "$signed_by"

# ---------------------------------------------------------------------------
# 5. Next steps (manual — this script never changes privacy settings)
# ---------------------------------------------------------------------------
cat <<EOF

${BOLD}Next steps${RESET}

1. Allow the helper (you must do this yourself):

   System Settings ▸ Privacy & Security ▸ Accessibility
       click "+", choose ~/Applications/Computer Use Turbo.app, and switch it on.

   System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording
       add Computer Use Turbo the same way and switch it on. Without it, observe_app
       still works but has no screenshot.

   Shortcuts to open those panes:
       open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
       open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

   After granting screen recording, quit the helper so it restarts with the grant:
       pkill -f "$HELPER_PROC_PATTERN"

2. Add the MCP server to your agent:
       scripts/mcp-config.sh
EOF
