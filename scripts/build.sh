#!/usr/bin/env bash
#
# build.sh — build Computer Use Turbo for this machine.
#
#   1. the platform helper   macOS: helpers/macos → helpers/macos/build/Computer Use Turbo.app
#                            Linux: helpers/windows-linux → target/release/computer-use-turbo-helper
#                            (Windows: scripts/build.ps1)
#   2. the MCP server        server/ (npm dependencies + a load check)
#
# Nothing is installed or registered: see scripts/install.sh and scripts/mcp-config.sh.
#
# Usage: scripts/build.sh [--help]
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,/^set -/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown argument: %s (try --help)\n' "$arg" >&2; exit 64 ;;
  esac
done

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; CYAN=$'\033[1;36m'; GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; RESET=$'\033[0m'
else
  BOLD=""; CYAN=""; GREEN=""; RED=""; RESET=""
fi
step() { printf '\n%s==> %s%s\n' "$CYAN" "$1" "$RESET"; }
die() { printf '%sERROR:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"; }

case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux) PLATFORM=linux ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *) die "unsupported platform $(uname -s)" ;;
esac
printf '%sComputer Use Turbo — build%s (%s, %s)\n' "$BOLD" "$RESET" "$PLATFORM" "$ROOT"

require_cmd node "Install Node.js 20 or newer."
require_cmd npm "Install npm (ships with Node.js)."
node_major="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$node_major" -ge 20 ]] || die "Node.js $node_major is too old; 20+ is required."

step "Helper ($PLATFORM)"
case "$PLATFORM" in
  macos)
    require_cmd swift "Install Xcode or the Command Line Tools."
    bash "$ROOT/helpers/macos/scripts/build-app.sh"
    HELPER="$ROOT/helpers/macos/build/Computer Use Turbo.app"
    [[ -d "$HELPER" ]] || die "the helper build did not produce $HELPER"
    ;;
  linux)
    require_cmd cargo "Install Rust (https://rustup.rs)."
    (cd "$ROOT/helpers/windows-linux" && cargo build --release)
    HELPER="$ROOT/helpers/windows-linux/target/release/computer-use-turbo-helper"
    [[ -x "$HELPER" ]] || die "the helper build did not produce $HELPER"
    ;;
  windows)
    die "On Windows use scripts\\build.ps1 (PowerShell)."
    ;;
esac

step "MCP server"
if [[ -f "$ROOT/server/package-lock.json" ]]; then
  (cd "$ROOT/server" && npm ci --omit=dev --no-audit --no-fund)
else
  (cd "$ROOT/server" && npm install --omit=dev --no-audit --no-fund)
fi
node --check "$ROOT/server/src/server.mjs"

printf '\n%sBuild OK%s\n  helper: %s\n  server: %s\n' "$GREEN" "$RESET" "$HELPER" "$ROOT/server/src/server.mjs"
printf '\nNext: scripts/install.sh, then add the server to your agent (scripts/mcp-config.sh).\n'
