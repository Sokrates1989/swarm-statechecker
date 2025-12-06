# quick-start.ps1
# Quick start tool for Swarm Statechecker

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$setupDir = Join-Path $scriptDir "setup"

# Import modules
Import-Module "$setupDir\modules\docker_helpers.ps1" -Force
Import-Module "$setupDir\modules\menu_handlers.ps1" -Force

Write-Host "Swarm Statechecker - Quick Start" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan
Write-Host ""

# Check Docker Swarm availability
if (-not (Test-DockerSwarm)) {
    exit 1
}
Write-Host ""

# Check if .env exists
if (-not (Test-Path .env)) {
    Write-Host "[WARN] .env file not found" -ForegroundColor Yellow
    Write-Host ""
    if (Test-Path setup\.env.template) {
        $createEnv = Read-Host "Create .env from template? (Y/n)"
        if ($createEnv -ne "n" -and $createEnv -ne "N") {
            Copy-Item setup\.env.template .env
            Write-Host "[OK] .env created from template" -ForegroundColor Green
            Write-Host "[WARN] Please edit .env with your configuration before deploying" -ForegroundColor Yellow
            Write-Host ""
        }
    }
}

# Check required secrets
Write-Host "Checking secrets..." -ForegroundColor Yellow
$secretsOk = Test-RequiredSecrets
if (-not $secretsOk) {
    Write-Host ""
    Write-Host "[WARN] Some required secrets are missing" -ForegroundColor Yellow
    $createSecrets = Read-Host "Create them now? (Y/n)"
    if ($createSecrets -ne "n" -and $createSecrets -ne "N") {
        New-RequiredSecretsMenu
    }
}
Test-OptionalSecrets
Write-Host ""

# Show main menu
Show-MainMenu
