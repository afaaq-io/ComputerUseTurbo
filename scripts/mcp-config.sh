#!/usr/bin/env bash
#
# mcp-config.sh — print the MCP server entry for Computer Use Turbo.
#
# Works with any MCP client (desktop agents, IDE agents, CLIs, agent SDKs): paste the
# printed entry into the client's MCP server configuration, or pass the command and
# arguments to its "add MCP server" command. The server talks stdio.
#
# Optional environment for the server (add an "env" object to the entry):
#   CUT_AGENT_NAME   the name shown in the helper's overlay and approval card
#                    (default: the name the MCP client reports for itself)
#
# Usage: scripts/mcp-config.sh [--help]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$ROOT/server/src/server.mjs"
NODE_BIN="$(command -v node || echo node)"

for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,/^set -/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown argument: %s (try --help)\n' "$arg" >&2; exit 64 ;;
  esac
done

[[ -f "$SERVER" ]] || { printf 'error: %s not found\n' "$SERVER" >&2; exit 1; }

cat <<EOF
{
  "mcpServers": {
    "turbo": {
      "command": "$NODE_BIN",
      "args": ["$SERVER"]
    }
  }
}
EOF
printf '\nCommand line form: %s %s\n' "$NODE_BIN" "$SERVER" >&2
