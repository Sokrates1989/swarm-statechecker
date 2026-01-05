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

function Set-EnvValuesInteractive {
    <#
    .SYNOPSIS
    Prompts for a handful of key env values and writes them to .env.

    .PARAMETER EnvFile
    Path to the .env file.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$EnvFile
    )

    $content = Get-Content $EnvFile -ErrorAction SilentlyContinue

    $currentStackName = ($content | Select-String '^STACK_NAME=' | Select-Object -First 1).Line
    $currentStackName = if ($currentStackName) { ($currentStackName -split '=', 2)[1].Trim('"') } else { "statechecker-server" }

    $currentDataRoot = ($content | Select-String '^DATA_ROOT=' | Select-Object -First 1).Line
    $currentDataRoot = if ($currentDataRoot) { ($currentDataRoot -split '=', 2)[1].Trim('"') } else { "/gluster_storage/swarm/monitoring/statechecker-server" }

    $currentProxyType = ($content | Select-String '^PROXY_TYPE=' | Select-Object -First 1).Line
    $currentProxyType = if ($currentProxyType) { ($currentProxyType -split '=', 2)[1].Trim('"') } else { "traefik" }

    $currentTraefik = ($content | Select-String '^TRAEFIK_NETWORK_NAME=' | Select-Object -First 1).Line
    $currentTraefik = if ($currentTraefik) { ($currentTraefik -split '=', 2)[1].Trim('"') } else { "traefik" }

    $currentApiUrl = ($content | Select-String '^API_URL=' | Select-Object -First 1).Line
    $currentApiUrl = if ($currentApiUrl) { ($currentApiUrl -split '=', 2)[1].Trim('"') } else { "api.statechecker.domain.de" }

    $currentWebUrl = ($content | Select-String '^WEB_URL=' | Select-Object -First 1).Line
    $currentWebUrl = if ($currentWebUrl) { ($currentWebUrl -split '=', 2)[1].Trim('"') } else { "web.statechecker.domain.de" }

    $currentPmaUrl = ($content | Select-String '^PHPMYADMIN_URL=' | Select-Object -First 1).Line
    $currentPmaUrl = if ($currentPmaUrl) { ($currentPmaUrl -split '=', 2)[1].Trim('"') } else { "phpmyadmin.statechecker.domain.de" }

    $currentWebPort = ($content | Select-String '^WEB_PORT=' | Select-Object -First 1).Line
    $currentWebPort = if ($currentWebPort) { ($currentWebPort -split '=', 2)[1].Trim('"') } else { "8080" }

    $currentPmaPort = ($content | Select-String '^PHPMYADMIN_PORT=' | Select-Object -First 1).Line
    $currentPmaPort = if ($currentPmaPort) { ($currentPmaPort -split '=', 2)[1].Trim('"') } else { "8081" }

    $currentImage = ($content | Select-String '^IMAGE_NAME=' | Select-Object -First 1).Line
    $currentImage = if ($currentImage) { ($currentImage -split '=', 2)[1].Trim('"') } else { "sokrates1989/statechecker" }

    $currentTag = ($content | Select-String '^IMAGE_VERSION=' | Select-Object -First 1).Line
    $currentTag = if ($currentTag) { ($currentTag -split '=', 2)[1].Trim('"') } else { "latest" }

    $currentWebImage = ($content | Select-String '^WEB_IMAGE_NAME=' | Select-Object -First 1).Line
    $currentWebImage = if ($currentWebImage) { ($currentWebImage -split '=', 2)[1].Trim('"') } else { "sokrates1989/statechecker-web" }

    $currentWebTag = ($content | Select-String '^WEB_IMAGE_VERSION=' | Select-Object -First 1).Line
    $currentWebTag = if ($currentWebTag) { ($currentWebTag -split '=', 2)[1].Trim('"') } else { "latest" }

    Write-Host "" 
    Write-Host "==========================" -ForegroundColor Cyan
    Write-Host "  Basic configuration" -ForegroundColor Cyan
    Write-Host "==========================" -ForegroundColor Cyan
    Write-Host "" 

    $stackName = Read-Host "Stack name [$currentStackName]"
    if ([string]::IsNullOrWhiteSpace($stackName)) { $stackName = $currentStackName }
    Update-EnvValue -EnvFile $EnvFile -Key "STACK_NAME" -Value $stackName | Out-Null

    $dataRoot = Read-Host "Data root [$currentDataRoot]"
    if ([string]::IsNullOrWhiteSpace($dataRoot)) { $dataRoot = $currentDataRoot }
    Update-EnvValue -EnvFile $EnvFile -Key "DATA_ROOT" -Value $dataRoot | Out-Null

    $proxyType = Read-Host "Proxy type (traefik/none) [$currentProxyType]"
    if ([string]::IsNullOrWhiteSpace($proxyType)) { $proxyType = $currentProxyType }
    if ($proxyType -ne "traefik" -and $proxyType -ne "none") { $proxyType = "traefik" }
    Update-EnvValue -EnvFile $EnvFile -Key "PROXY_TYPE" -Value $proxyType | Out-Null

    if ($proxyType -eq "none") {
        $webPort = Read-Host "WEB_PORT (localhost) [$currentWebPort]"
        if ([string]::IsNullOrWhiteSpace($webPort)) { $webPort = $currentWebPort }
        Update-EnvValue -EnvFile $EnvFile -Key "WEB_PORT" -Value $webPort | Out-Null

        $pmaPort = Read-Host "PHPMYADMIN_PORT (localhost) [$currentPmaPort]"
        if ([string]::IsNullOrWhiteSpace($pmaPort)) { $pmaPort = $currentPmaPort }
        Update-EnvValue -EnvFile $EnvFile -Key "PHPMYADMIN_PORT" -Value $pmaPort | Out-Null
    }

    if ($proxyType -eq "traefik") {
        $traefikNetwork = Select-TraefikNetwork -DefaultNetwork $currentTraefik
        if ([string]::IsNullOrWhiteSpace($traefikNetwork)) { $traefikNetwork = $currentTraefik }
        Update-EnvValue -EnvFile $EnvFile -Key "TRAEFIK_NETWORK_NAME" -Value $traefikNetwork | Out-Null

        $apiUrl = Read-Host "API_URL (Traefik Host) [$currentApiUrl]"
        if ([string]::IsNullOrWhiteSpace($apiUrl)) { $apiUrl = $currentApiUrl }
        Update-EnvValue -EnvFile $EnvFile -Key "API_URL" -Value $apiUrl | Out-Null

        $webUrl = Read-Host "WEB_URL (Traefik Host) [$currentWebUrl]"
        if ([string]::IsNullOrWhiteSpace($webUrl)) { $webUrl = $currentWebUrl }
        Update-EnvValue -EnvFile $EnvFile -Key "WEB_URL" -Value $webUrl | Out-Null

        $pmaUrl = Read-Host "PHPMYADMIN_URL (Traefik Host) [$currentPmaUrl]"
        if ([string]::IsNullOrWhiteSpace($pmaUrl)) { $pmaUrl = $currentPmaUrl }
        Update-EnvValue -EnvFile $EnvFile -Key "PHPMYADMIN_URL" -Value $pmaUrl | Out-Null
    }

    $imageName = Read-Host "API/CHECK image name [$currentImage]"
    if ([string]::IsNullOrWhiteSpace($imageName)) { $imageName = $currentImage }
    Update-EnvValue -EnvFile $EnvFile -Key "IMAGE_NAME" -Value $imageName | Out-Null

    $imageTag = Read-Host "API/CHECK image tag [$currentTag]"
    if ([string]::IsNullOrWhiteSpace($imageTag)) { $imageTag = $currentTag }
    Update-EnvValue -EnvFile $EnvFile -Key "IMAGE_VERSION" -Value $imageTag | Out-Null

    $webImageName = Read-Host "WEB image name [$currentWebImage]"
    if ([string]::IsNullOrWhiteSpace($webImageName)) { $webImageName = $currentWebImage }
    Update-EnvValue -EnvFile $EnvFile -Key "WEB_IMAGE_NAME" -Value $webImageName | Out-Null

    $webImageTag = Read-Host "WEB image tag [$currentWebTag]"
    if ([string]::IsNullOrWhiteSpace($webImageTag)) { $webImageTag = $currentWebTag }
    Update-EnvValue -EnvFile $EnvFile -Key "WEB_IMAGE_VERSION" -Value $webImageTag | Out-Null
}

function Initialize-DataRoot {
    <#
    .SYNOPSIS
    Creates required directory structure under DATA_ROOT and copies install files
    (schema + migrations) into place.

    .PARAMETER DataRoot
    The data root directory.

    .OUTPUTS
    System.Boolean
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot
    )

    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        Write-Host "[ERROR] DATA_ROOT cannot be empty" -ForegroundColor Red
        return $false
    }

    Write-Host "" 
    Write-Host "[DATA] Preparing DATA_ROOT: $DataRoot" -ForegroundColor Cyan

    $dirs = @(
        Join-Path $DataRoot "logs/api",
        Join-Path $DataRoot "logs/check",
        Join-Path $DataRoot "db_data",
        Join-Path $DataRoot "install/database/migrations"
    )

    foreach ($d in $dirs) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    $schemaSrc = Join-Path $ProjectRoot "install/database/state_checker.sql"
    $schemaDst = Join-Path $DataRoot "install/database/state_checker.sql"

    if (-not (Test-Path $schemaSrc)) {
        Write-Host "[ERROR] Missing schema file: $schemaSrc" -ForegroundColor Red
        return $false
    }

    Copy-Item $schemaSrc $schemaDst -Force

    $migSrc = Join-Path $ProjectRoot "install/database/migrations"
    $migDst = Join-Path $DataRoot "install/database/migrations"

    if (Test-Path $migSrc) {
        Copy-Item (Join-Path $migSrc "*") $migDst -Recurse -Force

        $runMig = Join-Path $migDst "run_migrations.sh"
        if (Test-Path $runMig) {
            $chmod = Get-Command chmod -ErrorAction SilentlyContinue
            if ($null -ne $chmod) {
                & chmod +x $runMig 2>$null
            }
        }
    }

    Write-Host "[OK] DATA_ROOT prepared" -ForegroundColor Green
    return $true
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

if (-not (Initialize-DataRoot -DataRoot $dataRoot)) {
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
