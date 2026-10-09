<#
.SYNOPSIS
  Install the Computer Use Turbo helper for the current user on Windows.

.DESCRIPTION
  helpers\windows-linux\target\release\computer-use-turbo-helper.exe
    -> %LOCALAPPDATA%\Programs\ComputerUseTurbo\computer-use-turbo-helper.exe (plus policy.json)
  Stops a running helper first. Needs no administrator rights and changes no settings.
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Src = Join-Path $Root 'helpers\windows-linux\target\release\computer-use-turbo-helper.exe'
$Dest = Join-Path $env:LOCALAPPDATA 'Programs\ComputerUseTurbo'

if (-not (Test-Path $Src)) { throw "No helper build at $Src - run scripts\build.ps1 first." }

Get-Process -Name 'computer-use-turbo-helper' -ErrorAction SilentlyContinue | Stop-Process -Force
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Copy-Item $Src (Join-Path $Dest 'computer-use-turbo-helper.exe') -Force
Copy-Item (Join-Path $Root 'shared\policy.json') (Join-Path $Dest 'policy.json') -Force

Write-Host "`nInstalled $Dest\computer-use-turbo-helper.exe" -ForegroundColor Green
Write-Host @"

Next steps

1. Nothing to grant: Windows lets the helper read apps (UI Automation) and capture their
   windows without extra permissions. The first time the agent uses an app, the helper
   asks you in its own dialog.

2. Add the MCP server to your agent:
       scripts\mcp-config.ps1
"@
