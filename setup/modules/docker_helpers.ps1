# docker_helpers.ps1
# PowerShell module for Docker Swarm helper functions

function Test-DockerSwarm {
    Write-Host "Checking Docker Swarm..." -ForegroundColor Yellow
    
    try {
        $null = docker --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Docker not found" }
    } catch {
        Write-Host "[ERROR] Docker is not installed!" -ForegroundColor Red
        return $false
    }

    try {
        $null = docker info 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Docker daemon not running" }
    } catch {
        Write-Host "[ERROR] Docker daemon is not running!" -ForegroundColor Red
        return $false
    }

    # Check if in swarm mode
    $swarmStatus = docker info --format '{{.Swarm.LocalNodeState}}' 2>$null
    if ($swarmStatus -ne "active") {
        Write-Host "[ERROR] Docker is not in Swarm mode!" -ForegroundColor Red
        Write-Host "   Run 'docker swarm init' to initialize a swarm" -ForegroundColor Yellow
        return $false
    }

    Write-Host "[OK] Docker Swarm is active" -ForegroundColor Green
    return $true
}

function Test-SecretExists {
    param([string]$SecretName)
    
    $null = docker secret inspect $SecretName 2>&1
    return ($LASTEXITCODE -eq 0)
}

function New-DockerSecret {
    param(
        [string]$SecretName,
        [string]$Description
    )
    
    Write-Host ""
    Write-Host "[SECRET] Creating secret: $SecretName" -ForegroundColor Cyan
    Write-Host "   $Description" -ForegroundColor Gray
    Write-Host ""
    
    $secureValue = Read-Host "Enter value for $SecretName" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
    $secretValue = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    
    if ([string]::IsNullOrWhiteSpace($secretValue)) {
        Write-Host "[ERROR] Secret value cannot be empty" -ForegroundColor Red
        return $false
    }
    
    $secretValue | docker secret create $SecretName -
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Secret created: $SecretName" -ForegroundColor Green
        return $true
    } else {
        Write-Host "[ERROR] Failed to create secret: $SecretName" -ForegroundColor Red
        return $false
    }
}

function Get-SecretList {
    Write-Host "Current secrets:" -ForegroundColor Cyan
    docker secret ls
}

function Test-RequiredSecrets {
    $allExist = $true
    $requiredSecrets = @(
        "STATECHECKER_SERVER_AUTHENTICATION_TOKEN",
        "STATECHECKER_SERVER_DB_ROOT_USER_PW",
        "STATECHECKER_SERVER_DB_USER_PW"
    )
    
    Write-Host "Checking required secrets..." -ForegroundColor Yellow
    
    foreach ($secret in $requiredSecrets) {
        if (Test-SecretExists -SecretName $secret) {
            Write-Host "   [OK] $secret" -ForegroundColor Green
        } else {
            Write-Host "   [MISSING] $secret" -ForegroundColor Red
            $allExist = $false
        }
    }
    
    return $allExist
}

function Test-OptionalSecrets {
    $optionalSecrets = @(
        "STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN",
        "STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD",
        "STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON"
    )
    
    Write-Host ""
    Write-Host "Checking optional secrets..." -ForegroundColor Yellow
    
    foreach ($secret in $optionalSecrets) {
        if (Test-SecretExists -SecretName $secret) {
            Write-Host "   [OK] $secret" -ForegroundColor Green
        } else {
            Write-Host "   [WARN] $secret (not configured)" -ForegroundColor Yellow
        }
    }
}
