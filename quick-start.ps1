# quick-start.ps1
# Quick start tool for Swarm Statechecker

param(
    [switch]$SmokeTest
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$setupDir = Join-Path $scriptDir "setup"

Set-Location $scriptDir

# Import modules
Import-Module "$setupDir\modules\docker_helpers.ps1" -Force
Import-Module "$setupDir\modules\ci-cd-github.ps1" -Force
Import-Module "$setupDir\modules\health-check.ps1" -Force
Import-Module "$setupDir\modules\menu_handlers.ps1" -Force

Write-Host "Swarm Statechecker - Quick Start" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan
Write-Host ""

if ($SmokeTest) {
    try {
        $null = docker --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Docker not available" }
    } catch {
        Write-Host "[ERROR] Docker is not available" -ForegroundColor Red
        exit 1
    }

    try {
        if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
            $null = docker-compose --version 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Docker Compose not available" }
        } else {
            $null = docker compose version 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Docker Compose not available" }
        }
    } catch {
        Write-Host "[ERROR] Docker Compose is not available" -ForegroundColor Red
        exit 1
    }

    Write-Host "[OK] Smoke test completed (module imports + Docker/Compose availability)." -ForegroundColor Green
    exit 0
}

# Offer wizard-driven setup (recommended)
if (-not (Test-Path ".setup-complete")) {
    Write-Host "[WARN] Setup wizard has not been completed (.setup-complete missing)" -ForegroundColor Yellow
    $wizardPath = Join-Path $setupDir "setup-wizard.ps1"
    if (Test-Path $wizardPath) {
        $runWizard = Read-Host "Run setup wizard now? (Y/n)"
        if ($runWizard -ne "n" -and $runWizard -ne "N") {
            & $wizardPath
            Write-Host ""
        }
    }
}

# Check Docker Swarm availability
if (-not (Test-DockerSwarm)) {
    exit 1
}
Write-Host ""

# Check Docker Compose
try {
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        $null = docker-compose --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Docker Compose not available" }
    } else {
        $null = docker compose version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Docker Compose not available" }
    }
} catch {
    Write-Host "[ERROR] Docker Compose is not available!" -ForegroundColor Red
    Write-Host "Please install a current Docker version with Compose plugin" -ForegroundColor Yellow
    exit 1
}
Write-Host "Docker Compose is available" -ForegroundColor Green
Write-Host ""

# Check if .env exists
if (-not (Test-Path .env)) {
    Write-Host "[WARN] .env file not found" -ForegroundColor Yellow
    Write-Host ""
    if (Test-Path setup\.env.template) {
        $createEnv = Read-Host "Create .env from template? (Y/n)"
        if ($createEnv -ne "n" -and $createEnv -ne "N") {
            Copy-Item setup\.env.template .env
            $envContent = Get-Content .env -ErrorAction SilentlyContinue
            $hasTraefikNetwork = $false
            foreach ($line in $envContent) {
                if ($line -match '^TRAEFIK_NETWORK_NAME=') { $hasTraefikNetwork = $true; break }
            }
            if (-not $hasTraefikNetwork) {
                $preferred = @('traefik-public','traefik_public','traefik')
                $networks = @()
                try {
                    $networks = & docker network ls --filter driver=overlay --format "{{.Name}}" 2>$null
                    if ($LASTEXITCODE -ne 0) { $networks = @() }
                } catch { $networks = @() }
                $networks = @($networks | ForEach-Object { $_.ToString().Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                foreach ($p in $preferred) {
                    if ($networks -contains $p) {
                        Update-EnvValue -EnvFile ".env" -Key "TRAEFIK_NETWORK_NAME" -Value $p | Out-Null
                        Write-Host "[OK] Auto-detected common Traefik network: $p (saved to .env)" -ForegroundColor Green
                        break
                    }
                }
            }
            Write-Host "[OK] .env created from template" -ForegroundColor Green
            Write-Host "[WARN] Please edit .env with your configuration before deploying" -ForegroundColor Yellow
            Write-Host ""

            $editor = $env:EDITOR
            if ([string]::IsNullOrWhiteSpace($editor)) { $editor = "notepad" }
            $openNow = Read-Host "Open .env now in $editor? (Y/n)"
            if ($openNow -notmatch "^[Nn]$") {
                & $editor ".env"
            }
        }
    }
}

# Check required secrets
Write-Host "Checking secrets..." -ForegroundColor Yellow
$secretsOk = Test-RequiredSecrets
if (-not $secretsOk) {
    Write-Host ""
    Write-Host "[WARN] Some required secrets are missing" -ForegroundColor Yellow
    Write-Host "How do you want to create secrets?" -ForegroundColor Yellow
    Write-Host "1) Create from secrets.env file" -ForegroundColor Gray
    Write-Host "2) Create interactively" -ForegroundColor Gray
    Write-Host ""
    $mode = Read-Host "Your choice (1-2) [2]"
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = "2" }
    if ($mode -eq "1") {
        New-SecretsFromFile -SecretsFile "secrets.env" -TemplateFile "setup\secrets.env.template" | Out-Null
    } else {
        New-RequiredSecretsMenu
    }
}
Test-OptionalSecrets
Write-Host ""

# Show main menu
Show-MainMenu
