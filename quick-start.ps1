# PowerShell entry point for the Swarm Statechecker deployment.
#
# The Bash quick-start is the single authoritative menu and deployment
# implementation. Delegating keeps PowerShell and Linux behavior identical.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$bashCommand = Get-Command bash -ErrorAction SilentlyContinue

if ($null -eq $bashCommand) {
    Write-Error "Bash is required. Run ./quick-start.sh on the Docker Swarm manager or install WSL/Bash."
    exit 1
}

$exitCode = 1
Push-Location $scriptDirectory
try {
    & $bashCommand.Source "./quick-start.sh" @args
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}

exit $exitCode
