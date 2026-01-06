# setup-wizard.ps1
# ------------------------------------------------------------------------------
# Swarm Statechecker - Setup Wizard
# ------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
Set-Location $ProjectRoot

Import-Module "$ScriptDir\modules\docker_helpers.ps1" -Force
Import-Module "$ScriptDir\modules\menu_handlers.ps1" -Force
Import-Module "$ScriptDir\modules\data-dirs.ps1" -Force

function Test-SetupComplete {
    <#
    .SYNOPSIS
    Checks whether setup appears to be complete.

    .OUTPUTS
    System.Boolean
    #>
    if (Test-Path "$ProjectRoot\.setup-complete") { return $true }
    if (Test-Path "$ProjectRoot\.env") { return $true }
    return $false
}

function New-EnvFileIfMissing {
    <#
    .SYNOPSIS
    Ensures a .env exists in the project root.

    .OUTPUTS
    System.Boolean
    #>
    if (Test-Path "$ProjectRoot\.env") { return $true }

    $template = Join-Path $ScriptDir ".env.template"
    if (-not (Test-Path $template)) {
        Write-Host "[ERROR] Missing env template: $template" -ForegroundColor Red
        return $false
    }

    Copy-Item $template "$ProjectRoot\.env" -Force
    Write-Host "[OK] Created .env from template" -ForegroundColor Green
    return $true
}

function Get-CurrentEnvValues {
    param([string]$EnvFile)
    $content = Get-Content $EnvFile -ErrorAction SilentlyContinue
    $values = @{}
    
    $keys = @("STACK_NAME", "DATA_ROOT", "PROXY_TYPE", "TRAEFIK_NETWORK_NAME", "API_URL", "WEB_URL", "PHPMYADMIN_URL", "WEB_PORT", "PHPMYADMIN_PORT", "IMAGE_NAME", "IMAGE_VERSION", "WEB_IMAGE_NAME", "WEB_IMAGE_VERSION")
    $defaults = @{
        "STACK_NAME" = "statechecker"
        "DATA_ROOT" = (Get-Location).Path
        "PROXY_TYPE" = "traefik"
        "TRAEFIK_NETWORK_NAME" = "traefik"
        "API_URL" = "api.statechecker.domain.de"
        "WEB_URL" = "statechecker.domain.de"
        "PHPMYADMIN_URL" = "pma.statechecker.domain.de"
        "WEB_PORT" = "8080"
        "PHPMYADMIN_PORT" = "8081"
        "IMAGE_NAME" = "sokrates1989/statechecker"
        "IMAGE_VERSION" = "latest"
        "WEB_IMAGE_NAME" = "sokrates1989/statechecker-web"
        "WEB_IMAGE_VERSION" = "latest"
    }

    foreach ($k in $keys) {
        $line = $content | Select-String "^${k}=" | Select-Object -First 1
        $values[$k] = if ($line) { ($line.Line -split '=', 2)[1].Trim('"') } else { $defaults[$k] }
    }
    return $values
}

function Test-ValidDomain {
    param([string]$Domain)
    $pattern = '^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+\.[A-Za-z]{2,}$'
    return $Domain -match $pattern
}

function Read-DomainWithValidation {
    param([string]$Prompt, [string]$Default, [string]$Example)
    while ($true) {
        $result = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($result)) { $result = $Default }
        if ([string]::IsNullOrWhiteSpace($result)) {
            Write-Host "[WARN] Domain is required for Traefik" -ForegroundColor Yellow
            continue
        }
        if (Test-ValidDomain -Domain $result) {
            return $result
        } else {
            Write-Host "[WARN] Please enter a valid domain like $Example (must contain at least two dots)." -ForegroundColor Yellow
            Write-Host "       If you need to create a new subdomain, configure it in your DNS provider first." -ForegroundColor Gray
        }
    }
}

function Prompt-ProxyConfig {
    param($EnvFile, $ProxyType, $Current)
    if ($ProxyType -eq "none") {
        $webPort = Read-Host "WEB_PORT (localhost) [$($Current['WEB_PORT'])]"
        Update-EnvValue -EnvFile $EnvFile -Key "WEB_PORT" -Value ($webPort -or $Current['WEB_PORT']) | Out-Null

        $pmaPort = Read-Host "PHPMYADMIN_PORT (localhost) [$($Current['PHPMYADMIN_PORT'])]"
        Update-EnvValue -EnvFile $EnvFile -Key "PHPMYADMIN_PORT" -Value ($pmaPort -or $Current['PHPMYADMIN_PORT']) | Out-Null
    } else {
        $traefikNetwork = Select-TraefikNetwork -DefaultNetwork $Current['TRAEFIK_NETWORK_NAME']
        Update-EnvValue -EnvFile $EnvFile -Key "TRAEFIK_NETWORK_NAME" -Value ($traefikNetwork -or $Current['TRAEFIK_NETWORK_NAME']) | Out-Null

        Write-Host ""
        Write-Host "[CONFIG] Domain Configuration for Traefik" -ForegroundColor Cyan
        Write-Host "------------------------------------------" -ForegroundColor Cyan
        Write-Host "Configure the domains for each service. These must be valid FQDNs"
        Write-Host "pointing to your server (e.g., api.statechecker.example.com)."
        Write-Host ""

        $apiUrl = Read-DomainWithValidation -Prompt "API_URL (Traefik Host)" -Default $Current['API_URL'] -Example "api.statechecker.example.com"
        Update-EnvValue -EnvFile $EnvFile -Key "API_URL" -Value $apiUrl | Out-Null

        $webUrl = Read-DomainWithValidation -Prompt "WEB_URL (Traefik Host)" -Default $Current['WEB_URL'] -Example "statechecker.example.com"
        Update-EnvValue -EnvFile $EnvFile -Key "WEB_URL" -Value $webUrl | Out-Null

        $pmaUrl = Read-DomainWithValidation -Prompt "PHPMYADMIN_URL (Traefik Host)" -Default $Current['PHPMYADMIN_URL'] -Example "pma.statechecker.example.com"
        Update-EnvValue -EnvFile $EnvFile -Key "PHPMYADMIN_URL" -Value $pmaUrl | Out-Null
    }
}

function Prompt-ImageConfig {
    param($EnvFile, $Current)
    $imageName = Read-Host "API/CHECK image name [$($Current['IMAGE_NAME'])]"
    Update-EnvValue -EnvFile $EnvFile -Key "IMAGE_NAME" -Value ($imageName -or $Current['IMAGE_NAME']) | Out-Null

    $imageTag = Read-Host "API/CHECK image tag [$($Current['IMAGE_VERSION'])]"
    Update-EnvValue -EnvFile $EnvFile -Key "IMAGE_VERSION" -Value ($imageTag -or $Current['IMAGE_VERSION']) | Out-Null

    $webImageName = Read-Host "WEB image name [$($Current['WEB_IMAGE_NAME'])]"
    Update-EnvValue -EnvFile $EnvFile -Key "WEB_IMAGE_NAME" -Value ($webImageName -or $Current['WEB_IMAGE_NAME']) | Out-Null

    $webImageTag = Read-Host "WEB image tag [$($Current['WEB_IMAGE_VERSION'])]"
    Update-EnvValue -EnvFile $EnvFile -Key "WEB_IMAGE_VERSION" -Value ($webImageTag -or $Current['WEB_IMAGE_VERSION']) | Out-Null
}

function Set-EnvValuesInteractive {
    <#
    .SYNOPSIS
    Prompts for a handful of key env values and writes them to .env.
    #>
    param([Parameter(Mandatory = $true)][string]$EnvFile)

    $current = Get-CurrentEnvValues -EnvFile $EnvFile

    Write-Host "`n==========================`n  Basic configuration`n==========================`n" -ForegroundColor Cyan

    $stackName = Read-Host "Stack name [$($current['STACK_NAME'])]"
    Update-EnvValue -EnvFile $EnvFile -Key "STACK_NAME" -Value ($stackName -or $current['STACK_NAME']) | Out-Null

    $dataRoot = Read-Host "Data root [$($current['DATA_ROOT'])]"
    Update-EnvValue -EnvFile $EnvFile -Key "DATA_ROOT" -Value ($dataRoot -or $current['DATA_ROOT']) | Out-Null

    $proxyType = Read-Host "Proxy type (traefik/none) [$($current['PROXY_TYPE'])]"
    $proxyType = if ($proxyType) { $proxyType } else { $current['PROXY_TYPE'] }
    if ($proxyType -ne "traefik" -and $proxyType -ne "none") { $proxyType = "traefik" }
    Update-EnvValue -EnvFile $EnvFile -Key "PROXY_TYPE" -Value $proxyType | Out-Null

    Prompt-ProxyConfig -EnvFile $EnvFile -ProxyType $proxyType -Current $current
    Prompt-ImageConfig -EnvFile $EnvFile -Current $current
}

function Set-SetupCompleteMarker {
    <#
    .SYNOPSIS
    Writes the setup completion marker file.
    #>
    New-Item -ItemType File -Path "$ProjectRoot\.setup-complete" -Force | Out-Null
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Swarm Statechecker - Setup Wizard" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "" 

if (-not (Test-DockerSwarm)) {
    exit 1
}

if (Test-SetupComplete) {
    Write-Host "[WARN] Setup appears to be already complete." -ForegroundColor Yellow
    $rerun = Read-Host "Run setup again? This will overwrite .env and re-copy install files (y/N)"
    if ($rerun -notmatch '^[Yy]$') {
        Write-Host "Setup cancelled."
        exit 0
    }
}

if (-not (New-EnvFileIfMissing)) {
    exit 1
}

Set-EnvValuesInteractive -EnvFile "$ProjectRoot\.env"

$envConfig = Get-EnvConfig
$dataRoot = $envConfig["DATA_ROOT"]

if (-not (Initialize-DataRoot -DataRoot $dataRoot -ProjectRoot $ProjectRoot)) {
    exit 1
}

Write-Host "" 
Write-Host "==========================" -ForegroundColor Cyan
Write-Host "  Secrets" -ForegroundColor Cyan
Write-Host "==========================" -ForegroundColor Cyan
Write-Host "" 

$secretsOk = Test-RequiredSecrets
if (-not $secretsOk) {
    Write-Host "" 
    Write-Host "[WARN] Some required secrets are missing" -ForegroundColor Yellow
    Write-Host "How do you want to create secrets?" -ForegroundColor Yellow
    Write-Host "1) Create from secrets.env file" -ForegroundColor Gray
    Write-Host "2) Create interactively" -ForegroundColor Gray
    Write-Host "" 

    $secretsChoice = Read-Host "Your choice (1-2) [2]"
    if ([string]::IsNullOrWhiteSpace($secretsChoice)) { $secretsChoice = "2" }

    if ($secretsChoice -eq "1") {
        New-SecretsFromFile -SecretsFile "secrets.env" -TemplateFile "setup\secrets.env.template" | Out-Null
    } else {
        New-RequiredSecretsMenu
    }

    $null = Test-RequiredSecrets
}

$createOptional = Read-Host "Create optional secrets now (Telegram/Email/Google Drive)? (y/N)"
if ($createOptional -match '^[Yy]$') {
    New-OptionalSecretsMenu
}

Set-SetupCompleteMarker

Write-Host "" 
Write-Host "[OK] Setup complete. You can now run .\\quick-start.ps1 to manage the stack." -ForegroundColor Green
