<#
.SYNOPSIS
  Build Computer Use Turbo on Windows: the helper (Rust) and the MCP server (Node.js).

.DESCRIPTION
  1. helpers\windows-linux  ->  helpers\windows-linux\target\release\computer-use-turbo-helper.exe
  2. server\                ->  npm dependencies and a load check
  Nothing is installed or registered: see scripts\install.ps1 and scripts\mcp-config.ps1.
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Require($cmd, $hint) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "'$cmd' not found. $hint" }
}
Require cargo 'Install Rust from https://rustup.rs (the MSVC toolchain).'
Require node 'Install Node.js 20 or newer.'
Require npm 'Install npm (ships with Node.js).'
$major = [int](node -p 'process.versions.node.split(".")[0]')
if ($major -lt 20) { throw "Node.js $major is too old; 20+ is required." }

Write-Host "==> Helper (windows)" -ForegroundColor Cyan
Push-Location (Join-Path $Root 'helpers\windows-linux')
try { cargo build --release; if ($LASTEXITCODE) { throw 'cargo build failed' } } finally { Pop-Location }
$Helper = Join-Path $Root 'helpers\windows-linux\target\release\computer-use-turbo-helper.exe'
if (-not (Test-Path $Helper)) { throw "the helper build did not produce $Helper" }

Write-Host "==> MCP server" -ForegroundColor Cyan
Push-Location (Join-Path $Root 'server')
try { npm ci --omit=dev --no-audit --no-fund; if ($LASTEXITCODE) { throw 'npm ci failed' } } finally { Pop-Location }
node --check (Join-Path $Root 'server\src\server.mjs')

Write-Host "`nBuild OK" -ForegroundColor Green
Write-Host "  helper: $Helper"
Write-Host "  server: $(Join-Path $Root 'server\src\server.mjs')"
Write-Host "`nNext: scripts\install.ps1, then add the server to your agent (scripts\mcp-config.ps1)."
