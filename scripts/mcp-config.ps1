<#
.SYNOPSIS
  Print the MCP server entry for Computer Use Turbo (Windows).

.DESCRIPTION
  Works with any MCP client: paste the printed entry into the client's MCP server
  configuration, or pass the command and argument to its "add MCP server" command.
  Optional: set CUT_AGENT_NAME in the entry's "env" to choose the name shown in the
  helper's overlay and approval dialog (default: the name the client reports).
#>
$Root = Split-Path -Parent $PSScriptRoot
$Server = Join-Path $Root 'server\src\server.mjs'
$Node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $Node) { $Node = 'node' }
if (-not (Test-Path $Server)) { throw "$Server not found" }

$entry = [ordered]@{ mcpServers = [ordered]@{ 'turbo' = [ordered]@{ command = $Node; args = @($Server) } } }
$entry | ConvertTo-Json -Depth 5
Write-Host "`nCommand line form: `"$Node`" `"$Server`"" -ForegroundColor DarkGray
